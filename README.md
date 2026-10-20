# SerialTerm

[![CI](https://github.com/mousebrains/SerialTerminal/actions/workflows/ci.yml/badge.svg)](https://github.com/mousebrains/SerialTerminal/actions/workflows/ci.yml)

A macOS serial terminal for instruments and embedded devices on USB-serial adapters (FTDI,
SiLabs, WCH, Prolific, and native USB CDC devices). It has built-in ZMODEM that starts automatically,
detailed protocol diagnostics, and millisecond-timestamped session logs.

## Features

- **Ports**: USB adapters are listed by product name and serial number, and the list updates as
  adapters are plugged in or removed. After an unplug, SerialTerm reconnects automatically when
  the same adapter comes back.
- **Speed**: 300 baud to 3 Mbaud from a menu, or any custom rate.
- **Line**: 5–8 data bits, none/even/odd parity, 1–2 stop bits, RTS/CTS or XON/XOFF flow control.
  Changes take effect immediately.
- **Terminal**: xterm-compatible (SwiftTerm) and resizes with the window. You can send the window
  size to the remote with `stty`, and Backspace can send `^H` instead of DEL.
- **ZMODEM, built in**:
  - sends and receives multiple files, with CRC-32 and streaming error recovery;
  - starts automatically when the remote runs `sz` or `rz`; you can also drop files on the window;
  - never overwrites an existing file, removes partial files on failure, and refuses remote
    commands.
- **ZMODEM diagnostics**: each transfer writes a decoded protocol trace (headers, flags, file offers,
  errors, retries, and raw-byte snapshots around errors). Settings let you work around unusual
  implementations.
- **XMODEM / YMODEM**: through [lrzsz](https://ohse.de/uwe/software/lrzsz.html) for now.
  SerialTerm types the device's `rx`/`rb` for you, and XMODEM receive starts when the device's `sx`
  announces itself.
- **Logging**: session logs with millisecond timestamps, with RX and TX marked and non-printing
  bytes escaped.

## Install

Requires macOS 14 (Sonoma) or later.

- **Download**: get `SerialTerm.zip` from [Releases](https://github.com/mousebrains/SerialTerminal/releases).
  The app is not notarized, so the first time you open it, right-click it and choose **Open**.
- **Build from source** (requires Xcode 26 or later):

  ```sh
  git clone git@github.com:mousebrains/SerialTerminal.git
  cd SerialTerminal
  ./scripts/make-app.sh          # → build/SerialTerm.app
  ```

For XMODEM/YMODEM (and an optional lrzsz-based ZMODEM): `brew install lrzsz`.

## Quick start

1. Plug in the adapter and pick it from the **port** menu in the toolbar. This connects.
2. Pick the **baud rate**. Data bits, parity and flow control are under the slider icon.
3. Type. While disconnected, typing connects to the selected port first.
4. To receive files, run `sz file…` on the device. To send, run `rz` on the device, or drop files
   on the window.

See the [User Guide](docs/user-guide.md) for everything else.

## Documentation

| | |
|---|---|
| [User Guide](docs/user-guide.md) | Connecting, settings, logging, file transfers, troubleshooting |
| [ZMODEM & Diagnostics](docs/zmodem.md) | What the built-in ZMODEM supports, trace format, workarounds |
| [Architecture](docs/architecture.md) | Modules, threading, data flow |
| [Development](docs/development.md) | Building, testing (including against real hardware), CI, releasing |
| [Changelog](CHANGELOG.md) | |

## Status

The ZMODEM implementation has been tested against lrzsz in both directions, both cleanly and over a
simulated noisy line, and on a Rockland MicroRider (native USB serial) in both directions:

| Direction | Files | Result |
|---|---|---|
| MicroRider → Mac | 262 KB – 134.6 MB; batch of 3 (183 MB) | MD5 verified; ~9.6 MB/s; occasional lost USB data recovered automatically |
| Mac → MicroRider | batch of 3 (193.5 MB) | MD5 verified; ~2.3 MB/s, which is the MicroRider's receive limit (raw: 4.5 MB/s, 3.0 MB/s to storage) |

XMODEM and YMODEM (via lrzsz) are also verified on the MicroRider in both directions.

Next: native XMODEM/YMODEM; testing with a TWR Slocum glider. See the [Changelog](CHANGELOG.md) for
details.
