# Development

## Requirements

- macOS 15 or later
- Xcode 26 or later, or only the Command Line Tools 26 or later (`xcode-select --install`): the
  Swift 6.2 toolchain, required by SwiftTerm; the package uses Swift 5 language mode
- `brew install lrzsz`, which plays the remote device in the interop tests (the app doesn't need it)

`swift build` and `swift test` use whichever `xcode-select -p` points at, unless `DEVELOPER_DIR`
is set. `scripts/make-app.sh` uses Xcode when it's installed.

With only the Command Line Tools, a clean build of the tests sometimes fails with "plugin for
module 'TestingMacros' not found" in `ZmodemDetectorTests.swift` or `ZmodemPerformanceTests.swift`.
That is a toolchain problem: it happened in 5 of 7 clean builds on 2026-10-21 (CLT 27.0.0, Swift
6.4), on `main` too, and building again finished each time. Xcode builds aren't affected, and the
app itself always builds.

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
swift test                                                    # everything (~35 s)
swift test --filter ZmodemNativeTransferTests                 # one suite
swift test -c release --filter ZmodemPerformanceTests         # throughput (release only)
```

| Suite | What it covers |
|---|---|
| `ZmodemDetectorTests` | Auto-start detection, including split and malformed headers |
| `SessionLoggerTests` | Log line format and escaping |
| `SerialPortPtyTests` | Real `SerialPort` I/O over a pseudo-terminal pair; binary transparency |
| `CoreRobustnessTests` (several suites) | Log and trace files (name collisions, write failures, escaping), paced-typing cancel and echo matching, refused baud rates, discards and cancellable waits, transfers that can't start, closing mid-transfer, the automatic-start back-off |
| `ZmodemSenderRobustnessTests` | The sender against scripted receivers and a rate-limited line (`SlowLine`, `FakeReceiver`): noise, cancel, lost replies, receivers that go quiet, go away or advertise a buffer |
| `ZmodemReceiverRobustnessTests`, `ZmodemSessionLeftoverTests` | The receiver against broken and hostile senders; false automatic starts; the prompt after a transfer |
| `SerialTermTests` (app target) | Port matching, preference decoding and clamping, preset names, baud parsing, the terminal mode reset, the port scanner's cleanup, the window-close hook |
| `ZmodemCodecTests` | CRC check values, header and subpacket round trips, escaping, file-name safety |
| `ZmodemNativeTransferTests` | Native ↔ native: multi-file, block-boundary sizes, corrupted and dropped data, a corrupted back channel, cancel, timeouts, no overwriting |
| `ZmodemDiagnosticsTests` | Trace contents at each level; error snapshots; workaround options on the wire |
| `ZmodemEndToEndTests` | ZMODEM, YMODEM and XMODEM against lrzsz over a pty, both directions; noisy line; each ZMODEM workaround; XMODEM checksum and CRC, 128 and 1K blocks (skipped if lrzsz is missing) |
| `LineEmulatorTests` | The emulated line itself: its rate, latency, jitter that keeps order, holding a writer off, overrun, USB-style packets, seeded damage, outages, stalls |
| `TransfersOverEmulatedLineTests` | Sessions at both ends of an emulated line, or lrzsz on its own terminal at one: a fast cable through an adapter, a noisy line, a satellite call, YMODEM from `lsb` over slow and uneven lines, receivers that lose replies or go quiet after errors (a Slocum glider at 921600), and late answers to a file offer and to ZEOF |
| `XmodemCodecTests`, `XmodemNativeTransferTests`, `XmodemScriptedTests` | Block and YMODEM header encoding; native ↔ native at every block-boundary size, checksum mode, noise both ways, cancel from either end, no overwriting; scripted peers for the handshake (an echoed 'C'), EOT, out-of-step blocks, leftovers |
| `ZmodemPerformanceTests` | Encoder and end-to-end throughput floors (skipped in debug builds) |
| `HardwareProbeTests`, `HardwareSendTests`, `HardwareReceiveTests`, `HardwareRawThroughputTests`, `HardwareXmodemTests` | Real devices; skipped unless enabled (below) |

The pty-based tests give lrzsz pipes rather than the pty master itself, because lrzsz changes
and flushes its terminal's modes, and on a pty those are shared with our side. A real remote has
its own tty.

#### The emulated line

`LineEmulator` (in the tests) joins two pseudo-terminals with an emulated serial line: pty ↔ line ↔
pty. A `SerialPort` opens one end; the other end takes a second `SerialPort` or a program such as
lrzsz, which gets that pty as its own terminal. Each direction has its own settings:

- **Time:** a line rate in baud (any rate, 1200 baud to several Mbaud, whatever the ptys' termios
  rate), a latency, and jitter (uniform, exponential, or an error-correcting modem's resends).
  Jitter delays whole packets and never reorders them. A stall holds up the packet that completes
  a chosen pattern, and everything behind it, once: a reply that's late for whatever reason.
- **Packets:** a size and an idle timer, as a radio or satellite modem sends, or a USB adapter
  (an FTDI chip sends 62-byte packets and holds a partial one for its latency timer).
- **Buffering:** a buffer that holds the writer off when it's full, or loses what doesn't fit
  (a modem without flow control, or a device slower than its line).
- **Damage:** random bit errors, lost bytes and noise from a seed, so a failure replays exactly;
  outages at set times; and the scripted filters the in-memory tests use (`Mangler`,
  `HeaderDropper` and so on).

Unlike the in-memory links, the line takes time: a sender's timeouts start when its data has gone,
not when it's queued, as on hardware. `log` records every byte delivered, damaged or lost, with its
time: when a transfer fails, the tests print every trace from both sides and the end of the wire log.

### Testing against real hardware

These tests talk to a device with a shell and lrzsz (`sz`/`rz`, `sx`/`rx`, `sb`/`rb`). SerialTerm must not have the port open
(disconnect it first). Run them in release mode for realistic speeds:

```sh
PORT=/dev/cu.usbmodemXXXX

# Open, send CR, print the reply
SERIALTERM_PROBE_PORT=$PORT swift test --filter HardwareProbeTests

# Send a file with native ZMODEM (types rz on the device), then compare MD5s over the same line
SERIALTERM_PROBE_PORT=$PORT SERIALTERM_PROBE_SEND_FILE=/path/to/file \
SERIALTERM_PROBE_TRACE_DIR=/tmp/traces \
  swift test -c release --filter HardwareSendTests

# Receive a file with native ZMODEM (types sz on the device; the receive starts by itself),
# then compare MD5s. The path is on the device, relative to its shell's directory.
SERIALTERM_PROBE_PORT=$PORT SERIALTERM_PROBE_RECEIVE_FILE=big.bin \
SERIALTERM_PROBE_TRACE_DIR=/tmp/traces \
  swift test -c release --filter HardwareReceiveTests

# Raw receive throughput of the device (no protocol): 20 MB of 'A' into /dev/null and into ~/tpw
SERIALTERM_PROBE_PORT=$PORT SERIALTERM_PROBE_RAW=1 \
  swift test -c release --filter HardwareRawThroughputTests

# Built-in XMODEM/YMODEM in all four directions with the device's lrzsz, MD5-checked over the line
SERIALTERM_PROBE_PORT=$PORT SERIALTERM_PROBE_XMODEM=1 swift test --filter HardwareXmodemTests

# FTDI adapters on Apple's driver: the latency requests set the chip's timer (no device needed on the line)
SERIALTERM_PROBE_PORT=$PORT SERIALTERM_PROBE_FTDI=1 swift test --filter HardwareFTDILatencyTests
```

The device's shell should be at a prompt in a scratch directory. The raw test writes and then
removes `~/tpw/rawtest.bin`; change the path in the test for other devices.

## Continuous integration

`.github/workflows/`:

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | push to `main`, pull requests | On macOS: reject Xcode-only SwiftUI macros, install lrzsz, build, run all tests (debug), run the performance tests (release), build the app bundle and upload it as an artifact; run the threaded suites under Thread Sanitizer; separately, build the app bundle with only the Command Line Tools |
| `release.yml` | tag `v*` (e.g. `v0.2.0`) | Run the tests, build `SerialTerm.app` with the tag's version and zip it, with a read-only token; then, in a separate job that runs nothing else, publish a GitHub release with the zip and its SHA-256 |

Workflows get a read-only token unless a job asks for more (only the release's publish job does),
actions are pinned to commit SHAs (Dependabot keeps them current), and the Swift package cache is
keyed by the Xcode version as well as `Package.resolved`.

Dependabot (`.github/dependabot.yml`) opens weekly pull requests for GitHub Actions and Swift
package updates.

## Releasing

1. Update `CHANGELOG.md` (move *Unreleased* to the new version).
2. `git tag v0.2.0 && git push origin v0.2.0`
3. The release workflow builds and publishes. Releases are ad-hoc signed and not notarized; users
   allow each new version once with Open Anyway in System Settings ▸ Privacy & Security. For
   notarized builds, add a Developer ID
   certificate and `notarytool` credentials as repository secrets and extend `release.yml`.
4. Update the formula in [mousebrains/homebrew-tap](https://github.com/mousebrains/homebrew-tap):
   `url` is the tag's source tarball
   (`https://github.com/mousebrains/SerialTerm/archive/refs/tags/v0.2.0.tar.gz`), and `sha256` is
   its checksum (`curl -L <url> | shasum -a 256`). The first time, also drop `--HEAD` from the
   tap's CI and from both READMEs.

## Conventions

- `SerialCore` stays free of AppKit and SwiftUI.
- Protocol code runs on its own thread as blocking code; UI state is `@MainActor`.
- No SwiftUI `State`, `Entry`, `Animatable` or `AnimatableIgnored` attributes: in the macOS 27 SDK
  they are macros whose compiler plugin ships only with Xcode, so they break builds with the
  Command Line Tools. Keep view state in an `ObservableObject` held by `@StateObject`. CI checks.
- New behavior comes with tests. Transfer changes should be checked against lrzsz, not only
  against SerialTerm's own other end.
- Comments explain *why*, especially for protocol behavior.
