# SerialTerm User Guide

- [Connecting](#connecting)
- [The window](#the-window)
- [Settings](#settings)
- [Keyboard](#keyboard)
- [Session logs](#session-logs)
- [File transfers](#file-transfers)
- [Troubleshooting](#troubleshooting)

## Connecting

1. **Choose a port** from the port menu at the left of the toolbar. USB adapters are listed first,
   by product name and serial number, for example `FT232R USB UART – A50285BI (cu.usbserial-A50285BI)`.
   **Choosing a port connects to it**, and choosing another switches to it.
2. **Choose the baud rate** from the baud menu. Choose **Custom…** to enter any rate the adapter
   supports.
3. **Adjust the line settings** (data bits, parity, stop bits, flow control) with the slider
   button. The default is 8N1 with no flow control. Changes to an open connection take effect
   immediately.

While disconnected, a bar across the top of the terminal shows the selected port and a
**Connect** button. **Typing at a disconnected terminal connects first**, then sends the key, so
pressing Return is usually all you need. **⇧⌘K** connects and disconnects.

The terminal shows dim local lines such as `[Connected: usbserial-A50285BI 115200 8N1]` and
`[Disconnected]`. They are displayed only and never sent to the device.

**Reconnect after unplugging**: if the adapter is unplugged while connected, SerialTerm reconnects
when the same adapter (matched by USB serial number) is plugged back in, even under a different
`/dev` name. You can turn this off in Settings ▸ General.

**Several devices**: each window (**⌘N**) has its own port and line settings. New windows start
with the settings used most recently.

### Baud rates and adapters

Rates up to 230400 are set the standard way. Faster or non-standard rates use macOS's
`IOSSIOSPEED` call, which works with the common adapter drivers. What a given adapter can actually
do varies:

| Adapter | Practical maximum |
|---|---|
| FTDI FT232R / FT231X | 3 Mbaud (1M, 1.5M, 2M, 3M are exact) |
| FTDI FT232H / FT2232H / FT4232H | 12 Mbaud in hardware; above 3 Mbaud depends on the driver |
| SiLabs CP2102 / CP2104 | ~921600 |
| SiLabs CP2102N | 3 Mbaud |
| WCH CH340 / CH343 | ~2 / 6 Mbaud |
| Native USB devices (`cu.usbmodem…`) | the baud setting is ignored; data moves at USB speed |

Above about 1 Mbaud, use RTS/CTS flow control if the device supports it.

## The window

**Toolbar**, left to right:

| Control | Purpose |
|---|---|
| Port menu | Select (and connect to) a port |
| Baud menu | Common rates, or Custom… |
| ⚡ Connect / Disconnect | ⇧⌘K |
| Transfer menu | ZMODEM / YMODEM / XMODEM send and receive, Cancel Transfer, Open Last ZMODEM Trace, Show Download Folder |
| ● Log | Turn session logging on or off (red while logging) |
| Line menu | Send Break, Send Window Size (stty), Clear Screen |
| Slider | Data bits, parity, stop bits, flow control; **More Settings…** |

If the window is narrow, macOS moves some toolbar items behind a `»` button.

**Status bar**:
- connection state and line settings, such as `115200 8N1`;
- transfer progress (file, bytes, percent, rate) with a **Cancel** button;
- the current log file (click to show it in Finder);
- `⌫ = ^H` when the Backspace key sends Ctrl-H;
- the terminal size in columns × rows.

**Window size**: the terminal reflows when you resize the window, but a serial line has no way to
tell the device. If full-screen programs on the device (`vi`, `less`, `top`) draw wrong, choose
**Line ▸ Send Window Size**. This types `stty rows R cols C` at the device's shell.

## Settings

Open with **SerialTerm ▸ Settings…** (⌘,). These settings apply to all windows.

**General**
- *Backspace key sends*: DEL (0x7F, the default) or Ctrl-H (0x08). Some devices expect the other
  one; if Backspace shows `^?` or `^H` instead of erasing, switch it.
- *Font size*.
- *Reconnect when the adapter is plugged back in*.

**Transfers**
- *Save received files to* (default: Downloads) and *Choose files to send from* (the file picker's
  starting folder; it follows your last choice).
- *Start transfers automatically*: ZMODEM when the remote runs `sz`/`rz`, and XMODEM when lrzsz's
  `sx` announces itself. *Use lrzsz instead of the built-in ZMODEM*.
- *ZMODEM diagnostics* and *ZMODEM workarounds*: see [ZMODEM & Diagnostics](zmodem.md).

**Logging**
- *Log sessions*, which is the same as the toolbar's ● Log button, and *Log folder* (default:
  `~/Documents/SerialTerm Logs`).

## Keyboard

- Keys are sent as an xterm would send them: arrows and function keys as escape sequences, and
  Option as Meta.
- ⌘C / ⌘V copy and paste. Pasted text is sent to the device.
- ⇧⌘K connects and disconnects. ⌘N opens a new window. ⌘, opens Settings.
- Keystrokes are ignored while a file transfer is running, because they would corrupt it.

## Session logs

When logging is on, each connection writes a new file such as `SerialTerm-2026-10-20-103201.log`
in the log folder:

```
2026-10-20 10:32:01.120 -- Log opened; /dev/cu.usbserial-A50285BI 115200 8N1; time zone America/Los_Angeles
2026-10-20 10:32:01.123 RX login: \r\n
2026-10-20 10:32:02.456 TX root\r
2026-10-20 10:32:05.001 -- ZMODEM receive started (transfer data not logged)
```

- One line for each chunk received from the driver (`RX`) or sent (`TX`). `--` lines are notes.
- Printable ASCII appears as-is. `\r \n \t \e \\` and `\xHH` represent other bytes, so each entry
  is exactly one line.
- Timestamps are local time to the millisecond and record **when the Mac received the data**.
  USB adapters deliver data in batches. FTDI adapters hold data for up to 16 ms by default.
  SerialTerm asks the driver for 1 ms, but not every driver honors that.
- File transfer data is not logged, only each file's start and finish and any errors. For full
  protocol detail, see the ZMODEM trace.

## File transfers

### ZMODEM (built in)

**Receiving**: run `sz file1 file2 …` on the device. SerialTerm detects it and receives all the
files into the download folder.
- An existing file is never overwritten; the new copy is saved as `name (1).ext`.
- Paths in the remote's file names are removed, so a file can't land outside the download folder.
- Each file keeps its original modification time.
- If a transfer fails or is cancelled, the partly received file is deleted.

**Sending**, any of three ways:
- Run `rz` on the device. SerialTerm detects it and opens a file picker; ⌘-click to choose
  several files.
- At the device's shell prompt, choose **Transfer ▸ ZMODEM ▸ Send Files…**. SerialTerm types
  `rz` for you.
- Drop files onto the terminal window.

**Progress** appears in the status bar. **Cancel** (status bar or Transfer menu) stops both ends.
**Results** appear in the status bar when the transfer ends, for example `Received 3 files
(183 MB)`.

If automatic start is off, choose **Transfer ▸ ZMODEM ▸ Receive** before running `sz`.

### YMODEM and XMODEM (via lrzsz)

These need `brew install lrzsz` on the Mac and lrzsz (`sx`/`rx`/`sb`/`rb`) on the device. Start
sends from SerialTerm while the device is at its shell prompt; SerialTerm types the device's
receive command for you.

| | Do this | What happens |
|---|---|---|
| **YMODEM send** (several files) | Transfer ▸ YMODEM ▸ Send Files… | SerialTerm types `rb`, then sends |
| **YMODEM receive** | Run `sb file…` on the device, **then** choose Transfer ▸ YMODEM ▸ Receive within 20 s | Files arrive with their names |
| **XMODEM send** (one file) | Transfer ▸ XMODEM ▸ Send File… | SerialTerm types `rx 'name'`, then sends |
| **XMODEM receive** (one file) | Run `sx file` on the device | SerialTerm sees its "Give your local XMODEM receive command now." and asks where to save |

The order matters for receives. A receiver signals readiness by sending characters (`C`), and if
the device is still at its shell, those characters land on its command line. Always start the
device's sender first. Transfer ▸ XMODEM ▸ Receive As… is available for devices that don't
announce themselves.

lrzsz's `sb` doesn't announce itself. If no YMODEM receiver answers within 20 seconds, it switches
to ZMODEM, which SerialTerm then receives automatically. So running `sb` and doing nothing still
gets your files.

XMODEM sends neither a file name nor a size, so you choose the name, and the file arrives padded
with 0x1A bytes to a multiple of 128. YMODEM sends both, so its files arrive exact.

## Troubleshooting

**Typing does nothing.** The status bar says why: no port chosen, or not connected. Typing connects
when a port is selected. If connecting fails, the status bar shows the error.

**"Resource busy" when connecting.** Another program (or another SerialTerm window) has the port
open. Only one program can use a serial port at a time.

**Garbled text.** The baud rate doesn't match the device. Native USB devices (`cu.usbmodem…`)
ignore the baud rate, so for those, check the device's own settings.

**Nothing at all from the device.** Check the port (USB adapters are listed by name) and try
pressing Return. Some devices need hardware flow control set to match, or none. If RTS/CTS is on
and the device doesn't drive CTS, nothing can be sent.

**Errors at high speed.** Turn on RTS/CTS if both ends support it. For ZMODEM, see the workarounds
in [ZMODEM & Diagnostics](zmodem.md).

**A ZMODEM transfer failed or behaved oddly.** Choose **Transfer ▸ Open Last ZMODEM Trace**. The
[ZMODEM guide](zmodem.md#reading-a-trace) explains how to read it. Trying again with the lrzsz
setting on helps tell a device quirk from a SerialTerm bug.

**The Edit menu shows Writing Tools / AutoFill.** macOS adds these to any app
that accepts text input. They have no use in a terminal; ignore them.
