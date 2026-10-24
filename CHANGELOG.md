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
- Transfer traces start with the line settings, the USB adapter, the macOS driver, whether the
  driver accepted the 1 ms receive-latency request, and the macOS version. The session log gets
  them on connect, or when recording starts on an open port.
  - Adapter: product and vendor, VID:PID, chip revision, serial number and USB speed.
  - Why: adapters differ in how long they hold a partial USB packet, and that shows in transfer
    timing.
- ZMODEM send: a block size above 1024 now falls back to 1024 when the receiver keeps rejecting
  the data (two restarts in a row without progress). Previously the same block was resent until
  the send failed: a Slocum glider takes at most 1024-byte subpackets.
- FTDI adapters no longer hold every reply for ~230 ms.
  - Cause: SerialTerm asked the driver for 1000 µs of receive latency (`IOSSDATALAT`). Apple's FTDI
    driver writes the low byte of that value to the chip's latency timer as milliseconds, so it
    became 232 ms.
  - Now: SerialTerm asks for 16 while idle (FTDI's default) and 1 during a transfer. The trace
    header records both requests and what the chip's timer reads.
  - Effect with a Slocum glider at 921,600: ~0.48 s less between files on a pull (a 10-file batch
    took 73.7 s instead of 78.0 s), and 19 KB/s instead of 4.4 KB/s when sending with an ACK every
    1 KB.
  - Idle cost: 16 rather than 1 keeps the FTDI driver at ~0.6% of a core while connected, not
    ~4.6%.
- ZMODEM workarounds: block size, forced ACK window, force CRC-16, escape all control characters,
  timeout.
- Native XMODEM (CRC-16 or checksum, 128- or 1024-byte blocks) and YMODEM (batches with names,
  sizes and modification times): sends type the device's `rx`/`rb`; XMODEM receive starts when
  lrzsz's `sx` announces itself; protocol traces like ZMODEM's; YMODEM files get the same safe names
  as ZMODEM's, and an XMODEM receive replaces the chosen file only once it has all arrived.
- Tests: codec, native↔native over corrupting links, interop with lrzsz over ptys (clean and
  noisy), traces, performance, and opt-in tests against real hardware.
- CI on GitHub Actions; tagged releases.
- Homebrew: `brew install --HEAD mousebrains/tap/serialterm` builds the app from source, so
  macOS doesn't block it ([mousebrains/homebrew-tap](https://github.com/mousebrains/homebrew-tap)).

- XMODEM-1K option (Settings ▸ Transfers): 1024-byte blocks, ~1.5× faster to the MicroRider.
- Licensed GPL-3.0-or-later.
- App icon: a green-screen terminal reading SERIAL / TERM, with a `>_` prompt at the small sizes.

### Changed
- XMODEM and YMODEM, which ran through lrzsz during development, are built in, so lrzsz is no
  longer needed on the Mac (the tests still use it as the remote side). The setting to run ZMODEM
  through lrzsz is gone. Transfer ▸ Open Last ZMODEM Trace is now Open Last Transfer Trace.
- Requires macOS 15 or later (was 14).
- Builds with only the Command Line Tools; Xcode is optional. (A clean build of the tests with only
  the Command Line Tools sometimes fails with "plugin for module 'TestingMacros' not found", a
  toolchain problem; building again finishes it.)

### Fixed
- ZMODEM send could livelock with lrzsz's `rz` after a resend's `ZDATA` header was lost. Seen once
  on CI (PR #17).
  - The receiver kept asking for the same offset, and the sender ignored those repeats as
    duplicates. It then waited a full 10 s for an answer to `ZEOF` before resending.
  - lrzsz's timeout is also 10 s, so each resend crossed the receiver's next `ZRPOS` (after which
    it skips input) and was lost the same way, until it gave up.
  - Now, without an answer within the duplicate window (≥ 2 s from the last repeat), the sender
    resends.
  - Test: `recoversWhenTheResendsHeaderIsLost` drops the resend's header on the way to `lrz`. It
    took 10.4 s before (at least one full timeout) and 2.5 s after.
- Found in an adversarial review ([#4](https://github.com/mousebrains/SerialTerm/issues/4)), core:
  - The app crashed if a session log or ZMODEM trace couldn't be written (disk full, volume
    removed): Foundation's `FileHandle.write` raises an exception. The log or trace now stops and
    the status bar says so.
  - Two windows starting logs in the same second shared one file and overwrote each other's
    lines, and traces started in the same second replaced each other. Each now gets its own file
    (`-2`, `-3`, …); an existing file is never replaced.
  - Disconnecting or switching ports mid-transfer left both ends running: the abort never reached
    the device, and the transfer (or an lrzsz program) carried on. The transfer is now cancelled
    and the device told to stop before the port closes.
  - A transfer that failed to start (a missing download folder, say) left the window showing a
    transfer in progress, with a Cancel that did nothing, after typing `rb`/`rx` to the device. The
    failure is now reported and nothing is typed.
  - A baud rate the driver refused left the line at 9600 with the new framing; the previous
    settings are now restored.
  - After a ZMODEM rewind or abort, the rest of the chunk being written kept going out, and waits
    for the line to drain could block forever under flow control. Both now stop.
  - Paced typing: Cancel left the echo wait running (the next key waited out the timeout and "No
    echo" appeared); the echo is now only looked for at the start of the device's reply; and the
    `rb`/`rx` commands typed for X/YMODEM sends now go at the typing pace.
  - Remote file names in session-log notes weren't escaped, so a name could forge a log line.
  - An XMODEM file name starting with `-` was read as an option by the device's `rx`.
  - A remote that kept starting and aborting transfers restarted one many times a second;
    automatic starts now pause for 30 s after three quick failures.
  - Data races on the session's settings (found with Thread Sanitizer) and the trace's counters,
    and a race that could send serial I/O to a reused descriptor number after a close.
- Review (#4), ZMODEM:
  - A sender could crash the app with huge numbers in a file offer (integer overflow); offer
    fields are now clamped and the progress maths can't overflow.
  - One stray `*` or CAN on the back channel aborted a send; it is now skipped.
  - Cancel during a send took effect only at the end of the file, and never while flow control
    held the line; it now takes effect within a subpacket.
  - The send's limit of 30 rewinds per file counted rewinds that made progress, so a receiver that
    overruns after every burst (a Slocum glider at 921600) failed files needing more than about 15
    recoveries. Now 30 in a row without progress, with an overall limit that grows with the file.
  - After an unanswered ZEOF the sender resent from the receiver's last `ZRPOS`, usually 0 when
    streaming: a whole extra copy, or three to a receiver that had gone. A `ZCRCQ` every 32 KB now
    keeps the receiver's position current, and a late `ZRINIT` is accepted.
  - The ZEOF, ZACK and file-offer waits could loop forever on replies that weren't timeouts
    (`ZNAK`, `ZACK`, noise). This predates the stale-ZEOF fix below, which kept it.
  - Up to 80 KB of queued file data went out after an abort, a remote cancel or a mid-stream
    `ZSKIP`, into the remote's shell. It is now discarded.
  - Windowed sends timed the `ZACK` wait from when the window was queued, so slow lines failed
    with "Too many errors" and no line errors; and the sender overran receivers' advertised
    buffers (more bytes between ACKs, and bigger subpackets, than the buffer).
  - The receiver's wait for a file never ended while bytes kept arriving: a false automatic start
    swallowed a streaming instrument's output and sent it ZRINITs, and a device echoing our ZRINIT
    got another one, forever. It now gives up on noise and echoes, and shows what arrived.
  - The receiver could be kept from asking for data again by fast stale ZEOFs, trickling noise or
    headers it ignores; it now asks whenever no new data has come for the timeout.
  - A timeout inside a file offer aborted the whole batch instead of answering `ZNAK`.
  - The receiver's 50-errors-per-file budget didn't renew with progress, so long files on noisy
    links failed.
  - The remote's prompt right after a transfer was swallowed.
  - File names: bidirectional overrides, zero-width and C1 control characters are removed, long
    names are shortened instead of the file being skipped, files are created without ever
    replacing one (even one another window just created), and received files are quarantined
    like downloads. Names are escaped in logs and traces.
  - The receive command (`rz`/`zr`) now goes at the typing pace; timeouts use a clock that doesn't
    jump; files of 4 GiB or more are refused up front; and the duplicate-`ZRPOS` window is longer
    on slow lines.
- Review (#4), app:
  - Auto-reconnect could switch a window to another instrument: a USB serial number from a
    previous adapter survived a switch to one without a serial number. And every port of a
    multi-port adapter (FT2232, FT4232) shares one serial number, so reconnects and presets picked
    the first port. Ports are now matched by name and serial number first, then by serial number
    and USB interface only when that's unambiguous.
  - Replies the terminal makes by itself (focus and mouse reports) reconnected a disconnected
    window, and modes one device turned on (mouse reporting, bracketed paste, the alternate
    screen) carried over to the next. Only typing and pasting connect now, and each new
    connection resets those modes.
  - A refused baud rate stayed in the window and in the saved settings; they now go back to what
    the port is using. Auto-reconnect gave up for good after one failed open.
  - The Log button showed "recording" when no log could be opened; it now shows ⚠, and the status
    bar says "Not logging".
  - Transfer and line controls stayed enabled when they couldn't work (disconnected, or during a
    transfer), and file panels could stack up. Quitting during a transfer now asks first; closing
    the window is blocked until the transfer is cancelled.
  - Every window reopened with the last-used window's port; each now gets its own back.
  - Option is no longer always Meta: *Use Option as Meta key* in Settings ▸ General (on by default).
  - Settings: one unreadable preset no longer loses all of them, unreadable settings are kept
    aside before defaults replace them, preset names must be non-empty and distinct, values are
    kept in range (a negative baud rate trapped), and a custom baud must be digits only ("1e6" was
    read as 16).
  - Messages: the trace hint appears only for a failure that wrote a trace, a cancel says so, an
    unplug's reason is no longer overwritten, and only transfers you started beep on failure. Late
    events from a closed session can't affect the window's new one.
- Review (#4), docs and CI:
  - `docs/zmodem.md` described the old send command, recovery and limits; the README offered
    Homebrew and download installs that don't exist before the first release.
  - The release workflow pasted the tag name into a shell script and held a write token while
    running Homebrew and the tests; it now passes the tag through the environment and publishes
    from a separate job. Actions are pinned to commit SHAs, workflows get read-only tokens, and
    the package cache is keyed by Xcode version.
  - CI runs the threaded suites under Thread Sanitizer. A hardware test for receiving with native
    ZMODEM was added, and the hardware send test now compares MD5s itself.
- Found in a second review ([#9](https://github.com/mousebrains/SerialTerm/issues/9)), core:
  - An XMODEM send typed the file name at the device's shell with only `'` escaped: a newline in
    the name ended the `rx` command and ran the rest. Only printable ASCII is typed now; anything
    else becomes `_` (the log notes it).
  - Files received through lrzsz (YMODEM, XMODEM, the lrzsz ZMODEM option) weren't marked as
    downloaded; they are now quarantined like the built-in receiver's.
  - A ZMODEM send mapped the file into memory, so a file on a volume that went away (USB stick
    pulled, share dropped) crashed the app with SIGBUS. Files are now read as they go; one that
    gets shorter meanwhile fails the send.
  - Disconnecting mid-transfer could hold up the window for up to 2 s; it now closes in the
    background.
  - A failed write (device gone) left the port open with every write failing; it now closes the
    port and reports the error.
  - Session logging escaped binary data on the serial read queue at ~3 MB/s; it now escapes on
    the logger's queue at ~78 MB/s.
  - With *Wait for each character's echo*, the first character of each line waited out the echo
    timeout when the device's output and prompt came to over 32 bytes before its echo.
  - A `ZRQINIT` split across reads lost the read that completed it (the trace didn't show the
    opening frame).
  - Smaller: the serial port's descriptor is no longer inherited by programs the app starts;
    write and command waits use a clock that doesn't jump; on very slow lines (below ~440 baud)
    the sender waits longer for the rest of a back-channel header.
- Review (#9), app:
  - Auto-reconnect could switch a window from a device without a USB serial number to another
    device, with one, plugged in where it was (CDC devices are named after the USB socket).
  - Closing a window didn't disconnect it, so its log missed the closing lines.
  - The port scanner didn't free its IOKit notifications when released (latent: the app keeps
    one for its lifetime).
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
