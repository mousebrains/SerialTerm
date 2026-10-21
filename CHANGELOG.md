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
- Settings window: the Backspace key's code (DEL or ^H), font size, folders for downloads, uploads
  and logs, transfer options.
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
- XMODEM receive failed with lrzsz's "Security Violation" (it refuses paths with directories);
  `lrx` now runs in the target folder.
- Cancelling an XMODEM/YMODEM transfer mid-block could leave the remote receiver running (it
  only sees CAN between blocks). SerialTerm now aborts again if the receiver NAKs after a cancel.
- ZMODEM sender: duplicate `ZRPOS` requests (lrzsz repeats them while skipping in-flight data)
  caused cascading rewinds and "Too many errors". Repeats are now ignored, and stale queued
  output is discarded on a rewind.

### Verified on hardware
- Rockland MicroRider (native USB serial): ZMODEM in both directions, single files and batches,
  up to 134.6 MB, all MD5-verified. ~9.6 MB/s receiving; sending is limited by the device to
  ~2.3 MB/s. XMODEM and YMODEM (two-file batches) in both directions, MD5-verified; XMODEM to the
  MicroRider ~260 KB/s, XMODEM-1K ~390 KB/s.
