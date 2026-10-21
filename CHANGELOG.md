# Changelog

All notable changes are recorded here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- macOS app (SwiftUI + SwiftTerm) with per-window connections.
- Port discovery through IOKit: USB product name, serial number and VID/PID; hot-plug updates;
  automatic reconnect to the same adapter, matched by serial number.
- Any baud rate up to the adapter's limit (`IOSSIOSPEED` above 230400); 5–8 data bits, parity,
  stop bits, RTS/CTS and XON/XOFF flow control; changes apply immediately.
- Choosing a port connects; typing at a disconnected terminal connects first; a connect bar and
  local `[Connected …]` / `[Disconnected]` lines.
- The command typed to start the device's ZMODEM receiver before a send is set per window and
  saved in presets: `rz` (default), `zr` for Slocum gliders, or nothing.
- ZMODEM progress shows the batch position (`3/10`), the percentage of the whole batch, and an
  estimate of the time left from the measured data rate and gap between files.
- Paced typing: typed and pasted text limited to N characters a second, optionally waiting for
  each character's echo (with a timeout and a "No echo" warning), with an optional pause after
  each line end; progress and Cancel in the status bar. File transfers are never paced.
- Presets: named line settings (baud rate, data bits, parity, stop bits, flow control), the
  Backspace key's code, the typing pace and optionally a port (found again by USB serial number), saved from and
  applied to any window; managed in Settings ▸ Presets.
- Per-window Backspace key code (DEL or ^H), with the line settings; the old app-wide setting
  carries over.
- Settings window: font size, folders for downloads, uploads and logs, transfer options.
- Session logs with millisecond timestamps.
- Native ZMODEM: batch send and receive, CRC-16/32, streaming with `ZRPOS` recovery, windowed mode,
  `ESCCTL`, automatic start on `sz`/`rz`, drag-and-drop send, safe file names, no overwriting,
  modification times kept, partial files removed, `ZCOMMAND` refused.
- ZMODEM protocol traces (Frames / Frames + raw bytes), with error snapshots showing the raw bytes
  and serial read timing around each bad subpacket.
- ZMODEM workarounds: block size, forced ACK window, force CRC-16, escape all control characters,
  timeout.
- XMODEM / YMODEM through lrzsz: sends type the device's `rx`/`rb`; XMODEM receive starts when
  lrzsz's `sx` announces itself; optional lrzsz ZMODEM.
- Tests: codec, native↔native over corrupting links, interop with lrzsz over ptys (clean and
  noisy), traces, performance, and opt-in tests against real hardware.
- CI on GitHub Actions; tagged releases.

- XMODEM-1K option (Settings ▸ Transfers): 1024-byte blocks, ~1.5× faster to the MicroRider.
- Licensed GPL-3.0-or-later.

### Changed
- Requires macOS 15 or later (was 14).
- Builds and tests with only the Command Line Tools; Xcode is optional.

### Fixed
- ZMODEM send could stall for a minute and fail when the receiver lost data, asked for a resend,
  lost data again and went quiet (as Slocum gliders do at 921600 baud). After a ZEOF gets no
  reply the sender now resends from the last position the receiver confirmed, which makes the
  receiver resume or say where it is. The ZEOF timeout also starts once the data has left the
  queue, not when it was queued.
- The app could crash just after a ZMODEM transfer ended, most often with raw-byte tracing at
  high baud rates: the trace file was closed with a `sync` onto the queue that was releasing it.
  The session log had the same flaw.
- XMODEM receive failed with lrzsz's "Security Violation" (it refuses paths with directories);
  `lrx` now runs in the target folder.
- Cancelling an XMODEM/YMODEM transfer mid-block could leave the remote receiver running (it
  only sees CAN between blocks). SerialTerm now aborts again if the receiver NAKs after a cancel.
- ZMODEM sender: duplicate `ZRPOS` requests (lrzsz repeats them while skipping in-flight data)
  caused cascading rewinds and "Too many errors". Repeats are now ignored, and stale queued
  output is discarded on a rewind.
- ZMODEM: a transfer could stall and then fail with "no reply to ZEOF" when the data right after
  a rewind was damaged too. The sender took the receiver's genuine repeat `ZRPOS` for a
  duplicate, and our receiver, ignoring the sender's stale `ZEOF`s, never asked again. The
  sender now rewinds when `ZEOF` goes unanswered after an ignored `ZRPOS`, and stale `ZEOF`s no
  longer postpone the receiver's timeout. Found as an intermittent CI failure.

### Verified on hardware
- Rockland MicroRider (native USB serial): ZMODEM in both directions, single files and batches,
  up to 134.6 MB, all MD5-verified. ~9.6 MB/s receiving; sending is limited by the device to
  ~2.3 MB/s. XMODEM and YMODEM (two-file batches) in both directions, MD5-verified; XMODEM to the
  MicroRider ~260 KB/s, XMODEM-1K ~390 KB/s.
