# ZMODEM & Diagnostics

SerialTerm has its own ZMODEM implementation (`Sources/SerialCore/Zmodem/`). This page covers what
it supports, how it behaves, how to read its protocol traces (XMODEM and YMODEM write them too),
and the settings that work around unusual peers.

- [What's supported](#whats-supported)
- [Automatic start](#automatic-start)
- [Sending](#sending)
- [Receiving](#receiving)
- [Error recovery](#error-recovery)
- [Protocol traces](#protocol-traces)
- [Reading a trace](#reading-a-trace)
- [XMODEM and YMODEM traces](#xmodem-and-ymodem-traces)
- [Workarounds](#workarounds)
- [Testing](#testing)

## What's supported

| Feature | Status |
|---|---|
| Batch send and receive (any number of files) | ✓ |
| CRC-16 and CRC-32 (CRC-32 whenever the peer offers it) | ✓ |
| Hex, binary (`ZBIN`) and binary CRC-32 (`ZBIN32`) headers | ✓ |
| Streaming (`ZCRCG`), with `ZRPOS` rewind on errors | ✓ |
| Windowed sending (`ZCRCW` + `ZACK`) for receivers with a small buffer, or when forced | ✓ |
| `ZCRCQ` (receiver acknowledges mid-stream) | ✓ answered when receiving; sent every 32 KB when streaming |
| Escaping all control characters (`ESCCTL`) | ✓ both directions |
| `ZSINIT` (sender's attention string) | acknowledged and ignored |
| `ZCHALLENGE`, `ZFREECNT`, `ZCRC` (file CRC request) | ✓ |
| `ZCOMMAND` (remote command execution) | refused, never run |
| Resuming an interrupted file (`ZCRESUM`) | not yet; received files always start at 0 |
| File conversion options (text/CRLF) | ignored; all files are binary |

## Automatic start

SerialTerm watches incoming data for the two headers that start a ZMODEM transfer, even when a
header is split across reads:

- `**` ZDLE `B00` (`ZRQINIT`): the remote ran `sz`. SerialTerm starts receiving and passes on the
  remote's opening frame, so it appears in the trace.
- `**` ZDLE `B01` (`ZRINIT`): the remote ran `rz`. SerialTerm opens a file picker. If you cancel the
  picker, SerialTerm sends the abort sequence so the remote `rz` exits.

Automatic start can be turned off in Settings ▸ Transfers.

## Sending

1. Type the window's receive command and Return (`rz` by default, `zr` for Slocum gliders, or
   nothing; set under the slider button and in presets). This starts the receiver if the remote
   is at its prompt; a receiver that is already running skips it as noise. With paced typing on,
   it goes out at that pace. Then send a `ZRQINIT` header.
2. Wait for `ZRINIT`, which gives the receiver's capabilities and buffer size. A `ZRQINIT` echoed
   by the remote shell before `rz` starts is recognized and ignored.
3. For each file: `ZFILE` with the file offer
   `name NUL size mtime(octal) mode(octal) 0 files-left bytes-left NUL`. The receiver answers
   `ZRPOS` (where to start) or `ZSKIP`.
4. `ZDATA` at that position, then data subpackets of the configured block size (default 1024),
   never larger than the receiver's buffer:
   - **Streaming** when the receiver advertises buffer 0 with `CANFDX|CANOVIO`. Subpackets are
     `ZCRCG`, except a `ZCRCQ` every 32 KB, which asks the receiver to confirm its position
     (`ZACK`) without stopping. The sender checks the back channel for `ZRPOS` and `ZACK` between
     subpackets without stopping.
   - **Windowed** when the receiver has a buffer, lacks `CANOVIO`/`CANFDX`, or the window setting is
     on. The sender sends `ZCRCW` after every *window* bytes (never more) and waits for `ZACK`,
     timing the wait from when the window has gone out.
5. `ZEOF` with the file length. The receiver answers `ZRINIT` when it has everything.
6. After the last file: `ZFIN`, the receiver answers `ZFIN`, and the sender sends `OO`.

Output is written in 16 KB batches, with at most 64 KB queued at the serial port. On a `ZRPOS`,
the sender drops its queued output, stops the batch being written, and flushes the driver's
buffer, so the resend starts within about one batch's time on the line (roughly 0.2 s at
921600 baud, 1.4 s at 115200).

Files of 4 GiB or more are refused before the transfer starts: ZMODEM positions are 32 bits.

## Receiving

- SerialTerm advertises `CANFDX|CANOVIO|CANFC32` with buffer 0, meaning the sender may stream.
  With *Force CRC-16* it omits `CANFC32`; with *Escape all control characters* it adds `ESCCTL`.
- File names are made safe: path components are removed; control characters, invisible
  formatting characters (bidirectional overrides, zero-width characters) and `:` are removed;
  leading dots are dropped; and long names are shortened to fit the file system. An empty name
  becomes `received`. Existing files are never overwritten, even one created a moment earlier by
  another window, and a symlink is never followed; the new copy is saved as `name (1).ext`.
- Received files are marked as downloaded (`com.apple.quarantine`), as browsers do, so macOS
  checks a received app or script before it can run.
- The modification time is set from the file offer. Sizes and counts in the offer are clamped to
  sensible ranges.
- If the received length differs from the announced size, the session log notes it.
- If the transfer fails, the partial file is deleted.
- The remote's prompt after the transfer is shown in the terminal, even when it arrives together
  with the final `ZFIN`.
- If what started the receive turns out not to be a transfer (no file is offered: only noise, or
  our own `ZRINIT` echoed back), the receiver gives up quickly, and the terminal shows what
  arrived meanwhile. Three such failures within 30 s pause automatic starts for 30 s.

## Error recovery

The receiver keeps the offset of the last good byte. On a CRC error, an invalid escape, an
oversize subpacket, data at the wrong offset, or a timeout, it sends `ZRPOS` with that offset and
then ignores everything until a `ZDATA` header for that offset arrives. The sender, on `ZRPOS`,
drops any output not yet written and restarts from the requested offset.

lrzsz's receiver repeats `ZRPOS` while it skips the data that was in flight, so the sender
ignores a repeat of the offset it restarted from within the last 2 s (longer on slow lines,
where the data in flight takes longer to drain). A quick repeat can also be genuine, when the
data right after the restart was damaged too, or the restart's `ZDATA` header was lost. Then the
receiver ignores the sender's `ZEOF`, because it doesn't have the data yet. If no answer comes
within that same 2 s (from the last repeat), the sender takes the repeats as genuine and restarts
from that offset.

It doesn't wait out the whole timeout: lrzsz's own timeout is also 10 s. Waiting the full 10 s
fell into step with it, so every restart crossed the receiver's next `ZRPOS`, which it follows by
skipping input. The restart's header was lost each time, and the transfer failed after three
rounds.

Some receivers (Slocum gliders at 921600 baud) go quiet after losing data, without asking for it
again, or their request is lost. If `ZEOF` gets no reply, the sender resends from the last
position the receiver confirmed (its last `ZRPOS` or `ZACK`; the `ZCRCQ` every 32 KB keeps that
recent): a receiver waiting there takes the data, and one elsewhere answers with a `ZRPOS` giving
its position. It does this up to three times in a row without progress. A `ZRINIT` that arrives
late, after such a resend has started, is taken as the answer to `ZEOF`.

The receiver asks for data again (`ZRPOS`) whenever it has had no new data for the timeout,
however busy the line is meanwhile with other traffic: stale `ZEOF`s, headers it ignores, or
noise. A stray `*` or CAN on the sender's back channel is skipped rather than taken for the
start of a header.

Limits:
- Sending: 30 rewinds in a row without the receiver confirming new data, and 30 plus one per KB
  of the file in all; 6 `ZRQINIT`s for the handshake; 10 offers per file; 10 `ZEOF`s per attempt;
  each wait for a reply lasts at most the timeout, whatever else arrives.
- Receiving: 50 resend requests in a row without progress, and 50 plus one per 4 KB received in
  all. While waiting for a file: 10 silent timeouts, 16 bad headers or runs of noise, noise for
  one timeout without a valid header, 3 echoes of our own `ZRINIT`, or 40 headers without a file.
  A damaged or truncated file offer is answered with `ZNAK`, so the sender offers it again.

Five consecutive CAN bytes (`0x18`) from the remote abort the transfer. A local cancel, or a fatal
error, drops the output still queued, then sends ten CANs and ten backspaces. The backspaces erase
the CANs if the remote has already returned to a shell. Cancel takes effect within one
subpacket, even while streaming, and even if flow control is holding the line. Closing the window
or the connection during a transfer cancels it the same way.

## Protocol traces

Every transfer writes a trace to the log folder, named `SerialTerm-YYYY-MM-DD-HHMMSS-zmodem.log`
(`-ymodem.log`, `-xmodem.log` for those protocols). The trace is written whether or not session
logging is on. Open the latest one with **Transfer ▸ Open Last Transfer Trace** (it opens in
Console).

Choose the level in Settings ▸ Transfers ▸ Diagnostics:

| Level | Contents |
|---|---|
| Off | No trace |
| **Frames** (default) | Every header in both directions, decoded; file offers as sent; summaries of data runs; bad headers and subpackets with the reason; skipped bytes with a hex sample; timeouts (and what was awaited); every retry and rewind; an error snapshot for each bad subpacket; a closing summary |
| Frames + raw bytes | All of the above, plus every data subpacket and a hex/ASCII dump of all line traffic. Large: roughly 4× the file size |

Each line starts with the local time and the seconds since the transfer started, then the
direction: `RX` (from the remote), `TX` (to the remote), or `--` (a note).

Every trace begins with notes on the connection:

- **`port:`**: the device and its line settings.
- **`adapter:`**: the USB product and vendor names, VID:PID, chip revision (`bcdDevice`), serial
  number and USB speed.
- **`driver:`**: the macOS driver serving the port. A DriverKit driver shows as
  `IOUserSerial (its class), its bundle`.
- **`receive latency:`**: the receive latency SerialTerm asked of the driver while idle
  (`IOSSDATALAT`, 16), and whether the driver accepted it.
- **`FTDI latency timer:`** (FTDI adapters only): what the chip's timer reads.
- **`for the transfer, …`**: the same two, after switching to the transfer's latency (1).
- **`host:`**: the macOS version.

The session log gets the same notes when a port is opened, or when recording starts on a port that
is already open.

### Receive latency and FTDI adapters

Adapters differ in how long they hold the last partial USB packet of a burst. That shows in a
transfer's timing wherever the sender stops to wait for a reply.

- **What the FTDI timer does:** an FTDI chip sends a partial packet when its latency timer runs out.
  FTDI's default is 16 ms.
- **How Apple's driver sets it:** Apple's FTDI driver (`AppleUSBFTDI`) sets the timer from
  `IOSSDATALAT`. The request is defined in microseconds, but the driver writes the value's low byte
  as milliseconds: 1000 becomes 232, 16 becomes 16, 1 becomes 1.
- **What that cost:** SerialTerm used to ask for 1000 (meaning 1 ms). That held every reply for
  about 230 ms, adding ~0.48 s per file to a pull from a Slocum glider.
- **What SerialTerm asks for now:** 16 while idle, which is FTDI's default and costs the driver
  ~0.6% of a core, and 1 during a transfer. At 1 the driver would take ~4.6% of a core even with the
  line idle.
- **Other drivers:** those values mean 16 µs and 1 µs, so no added latency either way.

## Reading a trace

A clean receive:

```
12:11:37.602 +0.002  -- opening bytes that triggered auto-start:
12:11:37.602 +0.002  RX   2a 2a 18 42 30 30 30 30 30 30 30 30 30 30 30 30 30 30 0d 8a 11
12:11:37.602 +0.003  RX ZRQINIT hex  zf0=00 zf1=00 zf2=00 zf3=00
12:11:37.602 +0.003  TX ZRINIT hex  caps=CANFDX|CANOVIO|CANFC32 buffer=0 (stream) zf1=00
12:11:37.604 +0.004  RX ZFILE bin32  conv=none mgmt=00 transport=00 ext=00
12:11:37.604 +0.004  RX   file "RIOT_SL684_0541.p" fields "58642907 15265734576 100666 0 1 58642907" → size 58642907, …
12:11:37.605 +0.005  TX ZRPOS hex  pos=0
12:11:37.619 +0.019  RX ZDATA bin32  pos=0
12:11:43.660 +6.060  RX   data 0..<58642907 (58642907 bytes)
12:11:43.660 +6.060  RX ZEOF bin32  pos=58642907
```

What to look at:

- **Header format** (`hex`, `bin16`, `bin32`): shows whether the peer uses CRC-32.
- **`caps=`** in the peer's `ZRINIT`: its capability flags (`CANFDX`, `CANOVIO`, `CANFC32`,
  `ESCCTL`, …) and `buffer=`. Unusual implementations usually show up here first.
- **`fields "…"`** in a file offer: exactly what the sender wrote after the name. Decimal size,
  octal mtime and mode, serial, files left, bytes left.
- **`skipped N non-header bytes: …`**: data outside any frame. After an error this is in-flight
  data being discarded, which is normal. Elsewhere it can be shell output, an echo, or noise.
- **`bad subpacket: CRC-32 mismatch, 516 bytes, ZCRCG`** followed by `TX ZRPOS`: an error and its
  recovery.
- **`timeout: nothing received for 10.0 s while waiting for …`**: what each side was waiting for when
  it stalled. **`timeout: deadline passed while waiting for …`**: data stopped making progress
  although other bytes kept arriving.
- **The summary**: duration, throughput, header and subpacket counts, raw line bytes, and error
  counts.

### Error snapshots

At the Frames level, every bad subpacket also gets a snapshot:

```
-- error snapshot: subpacket started at stream offset 49794, failed at 50859 (1065 raw bytes; …)
        raw bytes 49730..<50859:
             49730  09 44 c3 f9 …   |.D...|
       >     49794  0b b9 78 1a …   |..x..|      ← '>' marks where the subpacket began
        serial reads (offset, bytes, arrival, gap since previous read):
               49152    4096  12:17:33.150
               53248    4096  12:17:33.152  +2.0 ms  ← in failed subpacket
```

How to read it:

- **Length about normal** (a 1024-byte subpacket is about 1030–1100 raw bytes with escapes): bytes
  were *damaged*, as from noise.
- **Length clearly wrong**: bytes were *lost*. Too short means a gap inside the subpacket; too long
  means a lost frame end merged two subpackets. Losses near 512 bytes or a multiple suggest whole
  USB packets were dropped.
- **Serial reads**: each read from the port with its arrival time. A long gap just before the error
  suggests the Mac fell behind. Evenly spaced reads point to the device or the link.

## XMODEM and YMODEM traces

These protocols have no headers; the trace shows what they do have, at the same two levels:

- the handshake: `TX 'C'` (asking for CRC-16) or `TX NAK (checksum mode)` from a receiver, and
  `XMODEM receiver ready (CRC-16)` on the sending side;
- YMODEM's block 0, decoded like a ZMODEM file offer (`block 0: file "name" fields "…"`), and
  `block 0: end of batch`;
- every damaged block with the reason (`bad block: CRC-16 mismatch in block 12`, `cut short after
  991 of 1028 bytes`), the bytes purged before the NAK, and duplicates (`duplicate block 18;
  acknowledging it again`: the ACK was lost);
- every NAK received and each resend (`NAK for block 12`, `sending block 12 again (attempt 2)`),
  further NAKs taken as part of one (`after the NAK: 15 15 (taken as part of it)`), and the EOT
  exchange (a receiver NAKs the first EOT, in case it was noise);
- what was recognised as not being what it looked like: `0x04 with more bytes right behind it:
  not an EOT` (data from a block whose start byte was lost), `'C' again for block 1; waiting for
  its answer`, `A late ACK after block 40: the ACKs were a block behind`, `The remote's shell
  answered instead of an ACK for EOT`;
- a summary with blocks, bad blocks and NAKs in each direction.

Frames + raw bytes adds a line per block and the hex dump of all line traffic.

## Workarounds

Settings ▸ Transfers ▸ ZMODEM workarounds. The defaults suit lrzsz and most implementations. Each
setting is tested against lrzsz in both directions.

| Setting | Default | Use when |
|---|---|---|
| Block size when sending | 1024 | The receiver mishandles 1 KB subpackets (try 512 or 256), or the link is very clean and fast (try 8192) |
| Wait for ACK every | As receiver requests | The receiver advertises streaming but loses data when sent to continuously. Forces `ZCRCW` every N bytes |
| Force CRC-16 | off | The peer advertises CRC-32 but gets it wrong |
| Escape all control characters | off | Something on the link (a modem, a radio, a terminal server) swallows or changes control characters |
| Timeout | 10 s | The link or the peer is slow to respond (satellite, radio modems) |

**Restore Defaults** resets these settings but keeps the trace level.

## Testing

`swift test` exercises:

- the encoding and decoding of every header format and subpacket, including all 256 byte values
  and the `@`-CR escape;
- native ZMODEM against itself, over a link that flips and drops bytes in either direction;
- the sender against scripted receivers and a rate-limited line (`ZmodemSenderRobustnessTests`):
  a stray byte on the back channel, cancel while streaming or with output held, receivers that
  answer `ZEOF` with `ZNAK`, go away, advertise a buffer, lose a reply, or overrun and go quiet
  after every burst;
- the receiver against broken and hostile senders (`ZmodemReceiverRobustnessTests`): huge numbers
  in the file offer, streaming or echoing devices, stale `ZEOF`s, trickling noise, damaged offers,
  hostile file names and symlinks;
- native ZMODEM against lrzsz in both directions, over a pseudo-terminal pair, both cleanly and
  over a noisy line, and with each workaround setting;
- XMODEM and YMODEM against themselves (every block-boundary size, checksum and CRC, a noisy line
  both ways, cancel from either end, scripted peers for the handshake and EOT) and against lrzsz
  in both directions, cleanly and over a noisy line;
- cancelling, timeouts, an unanswered sender, and file naming;
- trace contents, including error snapshots for damaged and lost data.

See [Development](development.md#testing-against-real-hardware) for running the same checks
against a real device.
