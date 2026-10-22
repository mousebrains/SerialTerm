# Architecture

SerialTerm is a Swift package with two targets:

| Target | Depends on | Contents |
|---|---|---|
| `SerialCore` (library) | Foundation only | Serial I/O, session routing, logging, file transfer (ZMODEM, YMODEM, XMODEM) |
| `SerialTerm` (macOS app) | SerialCore, SwiftUI/AppKit, IOKit, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Windows, settings, port discovery, terminal display |

`SerialCore` doesn't use AppKit or SwiftUI, so it can be tested without a UI and, eventually,
ported to Linux. That would mainly need a Linux path for non-standard baud rates
(`termios2`/`BOTHER`).

## Source map

```
Sources/SerialCore/
  SerialConfig.swift       line settings (baud, data bits, parity, stop bits, flow control)
  SerialPort.swift         open/configure (termios + IOSSIOSPEED), reads via DispatchSource, write queue
  Session.swift            one connection: routes input to display / log / transfer; ZMODEM auto-start
  SessionLogger.swift      millisecond-timestamped session log
  LogFile.swift            append-only file for logs and traces: never replaces a file, never raises
  PacedSender.swift        paced typing (characters per second, line pause, wait for echo)
  ZmodemDetector.swift     finds ZRQINIT/ZRINIT in the incoming stream (split-safe)
  FileTransfer.swift       FileTransfer protocol; TransferKind; remote receive commands
  Zmodem/
    ZmodemFrames.swift     constants, ZHeader, CRC-16/32, ZEncoder (escaping, headers, subpackets)
    ZmodemReader.swift     ByteChannel (blocking inbox), ZReader (header/subpacket decoder)
    ZmodemSender.swift     ZLink (output batching, tracing, progress), ZmodemSender
    ZmodemReceiver.swift   ZmodemReceiver, file-offer parsing, safe file names
    ZmodemTransfer.swift   FileTransfer adapter: runs sender/receiver on its own thread
    ZmodemTrace.swift      ZmodemOptions; trace writer (all protocols); header descriptions
  Xmodem/
    XmodemTransfer.swift   wire constants, block and YMODEM header encoding; FileTransfer adapter
    XmodemSender.swift     XmodemSender (XMODEM, YMODEM batches)
    XmodemReceiver.swift   XmodemReceiver (XMODEM to a chosen file, YMODEM into a folder)
Sources/SerialTerm/
  SerialTermApp.swift      @main, Settings scene, app delegate
  ContentView.swift        toolbar, connect bar, status bar, settings views
  TerminalModel.swift      per-window state and actions; DisplayBuffer
  TerminalContainer.swift  SwiftTerm hosting, keyboard input, file drops
  PortScanner.swift        IOKit enumeration and hot-plug notifications
  Preferences.swift        ConnectionSettings (per window), Preferences + AppSettings (app-wide)
```

## Data flow

```
                 ┌────────────── SerialPort ──────────────┐
  device ◀──────▶│ write queue (ordered, bounded backlog)  │
                 │ read DispatchSource (64 KB reads)       │
                 └───────┬─────────────────────▲───────────┘
                         │ onData (read queue)  │ write()
                         ▼                      │
                 ┌──────────── Session ──────────────────────┐
                 │ transfer active? ──yes──▶ FileTransfer.feed│──▶ protocol thread
                 │      │no                                  │      │ onOutput
                 │      ├──▶ SessionLogger (RX)              │◀─────┘
                 │      ├──▶ ZmodemDetector ──▶ start transfer│
                 │      └──▶ onDisplay                       │
                 └──────┬─────────────────────▲──────────────┘
                        │                     │ sendFromUser (TX, logged)
                        ▼                     │
              DisplayBuffer (batches to main) │
                        ▼                     │
              SwiftTerm TerminalView ── keystrokes ──▶ TerminalModel
```

## Threads

| Thread / queue | Work |
|---|---|
| Main | UI, `TerminalModel`, feeding SwiftTerm, file pickers |
| `SerialPort.read` | Reads the port; `Session` routing; ZMODEM detection; hands data to the log (escaped on the logger's queue) |
| `SerialPort.write` | Writes in order; waits on `poll(POLLOUT)` when the driver is full |
| `ZMODEM`, `XMODEM` (one `Thread` per transfer) | Runs the sender or receiver as blocking, sequential code |
| `SessionLogger`, `ZmodemTrace` | Serial queues for file writes |
| `PacedSender` | Serial queue that times typed text (and the receive commands typed for transfers) |

`Session`'s settings (download folder, ZMODEM options, …) are written on the main thread and
read on the read queue when a transfer starts automatically, so they are kept under its lock.
`SerialPort` uses its descriptor only while holding its lock and gives it up under the same lock,
so a call can't reach a descriptor number that was closed and reused by another open.

**Display batching**: at 2–3 Mbaud, input arrives in thousands of small reads per second.
`DisplayBuffer` collects them and schedules at most one main-thread update at a time, so the
display can't flood the main queue.

**The transfer thread model**: ZMODEM, YMODEM and XMODEM are written as straightforward blocking
code, like lrzsz, rather than as callback state machines. `ByteChannel` turns the serial input into a blocking
read with a timeout (an `NSCondition`). `ZReader` adds a local buffer, one byte of push-back, and
a history used for error snapshots. Timeouts and deadlines use `Uptime` (system uptime), not
`Date`, so a clock change can't stretch them. A reader deadline bounds a wait however steadily
bytes arrive. Cancelling drops queued output and wakes the reader, which then throws; the sender
also checks for a cancel between subpackets, since it reads only when input is waiting.

**Leftover input**: when a transfer ends, it passes input it didn't use to `onLeftover`, and the
session logs and displays it without scanning it for transfers. That is the remote's prompt after
the transfer, or everything received if the remote never got going: no file offered (a false
automatic start), no block received, or no receiver asking for one (a shell's "rx: not found"). Input arriving after the end goes the same way until the session has
let go of the transfer.

**Back-pressure**: senders call `waitForOutput(maxPending:)`. `SerialPort` counts bytes queued but
not yet accepted by the driver, so a sender can keep the driver busy (a 64 KB backlog) without
queuing an unbounded amount, and a `ZRPOS` rewind wastes little. XMODEM and YMODEM send a block
and wait for its ACK, so they only wait for the block to reach the driver before timing the
reply. The wait gives up when the transfer is cancelled, so flow control holding the line can't block a
cancel. `discardPendingWrites` drops queued writes, stops the one in progress, and flushes the
driver (`TCOFLUSH`).

**Closing**: `Session.close()` cancels a running transfer, sends the abort sequence and waits up
to a second for it to go out before closing the port, so neither end carries on alone. A window
disconnecting mid-transfer uses `closeInBackground`, so the main thread isn't held up; reopening
that port, or quitting, waits for the close to finish. A failed write closes the port with the
error, as a failed read does. The port is opened with `O_CLOEXEC`.

**Sending files**: the senders read each file through its own descriptor (`SendFile`, with a
64 KB cache) rather than mapping it: touching a mapped file whose volume has gone raises
SIGBUS. A file that gets shorter during the send fails it.

## Session routing

`Session.handleIncoming` runs on the read queue:

1. If a transfer is active, all bytes go to it. They are not displayed or logged; the transfer
   logs its own events.
2. Otherwise the bytes are logged as `RX`, then scanned by `ZmodemDetector`:
   - `ZRQINIT` → display the bytes before the header, then start a ZMODEM receive with the header
     bytes passed on (`prime`), so the receiver parses and traces the remote's opening frame. A
     header split across reads is rebuilt from the detector's prefix (its first part was already
     displayed);
   - `ZRINIT` → emit `.remoteWaitingForFiles`; the UI shows a file picker;
   - nothing → display.

User input (`sendFromUser`) is dropped while a transfer runs.

`startTransfer` claims the transfer slot before creating anything, so a refused start
(`TransferInProgress`) leaves no trace file behind. Once it has sent `transferStarted`, it
always follows with `transferFinished`, also when the transfer then fails to start. Automatic
starts that fail three times within 30 s pause automatic starts for 30 s.

## File transfers

```swift
public protocol FileTransfer: AnyObject, Sendable {
    var onOutput: ((Data) -> Void)? { get set }                    // bytes for the line
    var waitForOutput: ((_ maxPending: Int) -> Void)? { get set }  // back-pressure
    var discardOutput: (() -> Void)? { get set }                   // drop what's queued
    var onStatus: ((String) -> Void)? { get set }                  // progress line
    var onLog: ((String) -> Void)? { get set }                     // session-log notes
    var onFinish: ((Bool, String) -> Void)? { get set }
    var typeReceiveCommand: ((String) -> Void)? { get set }        // "rz", "rx 'name'", "rb"
    var onLeftover: ((Data) -> Void)? { get set }                  // input that wasn't the transfer
    var traceURL: URL? { get }
    func start() throws
    func feed(_ data: Data)
    func cancel()
}
```

- `ZmodemTransfer`: ZMODEM (see [ZMODEM](zmodem.md)).
- `XmodemTransfer`: XMODEM and YMODEM, sharing ZMODEM's plumbing (`ByteChannel`, `ZReader`,
  `ZLink` for output, progress and tracing) and its receiver's safe names, never-overwrite file
  creation and quarantine. XMODEM accepts CRC-16 or the checksum and 128- or 1024-byte blocks in
  both directions; a receive asks for CRC-16 until three requests have met silence, then for the
  checksum, and the first block's length settles which the sender uses. YMODEM always uses
  CRC-16 and 1K blocks, with block 0 carrying the ZMODEM-style "name size mtime mode" fields; a
  file that arrives shorter than announced fails.

  What the receiver must not mistake: an EOT is one unchecked byte, so a 0x04 counts only as the
  first byte since its last answer with quiet after it (one in a block whose start byte was lost
  would end the file early and be reported complete), and it is NAKed once and never taken alone.
  Two CANs abort where a block should start, five among other bytes. After a bad block it waits
  for the line to go quiet, however long the block takes, and NAKs once.

  ACKs carry no block number, so a second copy of a block in flight makes every later ACK count
  for the next block, and a damaged last block is then lost with both ends reporting success.
  The sender avoids second copies: it waits a minute for a reply, as lrzsz's does, and lets the
  receiver's NAKs (every few seconds while it waits) drive resends; after a NAK it waits for the
  receiver to go quiet for a second, taking further NAKs as part of it (lrzsz's rx clears at most
  1000 bytes of a bad block before its first NAK, and NAKs again for the rest); and a repeated 'C' that may have crossed the first block gets time for the block's own
  answer. As a backstop, after the last block's ACK it waits a moment: a NAK then means the ACKs
  were a block behind, and the last block goes again. If the remote's shell answers instead of an
  ACK for EOT, the receiver has finished; another EOT would be a ^D at the shell.

  An XMODEM receive is written to a new file beside the chosen one and replaces it only when
  complete.

## Port discovery

`PortScanner` lists `IOSerialBSDClient` services and reports each one's callout device
(`/dev/cu.*`). It searches up the IOKit registry for USB vendor and product names, the serial
number, the interface number (`bInterfaceNumber`), and VID/PID. `IOServiceAddMatchingNotification`
(first-match and terminated) keeps the list current.

`SerialPortInfo.find(path:serialNumber:interface:in:)` is the one rule for finding a remembered
port again, used by auto-reconnect and presets: the same `/dev` name with the same (or no
recorded) serial number first; otherwise the serial number, narrowed by the interface, but only
if exactly one port matches. Every port of a multi-port adapter has the same serial number.
`ConnectionSettings.setPort` always records the port's serial number and interface, including
"none", so an earlier adapter's can't linger.

## Terminal input

What the user types reaches `TerminalModel` through the SwiftTerm delegate's `send`. Replies the
terminal makes by itself (focus and mouse reports, answers to queries) and pastes come through
`SerialTerminalView.send(source:data:)`, which marks a paste as user input. Only user input
connects a disconnected window. On a new connection the terminal is fed `TerminalModeReset`
locally (mouse and focus reporting, bracketed paste, kitty keyboard, alternate screen off, then
DECSTR), so one device's modes don't carry over to the next.

## Settings

- `ConnectionSettings` (port, its USB serial number and interface, `SerialConfig`, Backspace,
  pacing, receive command) belongs to a window. It is kept in the window's `@SceneStorage`, so a
  window macOS reopens at launch gets its own back, and the most recent one is stored as the
  default for new windows. A change the port refuses is reverted rather than saved.
- `Preferences` (keyboard, display, folders, transfer options, `ZmodemOptions`) is app-wide. It is
  held by `AppSettings.shared` and saved to `UserDefaults` as JSON under `preferences.v2`.
  Decoding goes field by field, so adding settings never discards saved ones; presets decode one
  by one, so one bad preset is skipped alone; values are clamped to their valid ranges. Settings
  that can't be read at all are copied to `preferences.v2.unreadable` before defaults replace
  them.
