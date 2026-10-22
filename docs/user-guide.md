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
   supports, as digits only (`250000`, not `250,000` or `2.5e5`).
3. **Adjust the line settings** (data bits, parity, stop bits, flow control, and what the
   Backspace key sends) with the slider button. The default is 8N1 with no flow control and
   Backspace sending DEL. Changes to an open connection take effect immediately. If the adapter's
   driver refuses a setting (not every adapter can do every rate), the status bar says so and the
   window goes back to the settings the port is still using.

While disconnected, a bar across the top of the terminal shows the selected port and a
**Connect** button. **Typing (or pasting) at a disconnected terminal connects first**, then sends
the key, so pressing Return is usually all you need. **⇧⌘K** connects and disconnects. Only what
you type or paste connects: replies the terminal sends by itself, such as mouse-click or window
focus reports a program on the device asked for, don't reopen a port you disconnected.

Each new connection starts the terminal with its default modes, so a mode one device turned on
(mouse reporting, bracketed paste, the alternate screen) doesn't carry over to the next.

The terminal shows dim local lines such as `[Connected: usbserial-A50285BI 115200 8N1]` and
`[Disconnected]`. They are displayed only and never sent to the device.

**Reconnect after unplugging**: if the adapter is unplugged while connected, SerialTerm reconnects
when the same adapter (matched by USB serial number) is plugged back in, even under a different
`/dev` name. The ports of a multi-port adapter share one serial number, so SerialTerm also matches
the port's USB interface, and it doesn't reconnect when it can't tell which port was yours.
Adapters without a serial number are matched by `/dev` name only. If the device isn't ready when
it reappears, SerialTerm tries again for a few seconds. You can turn reconnecting off in Settings ▸
General.

**Paced typing**: some device command lines drop characters that arrive faster than they can
parse them, typically above 10–50 characters a second, which garbles pasted commands. Under the
slider button, set *Typing speed* (characters per second) and, if the device needs time to run each
command, *Pause after each line*. Typed and pasted text then goes out at that pace, in order; file
transfers always run at full speed.

*Wait for each character's echo* sends the next character only when the device has echoed the
previous one, so it goes as fast as the device keeps up. A printable character must come back as
itself; Return as CR or LF; other control characters (Ctrl-C, Backspace) as anything. If no echo
arrives within *Give up waiting after* (1 s by default), the character is sent anyway and the
status bar shows **No echo**, so a device with echo off is slowed down but never stuck. The speed
limit and line pause still apply, counted from each echo. The echo must arrive first, within
the next few dozen bytes from the device; the same character further on in its output doesn't
count. The first character after a line end may come back after the device's answer to the line
(its output and the next prompt), within its next 1024 bytes. While text is waiting, the status bar shows how much is left and a **Cancel** button; the
status bar also shows the pace whenever it is on. Keys you type meanwhile, Ctrl-C included, queue
behind the text, so use **Cancel** to stop a long paste. Cancel also ends the wait for an echo,
so the next key goes out at once.

The commands SerialTerm types to start a transfer on the device (`rb`, `rx name`, and the ZMODEM
receive command) go out at the same pace.

**Several devices**: each window (**⌘N**) has its own port and line settings. New windows start
with the settings used most recently; windows that macOS reopens at launch get their own back
(they don't connect until you type or click Connect).

### Presets

A preset is a named set of line settings: baud rate, data bits, parity, stop bits, flow control,
what the Backspace key sends, the typing pace, and the command that starts the device's ZMODEM
receiver (`rz` or `zr`). It can also include a port.

- **Save**: set up a window, then choose **Presets ▸ Save Current Settings as Preset…** and give
  it a name. Turn on **Include port** to save the window's port with it. Saving under an existing
  name replaces that preset. Each preset has its own, non-empty name.
- **Apply**: choose the preset from the **Presets** menu. It applies to that window only, and
  immediately if the window is connected. A preset with a port also switches the window to that
  port, which connects to it.
- A saved port is found again by its USB serial number, so the preset follows whatever carries
  the USB serial chip, even if macOS gives it a different `/dev` name. That is the instrument
  when it has its own USB port, or the USB adapter when the instrument is wired to one. On a
  multi-port adapter, the preset remembers which of its ports it was.
- Choosing another port in the toolbar afterwards is fine; it doesn't change the preset.
- The menu's title shows the preset the window's settings match, or *Presets* if none does.
- **Rename, reorder, delete, or change a preset's port** in **Settings ▸ Presets**. Set the port
  to *Keep window's port* for a preset that should work with any port. Delete one from the menu
  with **Presets ▸ Delete Preset**.

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
| Presets menu | Apply, save or delete a [preset](#presets) |
| ⚡ Connect / Disconnect | ⇧⌘K |
| Transfer menu | ZMODEM / YMODEM / XMODEM send and receive (while connected and no transfer is running), Cancel Transfer, Open Last ZMODEM Trace, Show Download Folder |
| ● Log | Turn session logging on or off: red while this window is logging, grey while logging is on but the window isn't connected, ⚠ when logging is on but the window couldn't open its log |
| Line menu | Send Break, Send Window Size (stty), Clear Screen |
| Slider | Data bits, parity, stop bits, flow control, Backspace key, typing pace, ZMODEM receive command; **More Settings…** |

If the window is narrow, macOS moves some toolbar items behind a `»` button.

**During a transfer** the port, baud, preset and line settings controls are unavailable, and the
window can't be closed; cancel the transfer first. Quitting SerialTerm during a transfer asks
first, then cancels it and tells the device to stop.

**Status bar**:
- connection state and line settings, such as `115200 8N1`;
- transfer progress with a **Cancel** button. For a batch: which file of how many, the percentage
  of all the batch's bytes, and an estimate of the time left; then the current file's name,
  bytes, percent and rate, e.g.
  `3/10, 37% of 2.8 MB, ~45 s left · Receiving 02460483.dbd  9 KB / 12 KB (75%)  40 KB/s`.
  When receiving, the file count and batch size come from the sender (lrzsz and Slocum gliders
  send them; `3/?` means the sender didn't). The time left is measured as the batch goes: the
  data rate so far, plus the average pause the remote takes between files, so it suits any
  device;
- paced typing still to send, with a **Cancel** button, and the pace when it is on;
- the current log file (click to show it in Finder), or **Not logging** when logging is on but
  this window has no log (hover for the reason; turn logging off and on to try again);
- `⌫ = ^H` when the Backspace key sends Ctrl-H;
- the terminal size in columns × rows.

**Window size**: the terminal reflows when you resize the window, but a serial line has no way to
tell the device. If full-screen programs on the device (`vi`, `less`, `top`) draw wrong, choose
**Line ▸ Send Window Size**. This types `stty rows R cols C` at the device's shell.

## Settings

Open with **SerialTerm ▸ Settings…** (⌘,). These settings apply to all windows.

**General**
- *Font size*.
- *Reconnect when the adapter is plugged back in*.
- *Use Option as Meta key* (on by default): see [Keyboard](#keyboard).

**Transfers**
- *Save received files to* (default: Downloads) and *Choose files to send from* (the file picker's
  starting folder; it follows your last choice).
- *Start transfers automatically*: ZMODEM when the remote runs `sz`/`rz`, and XMODEM when lrzsz's
  `sx` announces itself. If three automatic transfers fail within 30 seconds, automatic starts
  pause for 30 seconds, so a device stuck starting and aborting transfers can't restart one
  many times a second. *Use lrzsz instead of the built-in ZMODEM*; files it receives are saved
  under the same safe names as the built-in receiver's (no paths, no leading dots, never
  overwriting).
- *ZMODEM diagnostics* and *ZMODEM workarounds*: see [ZMODEM & Diagnostics](zmodem.md).

**Presets**: rename, reorder or delete [presets](#presets), and change or clear each one's port.
A name that is empty or already used by another preset isn't taken; the field says why.

**Logging**
- *Log sessions*, which is the same as the toolbar's ● Log button, and *Log folder* (default:
  `~/Documents/SerialTerm Logs`).

## Keyboard

- Keys are sent as an xterm would send them: arrows and function keys as escape sequences, and
  Option as Meta (Option-x sends Esc x). On layouts that type characters such as `@`, `|` or `~`
  with Option, turn off *Use Option as Meta key* in Settings ▸ General. ⌥⌘O switches it for the
  front window until the setting next changes.
- ⌘C / ⌘V copy and paste. Pasted text is sent to the device.
- ⇧⌘K connects and disconnects. ⌘N opens a new window. ⌘, opens Settings.
- Keystrokes are ignored while a file transfer is running, because they would corrupt it.
- **Backspace** sends DEL (0x7F) by default. Some devices expect Ctrl-H (0x08) instead; if
  Backspace shows `^?` or `^H` rather than erasing, change *Backspace sends* under the slider
  button. This is set per window and can be part of a preset.

## Session logs

When logging is on, each connection writes a new file such as `SerialTerm-2026-10-20-103201.log`
in the log folder. If another window starts a log in the same second, its file gets `-2` (and so
on) added to the name: each session has its own file, and an existing file is never
overwritten.

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
- Notes quote what the device sent, such as file names, with the same escapes, so nothing the
  device sends can start a line of its own in the log.
- If the log can't be written (the disk is full, or the log folder's volume was removed), logging
  stops for that session and the status bar says so. SerialTerm keeps running.

## File transfers

### ZMODEM (built in)

**Receiving**: run `sz file1 file2 …` on the device. SerialTerm detects it and receives all the
files into the download folder.
- An existing file is never overwritten; the new copy is saved as `name (1).ext`.
- Paths in the remote's file names are removed, so a file can't land outside the download folder.
  Leading dots, control and invisible characters are removed too, and very long names shortened.
- Each file keeps its original modification time.
- Received files are marked as downloaded, as a browser marks them, so macOS asks before running a
  received app or script.
- If a transfer fails or is cancelled, the partly received file is deleted.
- The device's prompt after the transfer appears in the terminal as usual.
- If something that looked like the start of a transfer wasn't one (say, a listing of a file
  that happens to contain a ZMODEM header), SerialTerm gives up within a few seconds and shows
  what the device sent meanwhile.

**Sending**, any of three ways:
- Run `rz` on the device. SerialTerm detects it and opens a file picker; ⌘-click to choose
  several files.
- At the device's shell prompt, choose **Transfer ▸ ZMODEM ▸ Send Files…**. SerialTerm types
  the device's receive command for you: `rz` by default, or what *ZMODEM send starts receiver
  with* under the slider button says (`zr` for Slocum gliders, or nothing). It is harmless if
  the receiver is already running, it goes at the typing pace if paced typing is on, and it can
  be part of a preset.
- Drop files onto the terminal window.

**Progress** appears in the status bar. **Cancel** (status bar or Transfer menu) stops both ends.
Disconnecting during a transfer cancels it and tells the device to stop first. If the adapter is
unplugged during a transfer, the status bar keeps the reason for the disconnect and says the
transfer was stopped.
**Results** appear in the status bar when the transfer ends, for example `Received 3 files
(183 MB)`. A failure of a built-in ZMODEM transfer that wrote a trace points you to **Open Last
ZMODEM Trace**. SerialTerm beeps when a transfer you started fails, not for automatic ones.

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
with 0x1A bytes to a multiple of 128. YMODEM sends both, so its files arrive exact. To strip the
padding from a text file: `perl -pi -e 's/\x1a+$//' file`.

**XMODEM-1K** (Settings ▸ Transfers) sends 1024-byte blocks instead of 128, which is fewer round
trips and was about 1.5× faster to a MicroRider. Leave it off for devices that only accept classic
XMODEM.

**Cancelling** stops both ends. An XMODEM/YMODEM receiver only notices a cancel between blocks.
If the device's receiver keeps waiting (it sends a NAK), SerialTerm cancels again. If the device
still seems stuck, press Ctrl-X a few times, then Return.

## Troubleshooting

**Typing does nothing.** The status bar says why: no port chosen, or not connected. Typing connects
when a port is selected. If connecting fails, the status bar shows the error.

**"Resource busy" when connecting.** Another program (or another SerialTerm window) has the port
open. Only one program can use a serial port at a time.

**Garbled text.** The baud rate doesn't match the device. Native USB devices (`cu.usbmodem…`)
ignore the baud rate, so for those, check the device's own settings.

**Nothing at all from the device.** Check the port (USB adapters are listed by name) and try
pressing Return. Some devices need hardware flow control set to match, or none. If RTS/CTS is on
and the device doesn't drive CTS, nothing can be sent; a transfer then waits until you cancel it
or disconnect.

**The device resets when SerialTerm connects or disconnects.** Like most terminal programs,
SerialTerm leaves DTR and RTS to the driver: they come on when the port opens and go off when it
closes. Boards that reset on DTR (Arduino-style) reset then. The port keeps SerialTerm's settings
after it closes; the next program to open it sets its own.

**Errors at high speed.** Turn on RTS/CTS if both ends support it. For ZMODEM, see the workarounds
in [ZMODEM & Diagnostics](zmodem.md).

**A ZMODEM transfer failed or behaved oddly.** Choose **Transfer ▸ Open Last ZMODEM Trace**. The
[ZMODEM guide](zmodem.md#reading-a-trace) explains how to read it. Trying again with the lrzsz
setting on helps tell a device quirk from a SerialTerm bug.

**Settings were reset to defaults.** If SerialTerm can't read its saved settings (damaged, or
written by a newer version), it starts with defaults and keeps the old data in its preferences
under `preferences.v2.unreadable`. One unreadable preset is skipped on its own; the others load.

**The Edit menu shows Writing Tools / AutoFill.** macOS adds these to any app
that accepts text input. They have no use in a terminal; ignore them.
