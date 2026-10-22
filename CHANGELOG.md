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
  - lrzsz ZMODEM sends had no back-pressure: on a slow line the whole file queued up, `lsz` timed
    out after about a minute, and Cancel waited behind the file. `lsz` is now held back as a tty
    would hold it, Cancel discards queued output, and a program that ignores SIGTERM is killed.
  - After a ZMODEM rewind or abort, the rest of the chunk being written kept going out, and waits
    for the line to drain could block forever under flow control. Both now stop.
  - Paced typing: Cancel left the echo wait running (the next key waited out the timeout and "No
    echo" appeared); the echo is now only looked for at the start of the device's reply; and the
    `rb`/`rx` commands typed for X/YMODEM sends now go at the typing pace.
  - Remote file names in session-log notes weren't escaped, so a name could forge a log line.
  - lrzsz receives kept names such as `.profile`; files are now saved under the built-in
    receiver's safe names. An XMODEM file name starting with `-` was read as an option by
    `lrx`/`rx`, and lrzsz messages kept embedded line breaks.
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
