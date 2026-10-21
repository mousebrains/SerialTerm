# ZMODEM & Diagnostics

SerialTerm has its own ZMODEM implementation (`Sources/SerialCore/Zmodem/`). This page covers what
it supports, how it behaves, how to read its protocol traces, and the settings that work around
unusual peers.

- [What's supported](#whats-supported)
- [Automatic start](#automatic-start)
- [Sending](#sending)
- [Receiving](#receiving)
- [Error recovery](#error-recovery)
- [Protocol traces](#protocol-traces)
- [Reading a trace](#reading-a-trace)
- [Workarounds](#workarounds)
- [lrzsz fallback](#lrzsz-fallback)
- [Testing](#testing)

## What's supported

| Feature | Status |
|---|---|
| Batch send and receive (any number of files) | ✓ |
| CRC-16 and CRC-32 (CRC-32 whenever the peer offers it) | ✓ |
| Hex, binary (`ZBIN`) and binary CRC-32 (`ZBIN32`) headers | ✓ |
| Streaming (`ZCRCG`), with `ZRPOS` rewind on errors | ✓ |
| Windowed sending (`ZCRCW` + `ZACK`) for receivers with a small buffer, or when forced | ✓ |
| `ZCRCQ` (receiver acknowledges mid-stream) | ✓ answered when receiving; not sent |
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

1. Send `rz\r` (this starts the receiver if the remote is at a shell prompt), then a `ZRQINIT`
   header.
2. Wait for `ZRINIT`, which gives the receiver's capabilities and buffer size. A `ZRQINIT` echoed
   by the remote shell before `rz` starts is recognized and ignored.
3. For each file: `ZFILE` with the file offer
   `name NUL size mtime(octal) mode(octal) 0 files-left bytes-left NUL`. The receiver answers
   `ZRPOS` (where to start) or `ZSKIP`.
4. `ZDATA` at that position, then data subpackets of the configured block size (default 1024):
   - **Streaming** when the receiver advertises buffer 0 with `CANFDX|CANOVIO`. All subpackets are
     `ZCRCG`, and the sender checks the back channel for `ZRPOS` between subpackets without
     stopping.
   - **Windowed** when the receiver has a buffer, lacks `CANOVIO`/`CANFDX`, or the window setting is
     on. The sender sends `ZCRCW` every *window* bytes and waits for `ZACK`.
5. `ZEOF` with the file length. The receiver answers `ZRINIT` when it has everything.
6. After the last file: `ZFIN`, the receiver answers `ZFIN`, and the sender sends `OO`.

Output is written in 16 KB batches, with at most 64 KB queued at the serial port, so a `ZRPOS`
takes effect within a few milliseconds even on fast links.

## Receiving

- SerialTerm advertises `CANFDX|CANOVIO|CANFC32` with buffer 0, meaning the sender may stream.
  With *Force CRC-16* it omits `CANFC32`; with *Escape all control characters* it adds `ESCCTL`.
- File names are made safe: path components are removed, control characters and `:` are removed,
  and leading dots are dropped. An empty name becomes `received`. Existing files are never
  overwritten; the new copy is saved as `name (1).ext`.
- The modification time is set from the file offer.
- If the received length differs from the announced size, the session log notes it.
- If the transfer fails, the partial file is deleted.

## Error recovery

The receiver keeps the offset of the last good byte. On a CRC error, an invalid escape, an
oversize subpacket, data at the wrong offset, or a timeout, it sends `ZRPOS` with that offset and
then ignores everything until a `ZDATA` header for that offset arrives. The sender, on `ZRPOS`,
drops any output not yet written and restarts from the requested offset.

lrzsz's receiver repeats `ZRPOS` while it skips the data that was in flight, so the sender
ignores a repeat of the offset it restarted from within the last 2 s. A quick repeat can also be
genuine, when the data right after the restart was damaged too. Then the receiver ignores the
sender's `ZEOF`, because it doesn't have the data yet, and the sender, seeing no reply, restarts
from that offset. The receiver ignores a `ZEOF` for a different offset, but it doesn't restart
its timeout for it, so it asks again on schedule even while the sender keeps repeating `ZEOF`.

Limits:
- 50 errors per file when receiving, 30 rewinds per file when sending;
- 10 retries for the handshake, the file offer and `ZEOF`.

Five consecutive CAN bytes (`0x18`) from the remote abort the transfer. A local cancel, or a fatal
error, sends ten CANs and ten backspaces. The backspaces erase the CANs if the remote has already
returned to a shell.

## Protocol traces

Every built-in ZMODEM transfer writes a trace to the log folder, named
`SerialTerm-YYYY-MM-DD-HHMMSS-zmodem.log`. The trace is written whether or not session logging is
on. Open the latest one with **Transfer ▸ Open Last ZMODEM Trace** (it opens in Console).

Choose the level in Settings ▸ Transfers ▸ ZMODEM diagnostics:

| Level | Contents |
|---|---|
| Off | No trace |
| **Frames** (default) | Every header in both directions, decoded; file offers as sent; summaries of data runs; bad headers and subpackets with the reason; skipped bytes with a hex sample; timeouts (and what was awaited); every retry and rewind; an error snapshot for each bad subpacket; a closing summary |
| Frames + raw bytes | All of the above, plus every data subpacket and a hex/ASCII dump of all line traffic. Large: roughly 4× the file size |

Each line starts with the local time and the seconds since the transfer started, then the
direction: `RX` (from the remote), `TX` (to the remote), or `--` (a note).

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
- **`timeout: nothing received for 10.0s while waiting for …`**: what each side was waiting for when
  it stalled.
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

## lrzsz fallback

Settings ▸ Transfers ▸ *Use lrzsz instead of the built-in ZMODEM* runs `lrz`/`lsz` (from
`brew install lrzsz`) with their standard input and output connected to the serial port, the way
minicom does. No trace is written in this mode; the status bar shows lrzsz's own progress
messages. This is useful for checking whether a problem is in the device or in SerialTerm.

## Testing

`swift test` exercises:

- the encoding and decoding of every header format and subpacket, including all 256 byte values
  and the `@`-CR escape;
- native ZMODEM against itself, over a link that flips and drops bytes in either direction;
- native ZMODEM against lrzsz in both directions, over a pseudo-terminal pair, both cleanly and
  over a noisy line, and with each workaround setting;
- cancelling, timeouts, an unanswered sender, and file naming;
- trace contents, including error snapshots for damaged and lost data.

See [Development](development.md#testing-against-real-hardware) for running the same checks
against a real device.
