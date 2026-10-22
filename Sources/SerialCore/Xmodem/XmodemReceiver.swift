// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Receives one file by XMODEM (saved under the name the user chose: XMODEM carries none), or a
/// batch by YMODEM into a directory, under the same safe names as the ZMODEM receiver's.
final class XmodemReceiver {
    private let link: ZLink
    private var reader: ZReader { link.reader }
    private let kind: TransferKind
    private let directory: URL
    /// Blocks carry a CRC-16 rather than the original arithmetic checksum.
    private var crc = true
    /// A block has checked out, so the sender's check type is known. Until then a block's length
    /// decides it: the sender may have answered an earlier 'C', or a NAK.
    private var checkKnown = false
    /// Something arrived during the last `next`, if only noise.
    private var heard = false
    /// A block has arrived: what the sender sent is a transfer, not stray text.
    private(set) var sawBlock = false
    /// The file being written, removed if the transfer fails part way, and its identity, so the
    /// removal can't hit a file that has replaced it meanwhile.
    private var partial: (url: URL, inode: UInt64)?
    private let timeout: TimeInterval
    private let crcAttempts: Int

    init(link: ZLink, kind: TransferKind, directory: URL, timeout: TimeInterval = X.timeout, crcAttempts: Int = X.crcAttempts) {
        self.link = link
        self.kind = kind
        self.directory = directory
        self.timeout = timeout
        self.crcAttempts = crcAttempts
    }

    struct Result {
        var received: [URL] = []
        var bytes = 0
    }

    private var name: String { kind.isYmodem ? "YMODEM" : "XMODEM" }
    /// The quiet after a 0x04 that makes it an EOT: the sender then waits for an answer, while
    /// a 0x04 in a block's data (its start lost) or in noise has more bytes right behind it.
    private var eotQuiet: TimeInterval { min(0.5, timeout / 10) }

    func run() throws -> Result {
        defer { removePartial() }
        switch kind {
        case let .xmodemReceive(target): return try receiveXmodem(as: target)
        case .ymodemReceive: return try receiveYmodem()
        default: return Result()
        }
    }

    private func checkCancelled() throws {
        if reader.isCancelled { throw ZmodemError.cancelled }
    }

    // MARK: XMODEM

    /// Written to a new file beside `target`, which replaces it only once everything has arrived:
    /// a failed transfer leaves an existing file as it was.
    private func receiveXmodem(as target: URL) throws -> Result {
        let folder = target.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".SerialTerm-\(UUID().uuidString).part")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw ZmodemError.fileError("Cannot save in \(folder.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        track(temp, handle)
        ZmodemReceiver.quarantine(temp)

        let first = try ask("the XMODEM sender", checksumFallback: true)
        link.log("Receiving by XMODEM (\(crc ? "CRC-16" : "checksum")) → \(target.lastPathComponent)")
        let bytes = try receiveData(first: first, into: handle, shownAs: target.lastPathComponent, size: nil)
        try? handle.close()
        guard rename(temp.path, target.path) == 0 else {
            throw ZmodemError.fileError("Cannot save \(target.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        partial = nil
        link.log("Received \(target.lastPathComponent) (\(bytes) bytes)")
        return Result(received: [target], bytes: bytes)
    }

    // MARK: YMODEM

    private func receiveYmodem() throws -> Result {
        var result = Result()
        var offeredFiles = 0, offeredBytes = 0
        while true {
            // Block 0: the next file's name and size, or an empty name at the end of the batch.
            let waitingFor = result.received.isEmpty && offeredFiles == 0 ? "the YMODEM sender" : "the next YMODEM file"
            var incoming = try ask(waitingFor, checksumFallback: false)
            while case .eot = incoming {
                // A repeat: our ACK of the last file's EOT was lost.
                send(X.ack, "ACK (repeated EOT)")
                incoming = try ask(waitingFor, checksumFallback: false)
            }
            guard case let .block(number, data) = incoming, number == 0 else {
                if case let .block(number, _) = incoming, offeredFiles > 0 {
                    throw ZmodemError.protocolError("Got block \(number) where the next file's name (block 0) should be")
                }
                throw ZmodemError.protocolError("The sender isn't using YMODEM (it sent data without a file name); try XMODEM")
            }
            let meta = ZmodemReceiver.FileInfo(data)
            guard !meta.name.isEmpty else {
                link.trace?.line(.rx, "  block 0: end of batch")
                send(X.ack, "ACK")
                link.waitForOutput()
                return result
            }
            let shown = SessionLogger.escapeNote(meta.name)
            offeredFiles += 1
            link.fileNumber = (offeredFiles, meta.filesLeft.map { offeredFiles - 1 + $0 })
            link.batchBytes = meta.bytesLeft.map { (offeredBytes, offeredBytes + $0) }
            offeredBytes = min(offeredBytes + (meta.size ?? 0), 1 << 60)
            link.trace?.line(.rx, "  block 0: file \"\(shown)\" fields \"\(SessionLogger.escapeNote(meta.rawFields))\" → "
                + "size \(meta.size.map(String.init) ?? "?"), mtime \(meta.modified.map { "\($0)" } ?? "none")")

            let url: URL, handle: FileHandle
            do {
                (url, handle) = try ZmodemReceiver.createUnique(in: directory, for: meta.name)
            } catch {
                // YMODEM can't skip a file; stopping is all that's left.
                throw ZmodemError.fileError("Cannot save \(shown) in \(directory.path): \(error.localizedDescription)")
            }
            defer { try? handle.close() }
            track(url, handle)
            ZmodemReceiver.quarantine(url)
            send(X.ack, "ACK")
            link.log("Receiving \(shown)\(meta.size.map { " (\($0) bytes)" } ?? "") → \(url.lastPathComponent)")

            let first = try ask("data for \(shown)", checksumFallback: false)
            // A size clamped to ZMODEM's limit isn't the real one; keep everything rather than cut it.
            let size = meta.size.flatMap { $0 < ZmodemReceiver.FileInfo.maxSize ? $0 : nil }
            let bytes = try receiveData(first: first, into: handle, shownAs: url.lastPathComponent, size: size)
            try? handle.close()
            if let size, bytes < size {
                // Removed as a partial file: a short file under its real name would pass for the whole.
                throw ZmodemError.fileError("\(shown): only \(bytes) of the \(size) bytes announced arrived")
            }
            if let mtime = meta.modified {
                try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            }
            partial = nil
            link.log("Received \(url.lastPathComponent) (\(bytes) bytes)")
            result.received.append(url)
            result.bytes += bytes
        }
    }

    // MARK: Blocks

    /// Data blocks from 1 until EOT, starting with `first`; returns the bytes written. With a
    /// `size` (YMODEM), the padding after it isn't written.
    private func receiveData(first: Incoming, into handle: FileHandle, shownAs name: String, size: Int?) throws -> Int {
        var expected: UInt8 = 1
        var written = 0
        var errors = 0
        var eotSeen = false
        link.startFile(at: 0)
        link.progress("Receiving", name, 0, size, force: true)
        var incoming = first
        while true {
            switch incoming {
            case let .block(n, data) where n == expected:
                eotSeen = false
                let keep = size.map { max(0, min(data.count, $0 - written)) } ?? data.count
                do {
                    try handle.write(contentsOf: data.prefix(keep))
                } catch {
                    throw ZmodemError.fileError("Cannot write \(name): \(error.localizedDescription)")
                }
                written += keep
                expected &+= 1
                errors = 0
                if let trace = link.trace {
                    trace.subpacketsIn += 1
                    trace.dataBytesIn += keep
                    if trace.verbose { trace.line(.rx, "  block \(n) (\(data.count) bytes) ok") }
                }
                link.progress("Receiving", name, written, size)
                send(X.ack, nil)
            case let .block(n, _) where n == expected &- 1:
                // Our ACK was lost and the sender repeated the block.
                eotSeen = false
                link.trace?.note("duplicate block \(n); acknowledging it again")
                send(X.ack, "ACK")
                // A repeated YMODEM header: the sender is waiting to be asked for the data again.
                if n == 0 && kind.isYmodem && written == 0 { send(X.crcRequest, "'C'") }
            case let .block(n, _):
                throw ZmodemError.protocolError("\(name): got block \(n), expected \(expected); the sender is out of step")
            case .eot where eotSeen:
                send(X.ack, "ACK (EOT)")
                return finish(name, written, size)
            case .eot:
                // A real EOT is repeated after a NAK; a byte of noise isn't.
                eotSeen = true
                send(X.nak, "NAK (first EOT)")
            case let .bad(why):
                errors += 1
                link.trace?.badSubpackets += 1
                link.trace?.note("bad block: \(why)")
                if errors > X.retries { throw ZmodemError.tooManyErrors("\(name): \(why)") }
                try purge()
                send(X.nak, "NAK")
            case .timeout where eotSeen:
                // A sender repeats EOT when it's NAKed. Never take one alone as the end: noise
                // would end the file early and pass the short file off as complete.
                errors += 1
                if errors > X.retries { throw ZmodemError.tooManyErrors("\(name): EOT not repeated") }
                send(X.nak, "NAK (waiting for EOT again)")
            case .timeout:
                errors += 1
                if errors > X.retries { throw ZmodemError.tooManyErrors("\(name): no data from the sender") }
                send(X.nak, "NAK (timeout)")
            }
            try checkCancelled()
            reader.waitingFor = eotSeen ? "a second EOT" : "block \(expected) of \(name)"
            incoming = try next(timeout: eotSeen ? min(3, timeout) : timeout)
        }
    }

    private func finish(_ name: String, _ written: Int, _ size: Int?) -> Int {
        link.waitForOutput()
        link.fileFinished()
        link.progress("Received", name, written, size, force: true)
        return written
    }

    /// Asks for the first block of a file (or a YMODEM header) every 3 s, for up to a minute,
    /// until one starts to arrive. XMODEM asks for CRC-16 ('C') until three requests have met
    /// silence, then for the checksum (NAK), for senders that only know the original protocol.
    /// (Damaged answers don't count: the sender is there, and has chosen CRC-16.)
    private func ask(_ what: String, checksumFallback: Bool) throws -> Incoming {
        var errors = 0, silent = 0
        for _ in 0..<20 {
            try checkCancelled()
            let checksum = checksumFallback && silent >= crcAttempts && !checkKnown
            if checksum && silent == crcAttempts && silent > 0 { link.log("No answer to 'C'; asking for checksum mode (NAK)") }
            if !checkKnown { crc = !checksum }
            send(checksum ? X.nak : X.crcRequest, checksum ? "NAK (checksum mode)" : "'C'")
            reader.waitingFor = what
            switch try next(timeout: min(3, timeout)) {
            case .timeout:
                if !heard { silent += 1 }
                continue
            case let .bad(why):
                errors += 1
                link.trace?.badSubpackets += 1
                link.trace?.note("bad block: \(why)")
                if errors > X.retries { throw ZmodemError.tooManyErrors("\(what): \(why)") }
                try purge()
            case let incoming:
                if !sawBlock {
                    sawBlock = true
                    reader.stopCapture()
                }
                return incoming
            }
        }
        throw ZmodemError.protocolError("No \(name) sender answered")
    }

    private enum Incoming {
        /// A block that checked out.
        case block(UInt8, [UInt8])
        case eot
        /// A damaged block: bad number, check value, or cut short.
        case bad(String)
        case timeout
    }

    /// The next block or EOT within `timeout`, skipping noise. Two CANs in a row where a block
    /// should start: the sender gave up. Among skipped bytes, which may be a block's data read
    /// after its start was lost, it takes five, as for ZMODEM (two turn up in 1.5% of 1 KB of
    /// random data; a real abort has eight or ten).
    ///
    /// An EOT is one byte with no check, so a 0x04 counts only when it is the first thing since our
    /// last answer and the line then goes quiet (`eotQuiet`). Otherwise it is data from a block
    /// whose start was lost, or noise, and is skipped like any other: taking it for EOT would end
    /// the file early, and answering it would put a second copy of a block in flight.
    private func next(timeout: TimeInterval) throws -> Incoming {
        heard = false
        let deadline = Uptime.now + timeout
        var noise: [UInt8] = []
        var skipped = 0
        defer {
            if skipped > 0, let trace = link.trace {
                trace.garbageBytes += skipped
                trace.note("skipped \(skipped) bytes: \(ZmodemTrace.hex(noise))")
            }
        }
        var cans = 0
        while true {
            let left = deadline - Uptime.now
            let b: UInt8
            do {
                guard left > 0 else { throw ZmodemError.timeout }
                b = try reader.byte(timeout: left)
            } catch ZmodemError.timeout {
                return .timeout
            }
            heard = true
            switch b {
            case X.soh, X.stx:
                return try readBlock(size: b == X.stx ? 1024 : 128)
            case X.eot where skipped == 0 && cans == 0:
                if (try? reader.byte(timeout: eotQuiet, quiet: true)) == nil {
                    try checkCancelled()
                    link.trace?.line(.rx, "  EOT")
                    return .eot
                }
                reader.unread()  // more follows: look at it as usual
                link.trace?.note("0x04 with more bytes right behind it: not an EOT")
                skipped += 1
                if noise.count < 48 { noise.append(b) }
            case X.can:
                cans += 1
                if cans >= (skipped == 0 ? 2 : 5) { throw ZmodemError.remoteCancelled }
                continue
            default:
                skipped += 1
                if noise.count < 48 { noise.append(b) }
            }
            if cans > 0 {
                skipped += cans  // they were data, not an abort
                cans = 0
            }
        }
    }

    /// The rest of a block after its start byte. Until the sender's check type is known, the
    /// block's length tells: a second check byte right behind the first is a CRC-16.
    private func readBlock(size: Int) throws -> Incoming {
        let count = 2 + size + 1  // number, its complement, data, the (first) check byte
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count + 1)
        func cutShort() -> Incoming { .bad("cut short after \(bytes.count) of \(count + (crc ? 1 : 0)) bytes") }
        while bytes.count < count {
            do {
                bytes.append(try reader.byte(timeout: X.byteTimeout, quiet: true))
            } catch ZmodemError.timeout {
                return cutShort()
            }
        }
        if crc || !checkKnown {
            // Expecting a CRC-16, give its second byte the usual time; otherwise just a moment.
            if let b = try? reader.byte(timeout: crc ? X.byteTimeout : min(0.3, eotQuiet), quiet: true) {
                bytes.append(b)
            } else {
                try checkCancelled()
                if crc && checkKnown { return cutShort() }
            }
        }
        let n = bytes[0]
        guard bytes[1] == ~n else { return .bad("block number \(n) with complement \(bytes[1])") }
        let data = Array(bytes[2..<(2 + size)])
        let withCRC = bytes.count == count + 1
        if withCRC {
            let got = UInt16(bytes[2 + size]) << 8 | UInt16(bytes[3 + size])
            guard got == CRC.crc16(data) else { return .bad("CRC-16 mismatch in block \(n)") }
        } else {
            guard bytes[2 + size] == X.checksum(data) else { return .bad("checksum mismatch in block \(n)") }
        }
        if !checkKnown {
            checkKnown = true
            if withCRC != crc { link.log("The sender uses \(withCRC ? "CRC-16" : "the checksum")") }
            crc = withCRC
        }
        return .block(n, data)
    }

    /// After a bad block: let the rest of it go by before the NAK, so the resend isn't read from
    /// the middle of the old one, and so there's one NAK for it. Waits for half a second of quiet,
    /// however long that takes (a 1K block takes 8.6 s at 1200 baud), up to `3 × timeout` for a
    /// line that never goes quiet.
    private func purge() throws {
        let end = Uptime.now + 3 * timeout
        var bytes: [UInt8] = []
        var cans = 0
        while Uptime.now < end, let b = try? reader.byte(timeout: 0.5, quiet: true) {
            // Five in a row: data has two now and then (see `next`).
            cans = b == X.can ? cans + 1 : 0
            if cans >= 5 { throw ZmodemError.remoteCancelled }
            bytes.append(b)
        }
        try checkCancelled()
        if !bytes.isEmpty { link.trace?.note("purged \(bytes.count) bytes before the NAK") }
    }

    private func send(_ byte: UInt8, _ traced: String?) {
        if byte == X.nak { link.trace?.naksOut += 1 }
        if let traced { link.trace?.line(.tx, "  " + traced) }
        link.send([byte])
    }

    private func track(_ url: URL, _ handle: FileHandle) {
        var st = stat()
        partial = (url, fstat(handle.fileDescriptor, &st) == 0 ? UInt64(st.st_ino) : 0)
    }

    private func removePartial() {
        guard let p = partial else { return }
        partial = nil
        // Only if the path is still the file we created.
        var st = stat()
        if lstat(p.url.path, &st) == 0, UInt64(st.st_ino) == p.inode {
            try? FileManager.default.removeItem(at: p.url)
        }
    }
}
