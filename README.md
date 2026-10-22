# SerialTerm

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE) [![CI](https://github.com/mousebrains/SerialTerm/actions/workflows/ci.yml/badge.svg)](https://github.com/mousebrains/SerialTerm/actions/workflows/ci.yml)

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
- **Paced typing**: limit typed and pasted text to so many characters a second, optionally wait
  for each character's echo, and pause after each line, for device command lines that drop
  characters sent too fast.
- **Presets**: save a window's line settings, Backspace key, typing pace and (optionally) port
  under a name, and apply them to any window from the toolbar.
- **Terminal**: xterm-compatible (SwiftTerm) and resizes with the window. You can send the window
  size to the remote with `stty`, and Backspace can send `^H` instead of DEL.
- **ZMODEM, built in**:
  - sends and receives multiple files, with CRC-32 and streaming error recovery;
  - starts automatically when the remote runs `sz` or `rz`; you can also drop files on the window;
  - never overwrites an existing file, removes partial files on failure, and refuses remote
    commands.
- **XMODEM / YMODEM, built in**: XMODEM with CRC-16 or checksum, in 128- or 1024-byte blocks;
  YMODEM batches with file names and sizes. SerialTerm types the device's `rx`/`rb` for you, and
  XMODEM receive starts when the device's `sx` announces itself.
- **Diagnostics**: each transfer writes a decoded protocol trace (headers or blocks, flags, file
  offers, errors, retries, and raw-byte snapshots around errors). Settings let you work around
  unusual ZMODEM implementations.
- **Logging**: session logs with millisecond timestamps, with RX and TX marked and non-printing
  bytes escaped.

## Install

Requires macOS 15 (Sequoia) or later. There is no release yet: until the first one, install with
Homebrew or build from source (below). The download will work from the first release on.

- **Homebrew**: builds from source, so macOS doesn't block it. Needs Xcode 26 or the Command
  Line Tools 26 or later.

  ```sh
  brew install --HEAD mousebrains/tap/serialterm
  serialterm                     # opens the app; `brew info serialterm` shows how to add it to Applications
  ```

  `--HEAD` builds the latest `main`; it won't be needed after the first release. Update with
  `brew upgrade --fetch-HEAD serialterm` (without `--fetch-HEAD`, brew doesn't check `main`).

- **Download** (from the first release): get `SerialTerm.zip` from
  [Releases](https://github.com/mousebrains/SerialTerm/releases).
  The app is not notarized, so macOS blocks it the first time: open it once, then click
  **Open Anyway** in **System Settings ▸ Privacy & Security**. Each new version needs this once.
- **Build from source** (requires Xcode 26 or later, or only the Command Line Tools:
  `xcode-select --install`):

  ```sh
  git clone git@github.com:mousebrains/SerialTerm.git
  cd SerialTerm
  ./scripts/make-app.sh          # → build/SerialTerm.app
  ```

## Quick start

1. Plug in the adapter and pick it from the **port** menu in the toolbar. This connects.
2. Pick the **baud rate**, or a saved setup from the **Presets** menu. Data bits, parity, flow
   control and the Backspace key are under the slider icon.
3. Type. While disconnected, typing connects to the selected port first.
4. To receive files, run `sz file…` on the device. To send, run `rz` on the device, or drop files
   on the window.

See the [User Guide](docs/user-guide.md) for everything else.

## Documentation

| | |
|---|---|
| [User Guide](docs/user-guide.md) | Connecting, settings, logging, file transfers, troubleshooting |
| [ZMODEM & Diagnostics](docs/zmodem.md) | What the built-in ZMODEM supports, trace format (all protocols), workarounds |
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

XMODEM and YMODEM were verified on the MicroRider in both directions when SerialTerm ran them
through lrzsz. The built-in XMODEM and YMODEM that replaced it are tested against lrzsz in both
directions, cleanly and over a simulated noisy line, but not yet on hardware. ZMODEM's error
recovery has also changed since the hardware runs (from testing with a TWR Slocum glider and code
reviews, [#4](https://github.com/mousebrains/SerialTerm/issues/4) and
[#9](https://github.com/mousebrains/SerialTerm/issues/9)). All three will be checked on the hardware
again before the first release. See the [Changelog](CHANGELOG.md) for details.

## License

Copyright © 2026 Pat Welch. SerialTerm is free software, licensed under the
[GNU General Public License v3.0 or later](LICENSE).

It uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT). The tests use
[lrzsz](https://ohse.de/uwe/software/lrzsz.html) (GPL) as the remote side; the app doesn't need it.
