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
    // Times here are `Uptime`, so a clock change can't distort the rate.
    private var lastProgress = -TimeInterval.infinity
    private var rateStart = Uptime.now
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
    private var lastDataAt = Uptime.now
    private var fileActive = false
    private var lastFileEnd: TimeInterval?
    private var gaps: [TimeInterval] = []

    /// Called when a file's data starts.
    func startFile(at offset: Int) {
        let now = Uptime.now
        if !fileActive, let end = lastFileEnd { gaps.append(now - end) }
        fileActive = true
        rateStart = now
        rateBase = offset
        lastDone = offset
        lastDataAt = now
        lastProgress = -.infinity
    }

    /// Called when the sender goes back to `offset`. Resent data counts as data moved (it crossed
    /// the line), but the stall before the rewind doesn't count as time spent moving it.
    func rewound(to offset: Int) {
        lastDone = offset
        lastDataAt = Uptime.now
    }

    /// Data rate measured so far (bytes a second), once there's a second of it.
    var dataRate: Double? {
        dataTime >= 1 && dataBytes > 0 ? Double(dataBytes) / dataTime : nil
    }

    /// Called when a file's data is complete.
    func fileFinished() {
        if fileActive { lastFileEnd = lastDataAt }
        fileActive = false
    }

    /// Throttled progress line:
    /// "3/10, 37% of 2.8 MB, ~45 s left · Receiving name  45 KB / 100 KB (45%)  40 KB/s".
    func progress(_ verb: String, _ name: String, _ done: Int, _ total: Int?, force: Bool = false) {
        let now = Uptime.now
        if fileActive, done > lastDone {
            dataBytes += done - lastDone
            dataTime += now - lastDataAt
            lastDone = done
            lastDataAt = now
        }
        guard force || now - lastProgress >= 0.1 else { return }
        lastProgress = now
        var line = "\(verb) \(name)  \(Self.size(done))"
        var batch: [String] = []
        if let n = fileNumber { batch.append("\(n.index)/\(n.count.map(String.init) ?? "?")") }
        if let b = batchBytes, b.total > 0 {
            // In floating point: the totals come from the remote and may be huge.
            let percent = Int(min(100, max(0, (Double(b.before) + Double(done)) * 100 / Double(b.total))))
            batch.append("\(percent)% of \(Self.size(b.total))")
        }
        if let left = timeLeft(done: done, total: total) { batch.append("~\(Self.duration(left)) left") }
        if !batch.isEmpty { line = batch.joined(separator: ", ") + " · " + line }
        if let total, total > 0 {
            line += " / \(Self.size(total)) (\(Int(min(100, max(0, Double(done) * 100 / Double(total)))))%)"
        }
        let elapsed = now - rateStart
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
        // Int(_:) traps on a value out of range, and the estimate's inputs come from the remote.
        let s = t.isFinite ? Int(min(max(t.rounded(), 1), 359_999_999)) : 359_999_999
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
    /// Data bytes per subpacket: the configured size, but never more than the receiver's buffer.
    private var blockSize = 1024
    /// While streaming, a ZCRCQ every this many bytes asks the receiver to confirm its position
    /// (ZACK) without stopping, so a resend after a lost reply starts close to where it is.
    static let confirmInterval = 32 * 1024

    private let receiveCommand: String
    /// Types the receive command at the session's typing pace; nil sends it at once.
    private let typeReceiveCommand: ((String) -> Void)?

    init(link: ZLink, options: ZmodemOptions, receiveCommand: String = "rz", typeReceiveCommand: ((String) -> Void)? = nil) {
        self.link = link
        self.options = options
        self.receiveCommand = receiveCommand
        self.typeReceiveCommand = typeReceiveCommand
        blockSize = max(32, options.blockSize)
    }

    struct Result {
        var sent: [String] = []
        var skipped: [String] = []
        var bytes = 0
    }

    func run(files: [URL]) throws -> Result {
        // ZMODEM positions are 32 bits; refuse before starting rather than fail 4 GB in.
        for url in files where ((try? Self.size(of: url)) ?? 0) > Int(UInt32.max) {
            throw ZmodemError.fileError("\(url.lastPathComponent) is larger than ZMODEM's 4 GiB limit")
        }
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

    private func checkCancelled() throws {
        if reader.isCancelled { throw ZmodemError.cancelled }
    }

    // MARK: Session start and end

    private func handshake() throws {
        // Starts the receiver if the remote is sitting at its prompt ("rz", or "zr" on a Slocum).
        // A receiver that is already running skips it as noise.
        if !receiveCommand.isEmpty {
            link.trace?.line(.tx, "\"\(receiveCommand)\\r\"")
            if let typeReceiveCommand {
                link.flush()
                typeReceiveCommand(receiveCommand + "\r")
            } else {
                link.send(receiveCommand + "\r")
            }
        }
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
            window = blockSize
        }
        if options.window > 0 {
            window = window == 0 ? options.window : min(window, options.window)
        }
        // A subpacket must fit in the receiver's buffer (as lrzsz does).
        if buffer > 0 { blockSize = min(blockSize, buffer) }
        link.encoder.escapeControls = caps & Z.escCtl != 0 || options.escapeControls
        link.log("ZMODEM receiver: \(ZHeader.capabilities(caps)), buffer \(buffer); using CRC-\(useCRC32 ? 32 : 16), "
            + "\(window == 0 ? "streaming" : "ACK every \(window) bytes"), block \(blockSize)"
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

        // Offer the file until the receiver says where to start (or to skip it). Each offer waits
        // at most `timeout` for a useful reply, however much else arrives meanwhile.
        var start: Int?
        var tries = 0
        var crcReplies = 0
        offer: while start == nil {
            try checkCancelled()
            tries += 1
            if tries > 10 { throw ZmodemError.tooManyErrors("receiver did not accept \(name)") }
            if tries > 1 { link.trace?.note("offering \(name) again (attempt \(tries))") }
            link.sendBinary(ZHeader(.file, zf0: Z.convBinary), crc32: useCRC32)
            link.trace?.line(.tx, "  file \"\(name)\" \(fields)")
            link.sendSubpacket(Data(info), end: Z.crcW, crc32: useCRC32, payload: false)
            reader.waitingFor = "reply to ZFILE"
            var deadline = Uptime.now + timeout
            while true {
                let h: ZHeader?
                do {
                    h = try reader.readHeader(timeout: max(0.05, deadline - Uptime.now))
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
                    crcReplies += 1
                    if crcReplies > 10 { throw ZmodemError.tooManyErrors("receiver kept asking for the CRC of \(name)") }
                    let n = h.position == 0 ? data.count : min(h.position, data.count)
                    link.sendHex(ZHeader(.crc, position: Int(CRC.crc32(data.prefix(n)))))
                    deadline = Uptime.now + timeout
                case .rinit:
                    // A stray ZRINIT (a repeat from before our offer): give the real reply a moment.
                    deadline = min(deadline, Uptime.now + 1)
                case .nak:
                    continue offer
                case .abort, .ferr, .fin, .can:
                    throw ZmodemError.protocolError("Receiver refused \(name) (\(h.name))")
                default:
                    break
                }
                if Uptime.now >= deadline { continue offer }
            }
        }

        var pos = min(start ?? 0, data.count)
        if pos > 0 { link.log("Receiver asked to start \(name) at \(pos)") }
        link.startFile(at: pos)
        // Rewinds since the receiver last confirmed new data: one stuck at a position fails the
        // file after 30, but one that keeps making progress, however slowly (a Slocum glider
        // overrunning after every burst), carries on, up to an overall limit that grows with the
        // file. lrzsz likewise counts only repeats at the same position.
        var errors = 0
        var rewinds = 0
        let maxRewinds = 30 + data.count / 1024
        var lastRewind: (position: Int, time: TimeInterval)?
        /// A ZRPOS taken for a duplicate since the last rewind; see the ZEOF wait.
        var ignoredPosition: Int?
        /// The receiver has said it has everything before this (its last ZRPOS or ZACK).
        var confirmed = pos
        /// Times in a row a silent receiver was prodded by resending from `confirmed`, without it
        /// confirming anything further; see the ZEOF wait.
        var prods = 0
        /// This file's ZEOF has gone out: from now on a ZRINIT means the receiver has it all.
        var eofSent = false

        /// lrzsz's receiver repeats ZRPOS while it skips the data that was in flight. A repeat of
        /// the position we just rewound to is a duplicate; acting on it would inject another ZDATA
        /// header into the stream the receiver has resumed, and errors snowball. A repeat after
        /// a while (e.g. the receiver's timeout) is genuine. So is a quick repeat when the data
        /// right after the rewind was damaged too, which only shows when the receiver then
        /// ignores our ZEOF. "A while" is at least 2 s, longer on a slow line, where the data in
        /// flight takes longer to drain.
        func isDuplicate(_ p: Int) -> Bool {
            let window = max(2, Double(8 * 1024) / (link.dataRate ?? .infinity))
            guard let last = lastRewind, last.position == p, Uptime.now - last.time < window else { return false }
            link.log("Ignoring duplicate ZRPOS \(p) for \(name)")
            ignoredPosition = p
            return true
        }

        /// The receiver reports having everything before `p`.
        func confirm(_ p: Int) {
            guard p <= data.count, p > confirmed else { return }
            confirmed = p
            prods = 0
            errors = 0
        }

        func rewind(to p: Int, _ why: String) throws {
            guard p >= 0 && p <= data.count else { throw ZmodemError.protocolError("Receiver asked for invalid position \(p)") }
            link.discardUnsent()
            lastRewind = (p, Uptime.now)
            ignoredPosition = nil
            if p > confirmed {
                // It's making progress, however slowly.
                prods = 0
                errors = 0
            }
            confirmed = p
            errors += 1
            rewinds += 1
            link.log("Resending \(name) from \(p) (\(why)); was at \(pos)")
            if errors > 30 || rewinds > maxRewinds { throw ZmodemError.tooManyErrors("\(name): receiver kept rejecting data") }
            pos = p
            link.rewound(to: p)
        }

        /// The receiver answered this file's ZEOF (perhaps a late or repeated answer).
        func finished() -> FileOutcome {
            link.discardUnsent()
            link.fileFinished()
            link.progress("Sent", name, data.count, data.count, force: true)
            link.log("Sent \(name)")
            return .sent(data.count)
        }

        stream: while true {
            try checkCancelled()
            link.sendBinary(ZHeader(.data, position: pos), crc32: useCRC32)
            let streamStart = pos
            var sinceAck = 0
            var sinceDrain = 0
            var sinceConfirm = 0

            while true {
                try checkCancelled()
                var n = min(blockSize, data.count - pos)
                // Never more between acknowledgements than the window (the receiver's buffer).
                if window > 0 { n = min(n, window - sinceAck) }
                let last = pos + n >= data.count
                let end: UInt8
                if last {
                    end = Z.crcE
                } else if window > 0 && sinceAck + n >= window {
                    end = Z.crcW
                } else if window == 0 && sinceConfirm + n >= Self.confirmInterval {
                    end = Z.crcQ
                    sinceConfirm = -n
                } else {
                    end = Z.crcG
                }
                link.sendSubpacket(data[data.startIndex + pos ..< data.startIndex + pos + n], end: end,
                                   crc32: useCRC32, payload: true)
                pos += n
                sinceAck += n
                sinceDrain += n
                sinceConfirm += n
                link.progress("Sending", name, pos, data.count)

                // Keep the port busy, with a bounded queue so a ZRPOS takes effect quickly.
                if sinceDrain >= ZLink.batchSize {
                    link.throttle()
                    sinceDrain = 0
                    try checkCancelled()
                }

                if end == Z.crcW {
                    // Wait for the receiver to empty its buffer, timing its silence from when the
                    // window has gone out, not from when it was queued: on a slow line that alone
                    // can take longer than the timeout.
                    reader.waitingFor = "ZACK at \(pos)"
                    link.waitForOutput()
                    try checkCancelled()
                    let deadline = Uptime.now + timeout
                    while true {
                        let h: ZHeader?
                        do {
                            h = try reader.readHeader(timeout: max(0.05, deadline - Uptime.now))
                        } catch ZmodemError.timeout {
                            try rewind(to: pos - sinceAck, "no ZACK")
                            continue stream
                        }
                        switch h?.frame {
                        case .ack?:
                            confirm(h!.position)
                            continue stream
                        case .rpos?:
                            if !isDuplicate(h!.position) {
                                try rewind(to: h!.position, "ZRPOS")
                                continue stream
                            }
                        case .skip?:
                            link.discardUnsent()
                            return .skipped
                        case .rinit? where eofSent:
                            return finished()
                        case .abort?, .ferr?, .can?, .fin?:
                            throw ZmodemError.protocolError("Receiver aborted (\(h!.name))")
                        default:
                            break
                        }
                        if Uptime.now >= deadline {
                            try rewind(to: pos - sinceAck, "no ZACK")
                            continue stream
                        }
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
                    case .ack:
                        confirm(h.position)
                    case .rinit where eofSent:
                        // Resending after a ZEOF whose answer was late: it has everything.
                        return finished()
                    case .skip:
                        link.discardUnsent()
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

            // End of file: the receiver answers ZRINIT once it has everything. At most 10 ZEOFs
            // per attempt, whatever comes back.
            var eofTries = 0
            reader.waitingFor = "reply to ZEOF"
            eof: while true {
                eofTries += 1
                if eofTries > 10 { throw ZmodemError.tooManyErrors("no reply to ZEOF") }
                link.sendBinary(ZHeader(.eof, position: data.count), crc32: useCRC32)
                eofSent = true
                // Time the receiver's silence from when the data has left, not from when it was
                // queued: at low baud rates the queue alone can take longer than the timeout.
                link.waitForOutput()
                try checkCancelled()
                let deadline = Uptime.now + timeout
                while true {
                    let h: ZHeader?
                    do {
                        h = try reader.readHeader(timeout: max(0.05, deadline - Uptime.now))
                    } catch ZmodemError.timeout {
                        // A receiver still waiting for data ignores ZEOF. If it's waiting at a
                        // position we ignored, that ZRPOS was genuine; without this, each side
                        // waits for the other until we give up.
                        if let p = ignoredPosition {
                            try rewind(to: p, "no reply to ZEOF after an ignored ZRPOS")
                            continue stream
                        }
                        // A receiver that lost data and whose ZRPOS was lost (or never sent: Slocum
                        // gliders go quiet after an overrun) waits for data at a position we don't
                        // know, and ignores ZEOF. Resend from the last position it confirmed: if
                        // that's where it is, the data flows; if not, it answers with a ZRPOS
                        // giving its position. The periodic ZCRCQ keeps `confirmed` close behind,
                        // so this resends little. Three tries without progress, so a receiver that
                        // has gone for good still fails.
                        if prods < 3 {
                            prods += 1
                            try rewind(to: confirmed, "no reply to ZEOF; resending from the last confirmed position")
                            continue stream
                        }
                        continue eof
                    }
                    guard let h else { continue eof }
                    switch h.frame {
                    case .rinit:
                        return finished()
                    case .rpos:
                        // A duplicate isn't a reply: keep waiting rather than repeating ZEOF.
                        if !isDuplicate(h.position) {
                            try rewind(to: h.position, "ZRPOS after ZEOF")
                            continue stream
                        }
                    case .ack:
                        // A late answer to a ZCRCQ.
                        confirm(h.position)
                    case .skip:
                        return .skipped
                    case .abort, .ferr, .can:
                        throw ZmodemError.protocolError("Receiver aborted (\(h.name))")
                    default:
                        continue eof
                    }
                    if Uptime.now >= deadline { continue eof }
                }
            }
        }
    }

    /// A header from the back channel if one is (being) received; nil if only noise is pending.
    /// A lone pad or CAN from line noise is skipped: waiting long for the rest of a "header" that
    /// never comes used to time out and fail the whole transfer.
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
                do {
                    return try reader.readHeader(timeout: 0.5, garbageLimit: 32)
                } catch ZmodemError.timeout {
                    link.trace?.note("back channel: incomplete header")
                    return nil
                }
            }
            noise.append(b)
        }
        return nil
    }
}
