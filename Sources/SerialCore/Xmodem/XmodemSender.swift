// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Sends one file by XMODEM, or a batch by YMODEM.
final class XmodemSender {
    private let link: ZLink
    private var reader: ZReader { link.reader }
    private let kind: TransferKind
    private let xmodem1K: Bool
    private let receiveCommand: String?
    private let typeReceiveCommand: ((String) -> Void)?
    /// The receiver asked for CRC-16 ('C') rather than the checksum (NAK).
    private var crc = true
    /// The receiver has asked for data: what arrives is a transfer, not a shell's reply.
    private(set) var receiverAnswered = false
    /// The last block's round trip, so a slow line doesn't time out every block.
    private var roundTrip: TimeInterval = 0
    private let timeout: TimeInterval
    /// How long to wait for the reply to a block or EOT before sending it again: a minute, as
    /// lrzsz's sender does (lsx 0.13.1 resends after 60 s of silence). A receiver NAKs every few
    /// seconds while it waits (lrzsz's rx every 4 s once data has started; ours every `timeout`),
    /// and that drives the resends. A resend of our own as well would put two copies of a block in
    /// flight, and their two ACKs (which carry no block number) would be taken for this block's
    /// and the next's.
    private var replyTimeout: TimeInterval { timeout * 6 + 2 * roundTrip }

    init(link: ZLink, kind: TransferKind, xmodem1K: Bool, receiveCommand: String?, typeReceiveCommand: ((String) -> Void)?,
         timeout: TimeInterval = X.timeout) {
        self.link = link
        self.kind = kind
        self.xmodem1K = xmodem1K
        self.receiveCommand = receiveCommand
        self.typeReceiveCommand = typeReceiveCommand
        self.timeout = timeout
    }

    struct Result {
        var sent = 0
        var bytes = 0
    }

    private var name: String { kind.isYmodem ? "YMODEM" : "XMODEM" }

    func run() throws -> Result {
        let files: [URL]
        switch kind {
        case let .xmodemSend(url): files = [url]
        case let .ymodemSend(urls): files = urls
        default: return Result()
        }
        let ymodem = kind.isYmodem
        guard !files.isEmpty else { throw ZmodemError.fileError("No files selected") }
        // Check every file first: one that can't be read fails the batch before anything is
        // typed. Each is opened again when its turn comes, so a big batch doesn't hold a
        // descriptor per file.
        let sizes = try files.map { try SendFile($0).count }

        startReceiver()
        var result = Result()
        let total = sizes.reduce(0, +)
        var before = 0
        for (i, url) in files.enumerated() {
            let source = try Source(url)
            try waitForReceiver(first: i == 0)
            link.fileNumber = ymodem ? (i + 1, files.count) : nil
            link.batchBytes = ymodem ? (before, total) : nil
            if ymodem {
                let info = X.header(name: source.name, size: source.size, modified: source.modified,
                                    filesLeft: files.count - i, bytesLeft: source.size + sizes[(i + 1)...].reduce(0, +))
                link.trace?.line(.tx, "  block 0: file \"\(SessionLogger.escapeNote(source.name))\" "
                    + SessionLogger.escapeNote(String(decoding: info.drop { $0 != 0 }.dropFirst().prefix { $0 != 0 }, as: UTF8.self)))
                try sendBlock(0, info, size: info.count > 128 ? 1024 : 128, pad: 0, opening: true)
                // The receiver asks for the data with another 'C'.
                try waitForReceiver(first: false)
            }
            try sendData(source)
            result.sent += 1
            result.bytes += source.size
            before += source.size
        }
        if ymodem {
            // An empty block 0 ends the batch.
            try waitForReceiver(first: false)
            link.trace?.line(.tx, "  block 0: end of batch")
            do {
                try sendBlock(0, [], size: 128, pad: 0, opening: true, tries: 2, wait: timeout, shellEnds: true)
            } catch ZmodemError.tooManyErrors {
                // Every file was acknowledged; a receiver that doesn't answer this loses nothing.
                link.log("No reply to the end of the YMODEM batch; ending anyway")
            }
        }
        // The remote's prompt may follow; leave it for the terminal.
        return result
    }

    private func checkCancelled() throws {
        if reader.isCancelled { throw ZmodemError.cancelled }
    }

    /// Types the remote's receive command, then takes in its echo, so a 'C' in it (or in the
    /// receiver's banner) isn't mistaken for the receiver asking for data.
    private func startReceiver() {
        guard let receiveCommand, !receiveCommand.isEmpty else { return }
        link.trace?.line(.tx, "\"\(SessionLogger.escapeNote(receiveCommand))\"")
        if let typeReceiveCommand {
            link.flush()
            typeReceiveCommand(receiveCommand)
        } else {
            link.send(receiveCommand)
            link.waitForOutput()
        }
        var last: UInt8?
        while reader.hasPendingInput, let b = try? reader.byte(timeout: 0, quiet: true) { last = b }
        // A receiver quick off the mark may have asked already; that's for `waitForReceiver`.
        if last == X.crcRequest || last == X.nak { reader.unread() }
    }

    /// Waits for the receiver's 'C' (CRC-16) or NAK (checksum). One counts only when the line
    /// then stays quiet for a moment: a receiver sends it alone and waits, while text that
    /// happens to contain a 'C' (the remote echoing "rx 'Config.bin'") carries on.
    private func waitForReceiver(first: Bool) throws {
        reader.waitingFor = first ? "the \(name) receiver to start" : "the receiver to ask for the next block"
        // A minute for the first (the remote's receiver may be slow to start), as lrzsz allows.
        let deadline = Uptime.now + timeout * (first ? 6 : 3)
        var cans = 0
        while true {
            try checkCancelled()
            let left = deadline - Uptime.now
            guard left > 0, let b = try? reader.byte(timeout: left, quiet: true) else {
                if reader.isCancelled { throw ZmodemError.cancelled }
                throw first ? ZmodemError.protocolError("No \(name) receiver answered")
                            : ZmodemError.timeout
            }
            if b == X.can {
                cans += 1
                if cans >= 2 { throw ZmodemError.remoteCancelled }
                continue
            }
            cans = 0
            guard b == X.crcRequest || b == X.nak else { continue }
            if (try? reader.byte(timeout: 0.1, quiet: true)) != nil {
                reader.unread()  // more follows: part of some text (or a repeat, which counts once it stops)
                continue
            }
            if !kind.isYmodem || first { crc = b == X.crcRequest }
            if first {
                link.log("\(name) receiver ready (\(crc ? "CRC-16" : "checksum"))")
                reader.stopCapture()
            }
            receiverAnswered = true
            return
        }
    }

    /// The file's data blocks, then EOT. The last block is padded with 0x1A, which XMODEM leaves
    /// in the received file, so a tail of 896 bytes or less goes in 128-byte blocks, as lrzsz
    /// sends it: the padding stays under 128 bytes either way.
    private func sendData(_ source: Source) throws {
        let oneK = kind.isYmodem || xmodem1K
        link.startFile(at: 0)
        link.progress("Sending", source.name, 0, source.size, force: true)
        var number: UInt8 = 1
        var pos = 0
        var last: (number: UInt8, data: [UInt8], size: Int)?
        while pos < source.size {
            let left = source.size - pos
            let size = oneK && left > 896 ? 1024 : 128
            let n = min(size, left)
            let data = [UInt8](try source.file.bytes(pos..<pos + n))
            try sendBlock(number, data, size: size, pad: X.eofPad, opening: pos == 0)
            last = (number, data, size)
            pos += n
            number &+= 1
            link.trace?.dataBytesOut += n
            link.progress("Sending", source.name, pos, source.size)
        }
        if let last { try settle(after: last.number, last.data, size: last.size) }
        try sendEOT()
        link.fileFinished()
        link.progress("Sent", source.name, source.size, source.size, force: true)
        link.log("Sent \(source.name) (\(source.size) bytes)")
    }

    /// Sends a block until the receiver ACKs it. `opening`: the first block the receiver gets,
    /// so a repeated 'C' (it missed the block) means send it again too. `wait`: for the reply,
    /// if not `replyTimeout`. `shellEnds`: the remote's shell answering means the receiver has
    /// finished (and its ACK was lost).
    private func sendBlock(_ number: UInt8, _ data: [UInt8], size: Int, pad: UInt8, opening: Bool,
                           tries: Int = X.retries, wait: TimeInterval? = nil, shellEnds: Bool = false) throws {
        let block = X.block(number, data, size: size, crc: crc, pad: pad)
        for attempt in 1...tries {
            try checkCancelled()
            try dropStaleReplies()
            if attempt > 1 { link.trace?.note("sending block \(number) again (attempt \(attempt))") }
            if let trace = link.trace {
                trace.subpacketsOut += 1
                if trace.verbose { trace.line(.tx, "  block \(number) (\(size) bytes, \(crc ? "CRC-16" : "checksum"))") }
            }
            link.send(block)
            link.waitForOutput()
            let sentAt = Uptime.now
            reader.waitingFor = "ACK of block \(number)"
            // Later on, a 'C' is line noise or a late repeat from the start: the real answer follows.
            var answer = try reply(timeout: wait ?? replyTimeout, crcCounts: opening, shellEnds: shellEnds)
            let afterC = answer == .crcRequest
            if afterC {
                // Perhaps a repeat that crossed the block on its way (a long round trip): give the
                // block's own answer time to come before sending a second copy, whose ACK would be
                // taken for the next block's.
                link.trace?.note("'C' again for block \(number); waiting for its answer before sending it again")
                answer = try reply(timeout: timeout, crcCounts: true, shellEnds: shellEnds)
            }
            switch answer {
            case .ack:
                roundTrip = Uptime.now - sentAt
                return
            case .shell:
                link.log("The remote's shell answered: the receiver has finished")
                return
            case .nak:
                link.trace?.note("NAK for block \(number)")
                link.trace?.naksIn += 1
                try awaitQuiet()
            case .crcRequest:
                link.trace?.note("'C' again for block \(number)")
            case .timeout:
                link.trace?.note(afterC ? "no answer after the repeated 'C': the receiver missed block \(number)"
                                        : "no reply to block \(number)")
            }
        }
        throw ZmodemError.tooManyErrors("block \(number) was never acknowledged")
    }

    /// After the last block's ACK, a moment for an answer still on its way, before EOT. One means
    /// the ACKs have been running a block behind (a block went out twice, and its second ACK was
    /// taken for the next block's): a NAK is then the last block's real answer, so it goes again;
    /// an ACK is just the real one. Without this a damaged last block would be lost, and the file
    /// end short with both ends reporting success.
    private func settle(after number: UInt8, _ data: [UInt8], size: Int) throws {
        for _ in 0..<3 {
            reader.waitingFor = "anything more about block \(number)"
            switch try reply(timeout: min(2, 0.2 + 2 * roundTrip), crcCounts: false) {
            case .timeout, .crcRequest, .shell:
                return
            case .ack:
                link.log("A late ACK after block \(number): the ACKs were a block behind")
            case .nak:
                link.log("A NAK after block \(number), the last: the ACKs were a block behind; sending it again")
                try sendBlock(number, data, size: size, pad: X.eofPad, opening: false)
            }
        }
    }

    /// EOT until the receiver ACKs it. YMODEM receivers NAK the first, in case it was noise.
    private func sendEOT() throws {
        for attempt in 1...X.retries {
            try checkCancelled()
            try dropStaleReplies()
            link.trace?.line(.tx, attempt == 1 ? "  EOT" : "  EOT (attempt \(attempt))")
            link.send([X.eot])
            link.waitForOutput()
            reader.waitingFor = "ACK of EOT"
            switch try reply(timeout: replyTimeout, crcCounts: kind.isYmodem, shellEnds: true) {
            case .ack:
                return
            case .shell:
                // Its ACK was lost; another EOT would be a ^D at the shell, which may log out.
                link.log("The remote's shell answered instead of an ACK for EOT: the receiver has finished")
                return
            case .nak:
                link.trace?.note("NAK for EOT")
                link.trace?.naksIn += 1
                try awaitQuiet()
            case .crcRequest:
                // A YMODEM receiver asking for the next file: it has this one, and its ACK was lost.
                link.trace?.note("'C' instead of ACK for EOT; the receiver has moved on")
                reader.unread()
                return
            case .timeout:
                continue
            }
        }
        throw ZmodemError.tooManyErrors("no reply to EOT")
    }

    private enum Reply { case ack, nak, crcRequest, shell, timeout }

    /// A file to send, read as it goes (see `SendFile`).
    private struct Source {
        let name: String
        let file: SendFile
        let modified: Date?
        var size: Int { file.count }

        init(_ url: URL) throws {
            name = url.lastPathComponent
            file = try SendFile(url)
            modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    /// The receiver's answer, skipping noise (a 'C' too, unless `crcCounts`). Two CANs in a row:
    /// it gave up. With `shellEnds`, text (two printable characters in a row, such as a prompt)
    /// means it has exited.
    private func reply(timeout: TimeInterval, crcCounts: Bool, shellEnds: Bool = false) throws -> Reply {
        let deadline = Uptime.now + timeout
        var cans = 0, text = 0
        while true {
            let left = deadline - Uptime.now
            let b: UInt8
            do {
                guard left > 0 else { throw ZmodemError.timeout }
                b = try reader.byte(timeout: left)
            } catch ZmodemError.timeout {
                return .timeout
            }
            switch b {
            case X.ack: return .ack
            case X.nak: return .nak
            case X.crcRequest where crcCounts: return .crcRequest
            case X.can:
                cans += 1
                if cans >= 2 { throw ZmodemError.remoteCancelled }
                continue
            default:
                link.trace?.garbageBytes += 1
                if shellEnds && (b == 0x0A || b == 0x0D || (0x20...0x7E).contains(b)) {
                    text += 1
                    if text >= 2 { return .shell }
                    cans = 0
                    continue
                }
            }
            cans = 0
            text = 0
        }
    }

    /// After a NAK, before sending again: until the receiver has been quiet for `nakQuiet`. Some
    /// NAK more than once for one damaged block; a copy for each would be in flight together. And
    /// a receiver clears the damaged block from its input before it can take a new one: lrzsz's
    /// rx (0.13.1) reads at most 1000 bytes of it, or until 0.1 s of quiet, then NAKs, so a 1K
    /// block whose start byte was lost gets a second NAK once the rest has gone by. A copy sent
    /// before that second NAK is cut up in turn; resending at once on every NAK, lrx sent ten and
    /// gave up.
    private func awaitQuiet() throws {
        let end = Uptime.now + timeout
        var more: [UInt8] = []
        while Uptime.now < end, let b = try? reader.byte(timeout: nakQuiet, quiet: true) {
            if b == X.can && more.last == X.can { throw ZmodemError.remoteCancelled }
            more.append(b)
        }
        try checkCancelled()
        if !more.isEmpty { link.trace?.note("after the NAK: \(ZmodemTrace.hex(more)) (taken as part of it)") }
    }

    /// 1 s: the receiver's second NAK comes 0.1 s after the rest of the block has reached it,
    /// later on a busy machine or a slow line. (Shorter with the short timeouts of tests.)
    private var nakQuiet: TimeInterval { min(1, timeout / 10) }

    /// ACKs carry no block number: a late ACK still waiting from a block sent twice would be
    /// taken for the next block's. Drop what's pending before each block, but not an abort.
    private func dropStaleReplies() throws {
        var dropped: [UInt8] = []
        while reader.hasPendingInput, let b = try? reader.byte(timeout: 0, quiet: true) {
            if b == X.can && dropped.last == X.can { throw ZmodemError.remoteCancelled }
            dropped.append(b)
        }
        if !dropped.isEmpty { link.trace?.note("dropped stale input: \(ZmodemTrace.hex(dropped))") }
    }
}
