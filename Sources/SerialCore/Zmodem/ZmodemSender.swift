// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Plumbing shared by the sender and receiver: output, tracing, progress, and logging.
final class ZLink {
    let reader: ZReader
    var encoder = ZEncoder()
    let trace: ZmodemTrace?
    private let output: (Data) -> Void
    private let drain: (Int) -> Void
    private let discard: () -> Void
    /// Data subpackets collected into one large write: per-write overhead in USB serial
    /// drivers dominates at small sizes.
    private var batch: [UInt8] = []
    static let batchSize = 16 * 1024
    /// Output allowed to sit in the serial port's queue while streaming.
    static let maxBacklog = 64 * 1024
    private let status: (String) -> Void
    private let logLine: (String) -> Void
    private var lastProgress = Date.distantPast
    private var rateStart = Date()
    private var rateBase = 0

    init(reader: ZReader, trace: ZmodemTrace?, output: @escaping (Data) -> Void, drain: @escaping (Int) -> Void,
         discard: @escaping () -> Void = {}, status: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.reader = reader
        self.trace = trace
        self.output = output
        self.drain = drain
        self.discard = discard
        self.status = status
        logLine = log
        reader.trace = trace
    }

    /// Sends immediately (after any batched data, preserving order).
    func send(_ bytes: [UInt8]) {
        if batch.isEmpty {
            output(Data(bytes))
        } else {
            batch += bytes
            flush()
        }
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    /// After a ZRPOS: drop data not yet on the wire, both our batch and what's queued at the
    /// port. Otherwise the receiver must wade through it, and may ask again and again.
    func discardUnsent() {
        batch.removeAll(keepingCapacity: true)
        discard()
    }

    /// Writes out batched data.
    func flush() {
        guard !batch.isEmpty else { return }
        output(Data(batch))
        batch.removeAll(keepingCapacity: true)
    }

    /// Block until queued output has been handed to the serial driver.
    func waitForOutput() {
        flush()
        drain(0)
    }

    /// While streaming: keep the port's queue topped up but bounded, so a ZRPOS takes effect quickly.
    func throttle() {
        drain(Self.maxBacklog)
    }

    func sendHex(_ h: ZHeader) {
        trace?.header(.tx, h)
        send(encoder.hexHeader(h))
    }

    func sendBinary(_ h: ZHeader, crc32: Bool) {
        var traced = h
        traced.format = crc32 ? Z.bin32 : Z.bin16
        trace?.header(.tx, traced)
        send(encoder.binaryHeader(h, crc32: crc32))
    }

    /// `payload`: file data (counted in the trace summary) rather than protocol data like ZFILE info.
    /// File data is batched into large writes; anything else is sent at once.
    func sendSubpacket(_ data: Data, end: UInt8, crc32: Bool, payload: Bool) {
        if let trace {
            trace.subpacketsOut += 1
            if payload { trace.dataBytesOut += data.count }
            if trace.verbose || !payload {
                trace.line(.tx, "  subpacket \(data.count) bytes, \(ZReader.endName(end)), CRC-\(crc32 ? 32 : 16)")
            }
        }
        let encoded = encoder.subpacket(data, end: end, crc32: crc32)
        if payload && end == Z.crcG {
            batch += encoded
            if batch.count >= Self.batchSize { flush() }
        } else {
            send(encoded)
        }
    }

    /// A line for both the session log and the trace.
    func log(_ text: String) {
        trace?.note(text)
        logLine(text)
    }

    func status(_ text: String) { status(text) }

    /// Which file of the batch is being transferred (1-based) and how many there are, if known.
    var fileNumber: (index: Int, count: Int?)?
    /// Bytes of the batch in files before this one, and in the whole batch, if known.
    var batchBytes: (before: Int, total: Int)?

    // Measured over the whole session, for the time-left estimate: file data moved and the time
    // spent moving it, and the gaps between one file's last data and the next file's first.
    // Nothing is assumed about the remote; the estimate adapts to whatever it does.
    private var dataBytes = 0
    private var dataTime: TimeInterval = 0
    private var lastDone = 0
    private var lastDataAt = Date()
    private var fileActive = false
    private var lastFileEnd: Date?
    private var gaps: [TimeInterval] = []

    /// Called when a file's data starts, and again from `offset` after a rewind.
    func startFile(at offset: Int) {
        let now = Date()
        if !fileActive, let end = lastFileEnd { gaps.append(now.timeIntervalSince(end)) }
        fileActive = true
        rateStart = now
        rateBase = offset
        lastDone = offset
        lastDataAt = now
        lastProgress = .distantPast
    }

    /// Called when a file's data is complete.
    func fileFinished() {
        if fileActive { lastFileEnd = lastDataAt }
        fileActive = false
    }

    /// Throttled progress line:
    /// "3/10, 37% of 2.8 MB, ~45 s left · Receiving name  45 KB / 100 KB (45%)  40 KB/s".
    func progress(_ verb: String, _ name: String, _ done: Int, _ total: Int?, force: Bool = false) {
        let now = Date()
        if fileActive, done > lastDone {
            dataBytes += done - lastDone
            dataTime += now.timeIntervalSince(lastDataAt)
            lastDone = done
            lastDataAt = now
        }
        guard force || now.timeIntervalSince(lastProgress) >= 0.1 else { return }
        lastProgress = now
        var line = "\(verb) \(name)  \(Self.size(done))"
        var batch: [String] = []
        if let n = fileNumber { batch.append("\(n.index)/\(n.count.map(String.init) ?? "?")") }
        if let b = batchBytes, b.total > 0 {
            let percent = min(100, (b.before + done) * 100 / b.total)
            batch.append("\(percent)% of \(Self.size(b.total))")
        }
        if let left = timeLeft(done: done, total: total) { batch.append("~\(Self.duration(left)) left") }
        if !batch.isEmpty { line = batch.joined(separator: ", ") + " · " + line }
        if let total, total > 0 {
            line += " / \(Self.size(total)) (\(done * 100 / total)%)"
        }
        let elapsed = now.timeIntervalSince(rateStart)
        if elapsed > 0.2 {
            line += "  \(Self.size(Int(Double(done - rateBase) / elapsed)))/s"
        }
        status(line)
    }

    /// Bytes left over the measured data rate, plus the average gap between files for each file
    /// still to start. Nil until there's a second of data to measure, or when nothing is left.
    private func timeLeft(done: Int, total: Int?) -> TimeInterval? {
        guard dataTime >= 1, dataBytes > 0 else { return nil }
        var bytesLeft: Int
        var filesAfter = 0
        if let b = batchBytes {
            bytesLeft = b.total - b.before - done
            if let n = fileNumber, let count = n.count { filesAfter = max(0, count - n.index) }
        } else if let total {
            bytesLeft = total - done
        } else {
            return nil
        }
        bytesLeft = max(0, bytesLeft)
        guard bytesLeft > 0 || filesAfter > 0 else { return nil }
        let gap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        return Self.estimate(bytesLeft: bytesLeft, rate: Double(dataBytes) / dataTime, filesAfter: filesAfter, gap: gap)
    }

    static func estimate(bytesLeft: Int, rate: Double, filesAfter: Int, gap: TimeInterval) -> TimeInterval {
        Double(bytesLeft) / rate + Double(filesAfter) * gap
    }

    /// "45 s", "3 min 05 s", "1 h 02 min".
    static func duration(_ t: TimeInterval) -> String {
        let s = max(1, Int(t.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return String(format: "%d min %02d s", s / 60, s % 60) }
        return String(format: "%d h %02d min", s / 3600, s % 3600 / 60)
    }

    static func size(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Sends a batch of files to a ZMODEM receiver.
final class ZmodemSender {
    private let link: ZLink
    private let options: ZmodemOptions
    private var reader: ZReader { link.reader }
    private var timeout: TimeInterval { options.timeout }

    private var useCRC32 = false
    /// Bytes between acknowledgements; 0 means stream continuously.
    private var window = 0

    init(link: ZLink, options: ZmodemOptions) {
        self.link = link
        self.options = options
    }

    struct Result {
        var sent: [String] = []
        var skipped: [String] = []
        var bytes = 0
    }

    func run(files: [URL]) throws -> Result {
        try handshake()

        var result = Result()
        for (i, url) in files.enumerated() {
            link.fileNumber = (i + 1, files.count)
            let remaining = files[(i + 1)...]
            let totalLeft = remaining.reduce(0) { $0 + ((try? Self.size(of: $1)) ?? 0) }
            let before = files[..<i].reduce(0) { $0 + ((try? Self.size(of: $1)) ?? 0) }
            link.batchBytes = (before, before + ((try? Self.size(of: url)) ?? 0) + totalLeft)
            switch try sendFile(url, filesLeft: remaining.count + 1, bytesLeft: totalLeft) {
            case let .sent(bytes):
                result.sent.append(url.lastPathComponent)
                result.bytes += bytes
            case .skipped:
                result.skipped.append(url.lastPathComponent)
            }
        }
        try finish()
        return result
    }

    // MARK: Session start and end

    private func handshake() throws {
        // "rz\r" starts the receiver if the remote is sitting at a shell prompt.
        link.trace?.line(.tx, "\"rz\\r\"")
        link.send("rz\r")
        link.sendHex(ZHeader(.rqinit))
        reader.waitingFor = "ZRINIT from receiver"
        for _ in 0..<6 {
            do {
                guard let h = try reader.readHeader(timeout: timeout) else { continue }
                switch h.frame {
                case .rinit:
                    configure(from: h)
                    return
                case .challenge:
                    link.sendHex(ZHeader(type: ZFrameType.ack.rawValue, p: h.p, format: Z.hex))
                case .rqinit:
                    link.trace?.note("ignoring ZRQINIT (probably our own, echoed before rz started)")
                default:
                    link.trace?.note("ignoring \(h.name) while waiting for ZRINIT")
                }
            } catch ZmodemError.timeout {
                link.sendHex(ZHeader(.rqinit))
            }
        }
        throw ZmodemError.protocolError("No ZMODEM receiver answered")
    }

    private func configure(from h: ZHeader) {
        let caps = h.zf0
        let buffer = Int(h.p[0]) | Int(h.p[1]) << 8
        useCRC32 = caps & Z.canFC32 != 0 && !options.forceCRC16
        window = buffer
        if window == 0 && (caps & Z.canOVIO == 0 || caps & Z.canFDX == 0) {
            // Receiver can't read while writing to disk, or is half duplex: wait for an ACK per block.
            window = options.blockSize
        }
        if options.window > 0 {
            window = window == 0 ? options.window : min(window, options.window)
        }
        link.encoder.escapeControls = caps & Z.escCtl != 0 || options.escapeControls
        link.log("ZMODEM receiver: \(ZHeader.capabilities(caps)), buffer \(buffer); using CRC-\(useCRC32 ? 32 : 16), "
            + "\(window == 0 ? "streaming" : "ACK every \(window) bytes"), block \(options.blockSize)"
            + (link.encoder.escapeControls ? ", escaping control characters" : ""))
    }

    private func finish() throws {
        reader.waitingFor = "ZFIN from receiver"
        for _ in 0..<5 {
            link.sendHex(ZHeader(.fin))
            do {
                if let h = try reader.readHeader(timeout: min(timeout, 5)), h.frame == .fin {
                    link.trace?.line(.tx, "\"OO\"")
                    link.send("OO")
                    link.waitForOutput()
                    return
                }
            } catch ZmodemError.timeout {
                continue
            }
        }
        // Every file was acknowledged; a missing ZFIN reply doesn't lose data.
        link.log("No ZFIN reply from receiver; ending anyway")
    }

    // MARK: One file

    private enum FileOutcome {
        case sent(Int)
        case skipped
    }

    private static func size(of url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private func sendFile(_ url: URL, filesLeft: Int, bytesLeft: Int) throws -> FileOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw ZmodemError.fileError("Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let name = url.lastPathComponent
        let mtime = Int((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        // name NUL "size mtime(octal) mode(octal) serial filesleft bytesleft" NUL
        let fields = "\(data.count) \(String(mtime, radix: 8)) 100644 0 \(filesLeft) \(data.count + bytesLeft)"
        let info = Array(name.utf8) + [0] + Array(fields.utf8) + [0]

        link.log("Sending \(name) (\(data.count) bytes)")
        link.status("Offering \(name)")

        // Offer the file until the receiver says where to start (or to skip it).
        var start: Int?
        var tries = 0
        offer: while start == nil {
            tries += 1
            if tries > 10 { throw ZmodemError.tooManyErrors("receiver did not accept \(name)") }
            if tries > 1 { link.trace?.note("offering \(name) again (attempt \(tries))") }
            link.sendBinary(ZHeader(.file, zf0: Z.convBinary), crc32: useCRC32)
            link.trace?.line(.tx, "  file \"\(name)\" \(fields)")
            link.sendSubpacket(Data(info), end: Z.crcW, crc32: useCRC32, payload: false)
            reader.waitingFor = "reply to ZFILE"
            var waitBriefly = false
            while true {
                let h: ZHeader?
                do {
                    // After a stray ZRINIT, give the real reply a moment before offering again.
                    h = try reader.readHeader(timeout: waitBriefly ? 1 : timeout)
                } catch ZmodemError.timeout {
                    continue offer
                }
                guard let h else { continue offer }
                switch h.frame {
                case .rpos:
                    start = h.position
                    continue offer
                case .skip:
                    link.log("Receiver skipped \(name)")
                    return .skipped
                case .crc:
                    // Receiver wants a CRC of the file (or its first N bytes) to decide about resuming.
                    let n = h.position == 0 ? data.count : min(h.position, data.count)
                    link.sendHex(ZHeader(.crc, position: Int(CRC.crc32(data.prefix(n)))))
                case .rinit:
                    if waitBriefly { continue offer }
                    waitBriefly = true
                case .nak:
                    continue offer
                case .abort, .ferr, .fin, .can:
                    throw ZmodemError.protocolError("Receiver refused \(name) (\(h.name))")
                default:
                    continue
                }
            }
        }

        var pos = min(start ?? 0, data.count)
        if pos > 0 { link.log("Receiver asked to start \(name) at \(pos)") }
        link.startFile(at: pos)
        var errors = 0
        let blockSize = max(32, options.blockSize)
        var lastRewind: (position: Int, time: Date)?
        /// A ZRPOS taken for a duplicate since the last rewind; see the ZEOF wait.
        var ignoredPosition: Int?

        /// lrzsz's receiver repeats ZRPOS while it skips the data that was in flight. A repeat of
        /// the position we just rewound to is a duplicate; acting on it would inject another ZDATA
        /// header into the stream the receiver has resumed, and errors snowball. A repeat after
        /// a while (e.g. the receiver's timeout) is genuine. So is a quick repeat when the data
        /// right after the rewind was damaged too, which only shows when the receiver then
        /// ignores our ZEOF.
        func isDuplicate(_ p: Int) -> Bool {
            guard let last = lastRewind, last.position == p, Date().timeIntervalSince(last.time) < 2 else { return false }
            link.log("Ignoring duplicate ZRPOS \(p) for \(name)")
            ignoredPosition = p
            return true
        }

        func rewind(to p: Int, _ why: String) throws {
            link.discardUnsent()
            lastRewind = (p, Date())
            ignoredPosition = nil
            errors += 1
            link.log("Resending \(name) from \(p) (\(why)); was at \(pos)")
            if errors > 30 { throw ZmodemError.tooManyErrors("\(name): receiver kept rejecting data") }
            guard p >= 0 && p <= data.count else { throw ZmodemError.protocolError("Receiver asked for invalid position \(p)") }
            pos = p
        }

        stream: while true {
            link.sendBinary(ZHeader(.data, position: pos), crc32: useCRC32)
            let streamStart = pos
            var sinceAck = 0
            var sinceDrain = 0

            while true {
                let n = min(blockSize, data.count - pos)
                let last = pos + n >= data.count
                let end: UInt8
                if last {
                    end = Z.crcE
                } else if window > 0 && sinceAck + n >= window {
                    end = Z.crcW
                } else {
                    end = Z.crcG
                }
                link.sendSubpacket(data[data.startIndex + pos ..< data.startIndex + pos + n], end: end,
                                   crc32: useCRC32, payload: true)
                pos += n
                sinceAck += n
                sinceDrain += n
                link.progress("Sending", name, pos, data.count)

                // Keep the port busy, with a bounded queue so a ZRPOS takes effect quickly.
                if sinceDrain >= ZLink.batchSize {
                    link.throttle()
                    sinceDrain = 0
                }

                if end == Z.crcW {
                    // Wait for the receiver to empty its buffer.
                    reader.waitingFor = "ZACK at \(pos)"
                    while true {
                        let h: ZHeader?
                        do {
                            h = try reader.readHeader(timeout: timeout)
                        } catch ZmodemError.timeout {
                            try rewind(to: pos - sinceAck, "no ZACK")
                            continue stream
                        }
                        guard let h else { continue }
                        if h.frame == .ack { continue stream }
                        if h.frame == .rpos {
                            if isDuplicate(h.position) { continue }
                            try rewind(to: h.position, "ZRPOS")
                            continue stream
                        }
                        if h.frame == .skip { return .skipped }
                    }
                }

                // Check the back channel for ZRPOS (receiver saw an error) without stopping the stream.
                while reader.hasPendingInput {
                    guard let h = try pollHeader() else { break }
                    switch h.frame {
                    case .rpos:
                        if isDuplicate(h.position) { continue }
                        try rewind(to: h.position, "receiver reported an error")
                        continue stream
                    case .skip:
                        return .skipped
                    case .abort, .ferr, .can:
                        throw ZmodemError.protocolError("Receiver aborted (\(h.name))")
                    default:
                        break
                    }
                }

                if last { break }
            }
            if let trace = link.trace, !trace.verbose {
                trace.line(.tx, "  data \(streamStart)..<\(pos) (\(pos - streamStart) bytes)")
            }

            // End of file: the receiver answers ZRINIT once it has everything.
            var eofTries = 0
            reader.waitingFor = "reply to ZEOF"
            eof: while true {
                link.sendBinary(ZHeader(.eof, position: data.count), crc32: useCRC32)
                eofTries += 1
                let deadline = Date().addingTimeInterval(timeout)
                while true {
                    let h: ZHeader?
                    do {
                        h = try reader.readHeader(timeout: max(0.05, deadline.timeIntervalSinceNow))
                    } catch ZmodemError.timeout {
                        // A receiver still waiting for data ignores ZEOF. If it's waiting at a
                        // position we ignored, that ZRPOS was genuine; without this, each side
                        // waits for the other until we give up.
                        if let p = ignoredPosition {
                            try rewind(to: p, "no reply to ZEOF after an ignored ZRPOS")
                            continue stream
                        }
                        if eofTries > 10 { throw ZmodemError.tooManyErrors("no reply to ZEOF") }
                        continue eof
                    }
                    guard let h else { continue eof }
                    switch h.frame {
                    case .rinit:
                        link.fileFinished()
                        link.progress("Sent", name, data.count, data.count, force: true)
                        link.log("Sent \(name)")
                        return .sent(data.count)
                    case .rpos:
                        // A duplicate isn't a reply: keep waiting rather than repeating ZEOF.
                        if isDuplicate(h.position) { continue }
                        try rewind(to: h.position, "ZRPOS after ZEOF")
                        continue stream
                    case .skip:
                        return .skipped
                    case .ack:
                        continue eof
                    case .abort, .ferr, .can:
                        throw ZmodemError.protocolError("Receiver aborted (\(h.name))")
                    default:
                        continue eof
                    }
                }
            }
        }
    }

    /// A header from the back channel if one is (being) received; nil if only noise is pending.
    private func pollHeader() throws -> ZHeader? {
        var noise: [UInt8] = []
        defer {
            if !noise.isEmpty, let trace = link.trace {
                trace.garbageBytes += noise.count
                trace.note("back channel: skipped \(noise.count) bytes: \(ZmodemTrace.hex(noise))")
            }
        }
        while reader.hasPendingInput {
            let b = try reader.byte(timeout: 0, quiet: true)
            if b & 0x7F == Z.pad || b == Z.can {
                reader.unread()
                return try reader.readHeader(timeout: 2, garbageLimit: 32)
            }
            noise.append(b)
        }
        return nil
    }
}
