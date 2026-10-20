import Foundation

enum ZmodemError: Error, CustomStringConvertible, Equatable {
    case timeout
    case cancelled
    case remoteCancelled
    case tooManyErrors(String)
    case protocolError(String)
    case fileError(String)

    var description: String {
        switch self {
        case .timeout: return "Timed out waiting for the remote"
        case .cancelled: return "Cancelled"
        case .remoteCancelled: return "Cancelled by the remote"
        case let .tooManyErrors(s): return "Too many errors (\(s))"
        case let .protocolError(s): return s
        case let .fileError(s): return s
        }
    }
}

/// Thread-safe inbox: the serial side appends, the protocol thread blocks reading.
final class ByteChannel: @unchecked Sendable {
    private let cond = NSCondition()
    private var buffer: [UInt8] = []
    private var cancelled = false

    /// One `append` (one read from the serial port), for error diagnostics.
    struct Chunk {
        var offset: Int  // stream offset of its first byte
        var count: Int
        var time: Date
    }

    private var appended = 0
    private var chunks: [Chunk] = []
    private static let chunkHistory = 512

    func append(_ data: Data) {
        let now = Date()
        cond.lock()
        buffer.append(contentsOf: data)
        chunks.append(Chunk(offset: appended, count: data.count, time: now))
        if chunks.count > Self.chunkHistory { chunks.removeFirst(chunks.count - Self.chunkHistory) }
        appended += data.count
        cond.signal()
        cond.unlock()
    }

    /// Recent chunks overlapping stream offsets `range`.
    func chunks(overlapping range: Range<Int>) -> [Chunk] {
        cond.lock()
        defer { cond.unlock() }
        return chunks.filter { $0.offset < range.upperBound && $0.offset + $0.count > range.lowerBound }
    }

    func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    var isCancelled: Bool {
        cond.lock()
        defer { cond.unlock() }
        return cancelled
    }

    var hasInput: Bool {
        cond.lock()
        defer { cond.unlock() }
        return !buffer.isEmpty
    }

    /// Everything buffered, waiting up to `timeout` for at least one byte.
    func take(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while buffer.isEmpty && !cancelled {
            if !cond.wait(until: deadline) { break }
        }
        if cancelled { throw ZmodemError.cancelled }
        if buffer.isEmpty { throw ZmodemError.timeout }
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        return out
    }
}

/// Decodes ZMODEM frames from a `ByteChannel`. Used from one thread only.
final class ZReader {
    private let channel: ByteChannel
    private var local: [UInt8] = []
    private var index = 0
    /// Stream offset of local[0].
    private var localBase = 0
    /// The most recent bytes consumed from the channel, ending at `historyEnd`, for error snapshots.
    private var history: [UInt8] = []
    private var historyEnd = 0
    private static let historyLimit = 8192

    /// Stream offset of the next byte to be read.
    var position: Int { localBase + index }
    var trace: ZmodemTrace?
    /// What the protocol is waiting for, for timeout messages in the trace.
    var waitingFor = "data"

    init(_ channel: ByteChannel) {
        self.channel = channel
    }

    var hasPendingInput: Bool { index < local.count || channel.hasInput }

    func byte(timeout: TimeInterval, quiet: Bool = false) throws -> UInt8 {
        if index >= local.count {
            do {
                local = try channel.take(timeout: timeout)
            } catch ZmodemError.timeout {
                if !quiet, let trace {
                    trace.timeouts += 1
                    trace.note("timeout: nothing received for \(timeout)s while waiting for \(waitingFor)")
                }
                throw ZmodemError.timeout
            }
            localBase = historyEnd
            index = 0
            history.append(contentsOf: local)
            historyEnd += local.count
            if history.count > Self.historyLimit * 2 { history.removeFirst(history.count - Self.historyLimit) }
        }
        defer { index += 1 }
        return local[index]
    }

    /// Raw bytes for stream offsets `range`, as far as they're still in the history.
    func historyBytes(_ range: Range<Int>) -> (start: Int, bytes: [UInt8]) {
        let historyStart = historyEnd - history.count
        let lo = max(range.lowerBound, historyStart), hi = min(range.upperBound, historyEnd)
        guard lo < hi else { return (lo, []) }
        return (lo, Array(history[(lo - historyStart)..<(hi - historyStart)]))
    }

    func unread() {
        index -= 1
    }

    /// Next byte, ignoring XON/XOFF, which never appear unescaped inside ZMODEM data.
    private func raw(_ timeout: TimeInterval) throws -> UInt8 {
        while true {
            let b = try byte(timeout: timeout)
            switch b {
            case 0x11, 0x13, 0x91, 0x93: continue
            default: return b
            }
        }
    }

    enum Unit: Equatable {
        case byte(UInt8)
        case frameEnd(UInt8)
    }

    /// One ZDLE-decoded unit. Five CANs in a row mean the remote aborted.
    func zdlRead(_ timeout: TimeInterval) throws -> Unit {
        let c = try raw(timeout)
        guard c == Z.dle else { return .byte(c) }
        var cans = 1
        while true {
            let c2 = try raw(timeout)
            if c2 == Z.can {
                cans += 1
                if cans >= 5 { throw ZmodemError.remoteCancelled }
                continue
            }
            switch c2 {
            case Z.crcE, Z.crcG, Z.crcQ, Z.crcW: return .frameEnd(c2)
            case Z.rub0: return .byte(0x7F)
            case Z.rub1: return .byte(0xFF)
            default:
                if c2 & 0x60 == 0x40 { return .byte(c2 ^ 0x40) }
                throw ZmodemError.protocolError("bad ZDLE escape 0x\(String(c2, radix: 16))")
            }
        }
    }

    /// Scans for the next header, skipping up to `garbageLimit` other bytes.
    /// Returns nil for a corrupt header or too much garbage, so the caller can resynchronise.
    func readHeader(timeout: TimeInterval, garbageLimit: Int = 4096) throws -> ZHeader? {
        var skipped: [UInt8] = []
        var skippedCount = 0
        func reportSkipped() {
            guard skippedCount > 0, let trace else { return }
            trace.garbageBytes += skippedCount
            trace.note("skipped \(skippedCount) non-header bytes: \(ZmodemTrace.hex(skipped))")
            skipped.removeAll()
            skippedCount = 0
        }
        func skip(_ b: UInt8) {
            skippedCount += 1
            if skipped.count < 48 { skipped.append(b) }
        }
        defer { reportSkipped() }

        var garbage = 0
        var cans = 0
        while true {
            var c = try raw(timeout)
            if c == Z.can {
                cans += 1
                if cans >= 5 { throw ZmodemError.remoteCancelled }
            } else {
                cans = 0
            }
            guard c & 0x7F == Z.pad else {
                skip(c)
                garbage += 1
                if garbage > garbageLimit {
                    trace?.note("gave up looking for a header after \(garbage) bytes")
                    return nil
                }
                continue
            }
            // Where this candidate header began, so its prefix isn't counted as garbage.
            let markCount = skippedCount, markSample = skipped.count
            repeat { skip(c); c = try raw(timeout) } while c & 0x7F == Z.pad
            guard c == Z.dle else {
                unread()
                continue
            }
            skip(c)
            let format = try raw(timeout) & 0x7F
            let h: ZHeader?
            switch format {
            case Z.bin16: h = try readBinaryHeader(crc32: false, timeout)
            case Z.bin32: h = try readBinaryHeader(crc32: true, timeout)
            case Z.hex: h = try readHexHeader(timeout)
            default:
                unread()
                garbage += 1
                continue
            }
            skippedCount = markCount
            skipped.removeLast(skipped.count - markSample)
            reportSkipped()
            if let h { trace?.header(.rx, h) }
            return h
        }
    }

    private func badHeader(_ format: String, _ why: String, _ bytes: [UInt8]) -> ZHeader? {
        if let trace {
            trace.badHeaders += 1
            trace.note("bad \(format) header (\(why)): \(ZmodemTrace.hex(bytes))")
        }
        return nil
    }

    private func readBinaryHeader(crc32: Bool, _ timeout: TimeInterval) throws -> ZHeader? {
        let name = crc32 ? "bin32" : "bin16"
        var bytes: [UInt8] = []
        for _ in 0..<(crc32 ? 9 : 7) {
            guard case let .byte(b) = try zdlReadOrNil(timeout) else { return badHeader(name, "bad escape", bytes) }
            bytes.append(b)
        }
        let raw = Array(bytes[0..<5])
        if crc32 {
            let got = UInt32(bytes[5]) | UInt32(bytes[6]) << 8 | UInt32(bytes[7]) << 16 | UInt32(bytes[8]) << 24
            guard got == CRC.crc32(raw) else { return badHeader(name, "CRC mismatch", bytes) }
        } else {
            guard UInt16(bytes[5]) << 8 | UInt16(bytes[6]) == CRC.crc16(raw) else { return badHeader(name, "CRC mismatch", bytes) }
        }
        return ZHeader(type: raw[0], p: Array(raw[1...]), format: crc32 ? Z.bin32 : Z.bin16)
    }

    private func readHexHeader(_ timeout: TimeInterval) throws -> ZHeader? {
        var bytes: [UInt8] = []
        var chars: [UInt8] = []
        for _ in 0..<7 {
            let c1 = try raw(timeout), c2 = try raw(timeout)
            chars += [c1, c2]
            guard let hi = hexValue(c1), let lo = hexValue(c2) else { return badHeader("hex", "non-hex character", chars) }
            bytes.append(hi << 4 | lo)
        }
        let raw5 = Array(bytes[0..<5])
        guard UInt16(bytes[5]) << 8 | UInt16(bytes[6]) == CRC.crc16(raw5) else { return badHeader("hex", "CRC mismatch", chars) }
        // Consume the trailing CR LF if they're already here; never wait long for them.
        for _ in 0..<2 {
            guard let b = try? byte(timeout: 0.05, quiet: true) else { break }
            if b & 0x7F != 0x0D && b & 0x7F != 0x0A {
                unread()
                break
            }
        }
        return ZHeader(type: raw5[0], p: Array(raw5[1...]), format: Z.hex)
    }

    private func zdlReadOrNil(_ timeout: TimeInterval) throws -> Unit? {
        do {
            return try zdlRead(timeout)
        } catch ZmodemError.protocolError {
            return nil
        }
    }

    private func hexValue(_ c: UInt8) -> UInt8? {
        switch c & 0x7F {
        case 0x30...0x39: return (c & 0x7F) - 0x30
        case 0x61...0x66: return (c & 0x7F) - 0x61 + 10
        case 0x41...0x46: return (c & 0x7F) - 0x41 + 10
        default: return nil
        }
    }

    enum Subpacket {
        case data([UInt8], end: UInt8)
        /// CRC mismatch, bad escape, or overlong packet.
        case bad(String)
    }

    func readSubpacket(crc32: Bool, timeout: TimeInterval, maxLength: Int = 8192) throws -> Subpacket {
        let start = position
        let result = try readSubpacketUntraced(crc32: crc32, timeout: timeout, maxLength: maxLength)
        guard let trace else { return result }
        switch result {
        case let .data(bytes, end):
            trace.subpacketsIn += 1
            if trace.verbose {
                trace.line(.rx, "  subpacket \(bytes.count) bytes, \(Self.endName(end)), CRC-\(crc32 ? 32 : 16) ok")
            }
        case let .bad(why):
            trace.badSubpackets += 1
            trace.note("bad subpacket: \(why)")
            traceErrorSnapshot(packetStart: start, failedAt: position)
        }
        return result
    }

    /// Records the raw bytes of a failed subpacket (plus some context before it) and the
    /// serial reads they arrived in, so lost or damaged data can be located exactly.
    private func traceErrorSnapshot(packetStart: Int, failedAt end: Int) {
        guard let trace else { return }
        let from = max(packetStart - 64, end - 3072)
        let (shownStart, bytes) = historyBytes(from..<end)
        var text = "error snapshot: subpacket started at stream offset \(packetStart), failed at \(end) "
            + "(\(end - packetStart) raw bytes; an intact 1024-byte subpacket is ~1030–1100 with escapes)"
        text += "\n        raw bytes \(shownStart)..<\(shownStart + bytes.count):"
        for i in stride(from: 0, to: bytes.count, by: 32) {
            let marker = shownStart + i <= packetStart && packetStart < shownStart + i + 32 ? ">" : " "
            text += "\n       \(marker)\(String(format: "%10d", shownStart + i))  "
                + ZmodemTrace.hexLine(bytes[i..<min(i + 32, bytes.count)])
        }
        let reads = channel.chunks(overlapping: max(0, from - 4096)..<end)
        if !reads.isEmpty {
            text += "\n        serial reads (offset, bytes, arrival, gap since previous read):"
            var previous: Date?
            for c in reads {
                let gap = previous.map { String(format: "+%.1f ms", c.time.timeIntervalSince($0) * 1000) } ?? ""
                let inPacket = c.offset + c.count > packetStart && c.offset < end ? "  ← in failed subpacket" : ""
                text += "\n          \(String(format: "%10d", c.offset))  \(String(format: "%6d", c.count))  "
                    + "\(ZmodemTrace.timeString(c.time))  \(gap)\(inPacket)"
                previous = c.time
            }
        }
        trace.note(text)
    }

    static func endName(_ end: UInt8) -> String {
        switch end {
        case Z.crcE: return "ZCRCE"
        case Z.crcG: return "ZCRCG"
        case Z.crcQ: return "ZCRCQ"
        case Z.crcW: return "ZCRCW"
        default: return String(format: "end %02x", end)
        }
    }

    private func readSubpacketUntraced(crc32: Bool, timeout: TimeInterval, maxLength: Int) throws -> Subpacket {
        var data: [UInt8] = []
        data.reserveCapacity(1024)
        while true {
            guard let unit = try zdlReadOrNil(timeout) else { return .bad("bad ZDLE escape after \(data.count) bytes") }
            switch unit {
            case let .byte(b):
                guard data.count < maxLength else { return .bad("subpacket longer than \(maxLength) bytes") }
                data.append(b)
            case let .frameEnd(end):
                var crcBytes: [UInt8] = []
                for _ in 0..<(crc32 ? 4 : 2) {
                    guard case let .byte(b) = try zdlReadOrNil(timeout) else { return .bad("bad CRC bytes") }
                    crcBytes.append(b)
                }
                if crc32 {
                    let got = UInt32(crcBytes[0]) | UInt32(crcBytes[1]) << 8 | UInt32(crcBytes[2]) << 16 | UInt32(crcBytes[3]) << 24
                    let want = ~CRC.crc32Update([end], CRC.crc32Update(data, 0xFFFF_FFFF))
                    guard got == want else { return .bad("CRC-32 mismatch, \(data.count) bytes, \(Self.endName(end))") }
                } else {
                    let got = UInt16(crcBytes[0]) << 8 | UInt16(crcBytes[1])
                    guard got == CRC.crc16([end], CRC.crc16(data)) else { return .bad("CRC-16 mismatch, \(data.count) bytes, \(Self.endName(end))") }
                }
                return .data(data, end: end)
            }
        }
    }
}
