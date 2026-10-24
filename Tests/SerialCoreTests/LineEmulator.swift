// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Darwin
import Foundation
@testable import SerialCore

/// A serial line between two pseudo-terminals, standing in for the cable, adapter, radio or modem
/// between SerialTerm and a device. Each end is a pty slave that a `SerialPort` opens, or that a
/// program such as lrzsz uses as its terminal (`run`). What one end writes reaches the other at the
/// line's rate and latency, through whatever damage the test asks for.
///
/// Unlike the in-memory links, the line takes time and holds the writer off when it's full, so a
/// sender's timeouts start once its data has really gone, as on hardware. A pty buffers about 1 KB
/// each way itself; `Line.buffer` is the rest (an adapter's or a modem's buffer).
///
/// The line's rate is its own: a pty's termios rate means nothing to it, as a modem's line rate
/// needn't match its serial port's (and macOS ptys refuse rates termios can't set, such as 921600).
///
/// `log` records every byte delivered, damaged or lost, with its time, as the line saw it: a failure
/// can be read from the wire rather than from either end's own account.
final class LineEmulator: @unchecked Sendable {
    /// One direction of the line.
    struct Line {
        /// Bits a second on the wire; nil passes bytes on as soon as they're read, as the in-memory
        /// links do.
        var baud: Double?
        /// Bits per byte on the wire: 10 for 8N1.
        var bitsPerByte = 10.0
        /// Delay from a byte (or packet) leaving to its arriving: a radio's, a satellite's.
        var latency: TimeInterval = 0
        /// Extra delay drawn for each packet (for each read's worth of bytes, without `packets`).
        /// Order is kept: a late packet holds back those behind it.
        var jitter: Jitter = .none
        /// Packets, as a radio modem, a satellite modem or a USB adapter sends them. nil passes bytes
        /// on as they arrive.
        var packets: Packets?
        /// Bytes the line takes from the writer before it's full: a UART's FIFO, an adapter's or a
        /// modem's buffer. Adds to the pty's own ~1 KB.
        var buffer = 4096
        /// What happens to what doesn't fit.
        var overrun: Overrun = .holdOff
        /// Random damage: the chance per bit of a flipped bit, per byte of a lost byte, and per byte
        /// of a noise byte arriving after it. Drawn from the emulator's seed, so a failure replays.
        var bitErrorRate = 0.0
        var dropRate = 0.0
        var noiseRate = 0.0
        /// When everything sent is lost, in seconds after the emulator started: a dropped call, a
        /// radio fade.
        var outages: [Range<TimeInterval>] = []
        /// A one-off hold-up at a chosen point in the stream.
        var stall: Stall?
        /// Scripted damage at chosen bytes: the filters the in-memory tests use.
        var filter: (any LineFilter)?

        /// Seconds a byte takes on the wire.
        var byteTime: TimeInterval { baud.map { bitsPerByte / $0 } ?? 0 }
    }

    enum Jitter {
        case none
        /// Up to this much, evenly.
        case uniform(TimeInterval)
        /// Exponential with this mean: mostly little, now and then a lot.
        case exponential(mean: TimeInterval)
        /// An error-correcting modem's: a packet is resent, `delay` later, with chance `probability`
        /// each time it goes. Errors become delays rather than damage.
        case retries(probability: Double, delay: TimeInterval)
    }

    /// A packet goes when it holds `size` bytes, or when the line has been idle for `idle` after
    /// its last byte (as an FTDI adapter's latency timer sends a partial USB packet).
    struct Packets {
        var size: Int
        var idle: TimeInterval
    }

    /// The packet (or read's worth of bytes) that completes the `occurrence`th `pattern` arrives
    /// `duration` late, and what's behind it waits: an error-correcting modem resending a packet
    /// over and over, a satellite handover. It stands in for a reply that's late for any reason.
    struct Stall {
        var pattern: [UInt8]
        var occurrence = 1
        var duration: TimeInterval
    }

    enum Overrun {
        /// The writer waits: flow control, or a driver that holds it off.
        case holdOff
        /// It's lost: a modem with no flow control fed faster than it sends, or a device that can't
        /// keep up with the line (a line at the device's own rate, with its buffer).
        case drop
    }

    /// The ends: open `a.slavePath` and `b.slavePath`.
    let a: PtyPair
    let b: PtyPair
    let log = WireLog()
    private let directions: [Direction]

    /// `aToB` carries what end A writes to end B, `bToA` the reverse. `speed` is the ptys' termios
    /// rate, which only the programs at the ends see.
    init(aToB: Line, bToA: Line, seed: UInt64 = 1, speed: speed_t = 115_200) throws {
        a = try PtyPair(rawAt: speed)
        b = try PtyPair(rawAt: speed)
        let epoch = Uptime.now
        directions = [
            Direction(name: "A→B", line: aToB, from: a.master, to: b.master, epoch: epoch, seed: seed, log: log),
            Direction(name: "B→A", line: bToA, from: b.master, to: a.master, epoch: epoch, seed: seed &+ 0x5EED, log: log),
        ]
        for d in directions { d.start() }
    }

    convenience init(both line: Line, seed: UInt64 = 1, speed: speed_t = 115_200) throws {
        try self.init(aToB: line, bToA: line, seed: seed, speed: speed)
    }

    deinit { stop() }

    /// Stops moving bytes; returns once both directions have.
    func stop() {
        for d in directions { d.stop() }
    }

    /// Runs a program with end B as its terminal, as a device's shell runs lrzsz.
    func run(_ tool: URL, _ args: [String], in dir: URL) throws -> Process {
        // O_NOCTTY: the test runner mustn't take the pty as its controlling terminal.
        let fd = open(b.slavePath, O_RDWR | O_NOCTTY)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        let tty = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardInput = tty
        process.standardOutput = tty
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// One direction: reads what one end writes, takes it across the line, and writes it to the
    /// other end, on a thread of its own.
    private final class Direction: @unchecked Sendable {
        let name: String
        let line: Line
        let from: Int32, to: Int32
        /// When the emulator started: the zero of the log's and the outages' times.
        let epoch: TimeInterval
        let log: WireLog
        private let byteTime: TimeInterval
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stopped = false
        private var thread: Thread?

        /// When the transmitter will have sent everything it has.
        private var txFree: TimeInterval = 0
        /// Sent and not yet arrived, oldest first.
        private var wire: [Segment] = []
        /// A packet being filled, and when its last byte arrived.
        private var packet: [UInt8] = []
        private var packetLast: TimeInterval = 0
        /// Arrived and waiting out their latency and jitter, in order.
        private var due: [(time: TimeInterval, data: [UInt8])] = []
        private var lastDue: TimeInterval = 0
        /// Due and not yet taken by the far end's pty.
        private var out: [UInt8] = []
        /// When the last byte went through `line.filter`, if it may be holding bytes back: they're
        /// released once the line has paused (`flushDelay`).
        private var filtered: TimeInterval?
        private let flushDelay: TimeInterval
        /// Bytes taken from the writer, and bytes delivered: offsets for the log.
        private var taken = 0
        private var delivered = 0
        private var damage: Damage
        private var jitterRNG: SplitMix64
        /// The last bytes packed, and how often `line.stall`'s pattern has been seen in them.
        private var recent: [UInt8] = []
        private var stallSeen = 0
        /// The next packet emitted completes the stall's pattern.
        private var stallNext = false

        struct Segment {
            /// When the first byte not yet arrived does.
            var next: TimeInterval
            var bytes: [UInt8]
            var index = 0
        }

        init(name: String, line: Line, from: Int32, to: Int32, epoch: TimeInterval, seed: UInt64, log: WireLog) {
            self.name = name
            self.line = line
            self.from = from
            self.to = to
            self.epoch = epoch
            self.log = log
            byteTime = line.byteTime
            flushDelay = max(0.005, 4 * line.byteTime)
            damage = Damage(line: line, seed: seed)
            jitterRNG = SplitMix64(seed: seed ^ 0x4A17_7E55)
            _ = fcntl(from, F_SETFL, fcntl(from, F_GETFL) | O_NONBLOCK)
            _ = fcntl(to, F_SETFL, fcntl(to, F_GETFL) | O_NONBLOCK)
        }

        func start() {
            let t = Thread { [self] in
                run()
                done.signal()
            }
            // It plays hardware, which doesn't slow down when the machine is busy.
            t.qualityOfService = .userInteractive
            t.name = "LineEmulator \(name)"
            thread = t
            t.start()
        }

        func stop() {
            let first: Bool = lock.withLock {
                defer { stopped = true }
                return !stopped && thread != nil
            }
            if first { done.wait() }
        }

        private var isStopped: Bool { lock.withLock { stopped } }

        private func run() {
            var buf = [UInt8](repeating: 0, count: 65_536)
            while !isStopped {
                let now = Uptime.now
                let room = self.room(at: now)
                if room > 0 || line.overrun == .drop {
                    let n = read(from, &buf, line.overrun == .drop ? buf.count : min(room, buf.count))
                    if n > 0 { send(Array(buf[0..<n]), room: room, at: now) }
                }
                arrive(by: now)
                deliver(by: now)
                wait(now: now)
            }
        }

        /// Bytes the line can take now, short of being full.
        private func room(at now: TimeInterval) -> Int {
            guard byteTime > 0 else { return line.buffer }
            let backlog = Int((max(0, txFree - now) / byteTime).rounded(.up))
            return max(0, line.buffer - backlog)
        }

        /// Puts bytes on the wire, behind what's there; what doesn't fit is lost (`.drop` only).
        private func send(_ bytes: [UInt8], room: Int, at now: TimeInterval) {
            var bytes = bytes
            if bytes.count > room {
                log.add(now - epoch, name, .overrun, taken + room, Array(bytes[room...]))
                taken += bytes.count - room
                bytes.removeLast(bytes.count - room)
            }
            guard !bytes.isEmpty else { return }
            let begin = max(txFree, now)
            txFree = begin + Double(bytes.count) * byteTime
            wire.append(Segment(next: begin + byteTime, bytes: bytes))
            taken += bytes.count
        }

        /// Takes off the wire the bytes that have arrived by `now`: damages them and packs them.
        private func arrive(by now: TimeInterval) {
            while !wire.isEmpty, wire[0].next <= now {
                var s = wire[0]
                let left = s.bytes.count - s.index
                let k = byteTime > 0 ? min(left, Int((now - s.next) / byteTime) + 1) : left
                let first = s.next
                var chunk = Array(s.bytes[s.index..<(s.index + k)])
                s.index += k
                s.next += Double(k) * byteTime
                if s.index == s.bytes.count { wire.removeFirst() } else { wire[0] = s }

                chunk = lose(chunk, firstAt: first)
                if let filter = line.filter, !chunk.isEmpty {
                    chunk = [UInt8](filter.apply(Data(chunk)))
                    filtered = first + Double(k - 1) * byteTime
                }
                pack(damaged(chunk, now: now), firstAt: first)
            }
            if let f = filtered, now >= f + flushDelay, let filter = line.filter {
                filtered = nil
                pack(damaged([UInt8](filter.flush()), now: now), firstAt: f + flushDelay)
            }
            if line.packets != nil, !packet.isEmpty, let idle = line.packets?.idle, now >= packetLast + idle {
                emit(packet, at: packetLast + idle)
                packet = []
            }
        }

        private func damaged(_ chunk: [UInt8], now: TimeInterval) -> [UInt8] {
            damage.apply(chunk) { [self] kind, offset, bytes in log.add(now - epoch, name, kind, offset, bytes) }
        }

        /// Drops the bytes that arrive during an outage.
        private func lose(_ chunk: [UInt8], firstAt first: TimeInterval) -> [UInt8] {
            guard !line.outages.isEmpty else { return chunk }
            var kept: [UInt8] = []
            var lost: [UInt8] = []
            for (i, b) in chunk.enumerated() {
                let t = first + Double(i) * byteTime - epoch
                if line.outages.contains(where: { $0.contains(t) }) { lost.append(b) } else { kept.append(b) }
            }
            if !lost.isEmpty { log.add(first - epoch, name, .lost, -1, lost) }
            return kept
        }

        private func pack(_ chunk: [UInt8], firstAt first: TimeInterval) {
            guard !chunk.isEmpty else { return }
            guard let p = line.packets else {
                for b in chunk where stalls(after: b) { stallNext = true }
                emit(chunk, at: first + Double(chunk.count - 1) * byteTime)
                return
            }
            for (i, b) in chunk.enumerated() {
                let t = first + Double(i) * byteTime
                if !packet.isEmpty && t > packetLast + p.idle {
                    emit(packet, at: packetLast + p.idle)
                    packet = []
                }
                packet.append(b)
                if stalls(after: b) { stallNext = true }
                packetLast = t
                if packet.count >= p.size {
                    emit(packet, at: t)
                    packet = []
                }
            }
        }

        /// Whether `b` completes the stall's pattern for the chosen time.
        private func stalls(after b: UInt8) -> Bool {
            guard let s = line.stall, stallSeen < s.occurrence else { return false }
            recent.append(b)
            if recent.count > s.pattern.count { recent.removeFirst() }
            guard recent == s.pattern else { return false }
            stallSeen += 1
            return stallSeen == s.occurrence
        }

        /// Sends a packet across: it arrives after the latency and its jitter, and not before the one ahead.
        private func emit(_ bytes: [UInt8], at time: TimeInterval) {
            var arrival = max(lastDue, time + line.latency + jitter())
            if stallNext, let s = line.stall {
                stallNext = false
                arrival += s.duration
            }
            lastDue = arrival
            due.append((arrival, bytes))
        }

        private func jitter() -> TimeInterval {
            switch line.jitter {
            case .none:
                return 0
            case let .uniform(most):
                return most * jitterRNG.unit()
            case let .exponential(mean):
                return -mean * log1p(-jitterRNG.unit())
            case let .retries(probability, delay):
                var extra = 0.0
                while jitterRNG.unit() < probability { extra += delay }
                return extra
            }
        }

        private func deliver(by now: TimeInterval) {
            var n = 0
            while n < due.count, due[n].time <= now {
                out += due[n].data
                n += 1
            }
            due.removeFirst(n)
            guard !out.isEmpty else { return }
            let written = out.withUnsafeBytes { write(to, $0.baseAddress, $0.count) }
            if written > 0 {
                log.add(now - epoch, name, .delivered, delivered, Array(out[0..<written]))
                delivered += written
                out.removeFirst(written)
            }
        }

        /// Sleeps until there's something to do: input while there's room, the far end taking
        /// output, or the next byte or packet due.
        private func wait(now: TimeInterval) {
            var next: TimeInterval?
            func soonest(_ t: TimeInterval) { next = min(next ?? t, t) }
            if let s = wire.first { soonest(s.next) }
            if let d = due.first { soonest(d.time) }
            if let p = line.packets, !packet.isEmpty { soonest(packetLast + p.idle) }
            if let f = filtered { soonest(f + flushDelay) }
            let reading = room(at: now) > 0 || line.overrun == .drop
            if !reading { soonest(txFree - Double(line.buffer - 1) * byteTime) }

            var fds: [pollfd] = []
            if reading { fds.append(pollfd(fd: from, events: Int16(POLLIN), revents: 0)) }
            if !out.isEmpty { fds.append(pollfd(fd: to, events: Int16(POLLOUT), revents: 0)) }
            // At least 1 ms, so a fast line moves bytes in batches rather than spinning; at most
            // 100 ms, to notice a stop.
            var timeout: Int32 = 100
            if let next { timeout = next <= Uptime.now ? 0 : Int32(min(100, max(1, ((next - Uptime.now) * 1000).rounded(.up)))) }
            if timeout == 0 { return }
            _ = poll(&fds, nfds_t(fds.count), timeout)
        }
    }

    /// Random bit flips, lost bytes and noise, at offsets drawn ahead from the seed: the same seed
    /// damages the same bytes of the same stream.
    private struct Damage {
        let line: Line
        var flipRNG, dropRNG, noiseRNG: SplitMix64
        /// Offsets, in bits for flips and bytes for the rest, of the next of each.
        var nextFlip: Int, nextDrop: Int, nextNoise: Int
        /// Bytes seen so far.
        var offset = 0

        init(line: Line, seed: UInt64) {
            self.line = line
            flipRNG = SplitMix64(seed: seed ^ 0xF11B)
            dropRNG = SplitMix64(seed: seed ^ 0xD20B)
            noiseRNG = SplitMix64(seed: seed ^ 0x4015E)
            nextFlip = flipRNG.gap(line.bitErrorRate)
            nextDrop = dropRNG.gap(line.dropRate)
            nextNoise = noiseRNG.gap(line.noiseRate)
        }

        mutating func apply(_ chunk: [UInt8], log: (WireLog.Kind, Int, [UInt8]) -> Void) -> [UInt8] {
            let end = offset + chunk.count
            guard nextFlip / 8 < end || nextDrop < end || nextNoise < end else {
                offset = end
                return chunk
            }
            var out: [UInt8] = []
            out.reserveCapacity(chunk.count)
            for (i, var b) in chunk.enumerated() {
                let at = offset + i
                while nextFlip / 8 == at {
                    let was = b
                    b ^= 1 << UInt8(nextFlip % 8)
                    log(.flipped, at, [was, b])
                    nextFlip += 1 + flipRNG.gap(line.bitErrorRate)
                }
                if nextDrop == at {
                    log(.dropped, at, [b])
                    nextDrop += 1 + dropRNG.gap(line.dropRate)
                } else {
                    out.append(b)
                }
                if nextNoise == at {
                    let n = UInt8(truncatingIfNeeded: noiseRNG.next())
                    out.append(n)
                    log(.noise, at, [n])
                    nextNoise += 1 + noiseRNG.gap(line.noiseRate)
                }
            }
            offset = end
            return out
        }
    }
}

/// What a `LineEmulator` saw, with times in seconds from its start.
final class WireLog: @unchecked Sendable {
    enum Kind: String {
        /// Written to the far end.
        case delivered
        /// Damaged on the way: a bit flipped (the byte before and after), a byte lost, noise added.
        case flipped, dropped, noise
        /// Lost in an outage, or for want of room (`Overrun.drop`).
        case lost, overrun
    }

    struct Entry {
        let time: TimeInterval
        let direction: String
        let kind: Kind
        /// Offset in the stream taken from the writer (for `delivered`, in the stream delivered);
        /// -1 if it doesn't apply.
        let offset: Int
        let bytes: [UInt8]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func add(_ time: TimeInterval, _ direction: String, _ kind: Kind, _ offset: Int, _ bytes: [UInt8]) {
        lock.withLock { entries.append(Entry(time: time, direction: direction, kind: kind, offset: offset, bytes: bytes)) }
    }

    var all: [Entry] { lock.withLock { entries } }

    /// Events of a kind (one way, or both).
    func events(_ kind: Kind, _ direction: String? = nil) -> [Entry] {
        all.filter { $0.kind == kind && (direction == nil || $0.direction == direction) }
    }

    /// Bytes of a kind (one way, or both).
    func bytes(_ kind: Kind, _ direction: String? = nil) -> Int {
        events(kind, direction).reduce(0) { $0 + $1.bytes.count }
    }

    /// One line per event, bytes in hex.
    var text: String {
        all.map { e in
            let hex = e.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            return String(format: "%10.6f %@ %@ @%d %d: ", e.time, e.direction, e.kind.rawValue, e.offset, e.bytes.count) + hex
        }.joined(separator: "\n")
    }
}

/// A small, seedable generator (SplitMix64), so damage and jitter replay from a seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Trials before the next event of chance `p` each (geometric); effectively never for p = 0.
    mutating func gap(_ p: Double) -> Int {
        guard p > 0 else { return Int.max / 2 }
        guard p < 1 else { return 0 }
        return Int(min(Double(Int.max / 4), (log1p(-unit()) / log1p(-p)).rounded(.down)))
    }
}
