# Development

## Requirements

- macOS 14 or later
- Xcode 26 or later (Swift 6.2 toolchain, required by SwiftTerm; the package uses Swift 5 language mode)
- `brew install lrzsz` (for the interop tests and for XMODEM/YMODEM)

If `xcode-select -p` points at the Command Line Tools, either run
`sudo xcode-select -s /Applications/Xcode.app` or prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `scripts/make-app.sh` does this for
you.

## Build and run

```sh
open Package.swift                 # Xcode: scheme "SerialTerm"
swift build                        # debug build
swift run SerialTerm               # run without a bundle (fine for development)
./scripts/make-app.sh              # release build → build/SerialTerm.app (ad-hoc signed)
VERSION=0.2.0 BUILD=7 ./scripts/make-app.sh
```

## Testing

```sh
swift test                                                    # everything (~5 s)
swift test --filter ZmodemNativeTransferTests                 # one suite
swift test -c release --filter ZmodemPerformanceTests         # throughput (release only)
```

| Suite | What it covers |
|---|---|
| `ZmodemDetectorTests` | Auto-start detection, including split and malformed headers |
| `SessionLoggerTests` | Log line format and escaping |
| `SerialPortPtyTests` | Real `SerialPort` I/O over a pseudo-terminal pair; binary transparency |
| `ZmodemCodecTests` | CRC check values, header and subpacket round trips, escaping, file-name safety |
| `ZmodemNativeTransferTests` | Native ↔ native: multi-file, block-boundary sizes, corrupted and dropped data, a corrupted back channel, cancel, timeouts, no overwriting |
| `ZmodemDiagnosticsTests` | Trace contents at each level; error snapshots; workaround options on the wire |
| `ZmodemEndToEndTests` | Native and lrzsz engines against lrzsz over a pty, both directions; noisy line; each workaround (skipped if lrzsz is missing) |
| `ZmodemPerformanceTests` | Encoder and end-to-end throughput floors (skipped in debug builds) |
| `HardwareProbeTests`, `HardwareSendTests`, `HardwareRawThroughputTests` | Real devices; skipped unless enabled (below) |

The pty-based tests give lrzsz pipes rather than the pty master itself, because lrzsz changes
and flushes its terminal's modes, and on a pty those are shared with our side. A real remote has
its own tty.

### Testing against real hardware

These tests talk to a device with a shell and lrzsz. SerialTerm must not have the port open
(disconnect it first). Run them in release mode for realistic speeds:

```sh
PORT=/dev/cu.usbmodemXXXX

# Open, send CR, print the reply
SERIALTERM_PROBE_PORT=$PORT swift test --filter HardwareProbeTests

# Send a file with native ZMODEM (types rz on the device), then md5sum it over the same line
SERIALTERM_PROBE_PORT=$PORT SERIALTERM_PROBE_SEND_FILE=/path/to/file \
SERIALTERM_PROBE_TRACE_DIR=/tmp/traces \
  swift test -c release --filter HardwareSendTests

# Raw receive throughput of the device (no protocol): 20 MB of 'A' into /dev/null and into ~/tpw
SERIALTERM_PROBE_PORT=$PORT SERIALTERM_PROBE_RAW=1 \
  swift test -c release --filter HardwareRawThroughputTests

# XMODEM/YMODEM in all four directions via the device's lrzsz, MD5-checked over the line
SERIALTERM_PROBE_PORT=$PORT SERIALTERM_PROBE_XMODEM=1 swift test --filter HardwareXmodemTests
```

The device's shell should be at a prompt in a scratch directory. The raw test writes and then
removes `~/tpw/rawtest.bin`; change the path in the test for other devices.

## Continuous integration

`.github/workflows/`:

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | push to `main`, pull requests | On macOS: install lrzsz, build, run all tests (debug), run the performance tests (release), build the app bundle and upload it as an artifact |
| `release.yml` | tag `v*` (e.g. `v0.2.0`) | Run the tests, build `SerialTerm.app` with the tag's version, zip it, and publish a GitHub release with the zip and its SHA-256 |

Dependabot (`.github/dependabot.yml`) opens weekly pull requests for GitHub Actions and Swift
package updates.

## Releasing

1. Update `CHANGELOG.md` (move *Unreleased* to the new version).
2. `git tag v0.2.0 && git push origin v0.2.0`
3. The release workflow builds and publishes. Releases are ad-hoc signed and not notarized; users
   open them with right-click ▸ Open the first time. For notarized builds, add a Developer ID
   certificate and `notarytool` credentials as repository secrets and extend `release.yml`.

## Conventions

- `SerialCore` stays free of AppKit and SwiftUI.
- Protocol code runs on its own thread as blocking code; UI state is `@MainActor`.
- New behavior comes with tests. Transfer changes should be checked against lrzsz, not only
  against the native implementation.
- Comments explain *why*, especially for protocol behavior.
