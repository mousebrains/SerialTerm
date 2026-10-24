// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Receives a batch of files from a ZMODEM sender into a directory.
final class ZmodemReceiver {
    private let link: ZLink
    private var reader: ZReader { link.reader }
    private let directory: URL
    private let options: ZmodemOptions
    private var timeout: TimeInterval { options.timeout }

    init(link: ZLink, directory: URL, options: ZmodemOptions) {
        self.link = link
        self.directory = directory
        self.options = options
    }

    struct Result {
        var received: [URL] = []
        var bytes = 0
    }

    /// The file being written, removed if the transfer fails part way, and its identity, so the
    /// removal can't hit a file that has replaced it meanwhile.
    private var partial: (url: URL, inode: UInt64)?
    private let marks = QuarantineMarks()
    /// Files offered so far in this session, and their announced bytes, for batch progress.
    private var offeredFiles = 0
    private var offeredBytes = 0
    /// True once the sender has offered a file: what it sent is a transfer, not stray text.
    var sawFile: Bool { offeredFiles > 0 }

    func run() throws -> Result {
        var result = Result()
        defer {
            removePartial()
            marks.wait()
        }
        // Until a file is offered this may be no transfer at all (a header in ordinary output);
        // keep what arrives so it can be shown if so.
        reader.startCapture()

        // When auto-started, the sender's opening ZRQINIT is already waiting; read it (so it's
        // traced) before answering, rather than answering twice.
        if reader.hasPendingInput, let first = try? reader.readHeader(timeout: 1, garbageLimit: 64) {
            if first.frame != .rqinit { link.log("Sender opened with \(first.name) rather than ZRQINIT") }
        }
        sendReceiverInit()
        // Waiting for a file: give up after 10 silent timeouts; after 16 bad headers or runs of
        // noise (each up to 1 KB), or noise for `timeout` without a valid header (a sender's
        // headers come promptly); after 3 echoes of our own ZRINIT; or after 40 headers that lead
        // nowhere. So a device that is streaming, echoing or babbling can't hold the session for
        // long, and what it sent is then shown after all.
        var timeouts = 0, noise = 0, echoes = 0, unproductive = 0
        var noiseSince: TimeInterval?
        /// A ZDATA header has come: what follows up to the next header is a sender's data.
        var resent = false
        defer { reader.deadline = nil }
        while true {
            reader.waitingFor = "a file from the sender"
            reader.deadline = noiseSince.map { $0 + timeout }
            let h: ZHeader?
            do {
                defer { resent = false }
                h = try reader.readHeader(timeout: timeout, garbageLimit: resent ? 1 << 22 : 1024)
            } catch ZmodemError.timeout {
                if let start = noiseSince, Uptime.now >= start + timeout {
                    throw ZmodemError.protocolError("No ZMODEM sender (only noise received)")
                }
                timeouts += 1
                if timeouts > 10 { throw ZmodemError.protocolError("No ZMODEM sender") }
                sendReceiverInit()
                continue
            }
            timeouts = 0
            guard let h else {
                noise += 1
                if noise > 16 { throw ZmodemError.protocolError("No ZMODEM sender (only noise received)") }
                if noiseSince == nil { noiseSince = Uptime.now }
                continue
            }
            noiseSince = nil
            unproductive += 1
            if unproductive > 40 { throw ZmodemError.protocolError("No file offered by the sender") }

            switch h.frame {
            case .rqinit, .eof:
                // Sender (re)starting, or it missed our ZRINIT after the last file.
                sendReceiverInit()
            case .data:
                // Data for a file we have: our answer to its ZEOF was late, and the sender went
                // back to where we last confirmed. Answer again, and let the data go by up to the
                // next header, as after a ZRPOS: it's a sender's, not noise.
                link.trace?.note("data at \(h.position) for a file already received; skipping it")
                sendReceiverInit()
                resent = true
            case .rinit:
                // That's what we send: the remote is echoing us (or is a receiver too). Answering
                // would echo back and forth forever.
                echoes += 1
                if echoes >= 3 {
                    throw ZmodemError.protocolError("The remote sends back what it receives; no ZMODEM sender is running")
                }
            case .sinit:
                // Carries the sender's attention string; we have no use for it.
                if case .data = try readOfferSubpacket(h) { link.sendHex(ZHeader(.ack, position: 1)) }
            case .file:
                guard case let .data(info, _) = try readOfferSubpacket(h) else {
                    link.sendHex(ZHeader(.nak))
                    continue
                }
                reader.stopCapture()
                unproductive = 0
                noise = 0
                // Its size as counted: asking the file system can wait on the file's quarantine mark,
                // and the sender is waiting for our answer to its ZEOF.
                if let (url, bytes) = try receiveFile(info: info) {
                    result.received.append(url)
                    result.bytes += bytes
                }
                sendReceiverInit()
            case .fin:
                link.sendHex(ZHeader(.fin))
                link.waitForOutput()
                // The sender closes with "OO"; read it so it doesn't reach the terminal, but leave
                // anything else (the remote's prompt) for the terminal.
                for _ in 0..<2 {
                    guard let b = try? reader.byte(timeout: 1, quiet: true) else { break }
                    if b != 0x4F {
                        reader.unread()
                        break
                    }
                }
                return result
            case .command:
                // Never run commands sent by the remote.
                _ = try readOfferSubpacket(h)
                link.log("Refused ZCOMMAND from sender")
                link.sendHex(ZHeader(.compl, position: 1))
            case .freecnt:
                link.sendHex(ZHeader(.ack, position: 0x7FFF_FFFF))
            case .abort, .ferr, .can:
                throw ZmodemError.remoteCancelled
            default:
                sendReceiverInit()
            }
        }
    }

    /// The subpacket after ZFILE, ZSINIT or ZCOMMAND. A timeout in it (its end was lost) is
    /// treated like a damaged one: the sender offers again, rather than the batch failing.
    private func readOfferSubpacket(_ h: ZHeader) throws -> ZReader.Subpacket {
        do {
            return try reader.readSubpacket(crc32: h.crc32, timeout: timeout)
        } catch ZmodemError.timeout {
            link.trace?.note("timeout in the \(h.name) subpacket")
            return .bad("timeout")
        }
    }

    private func sendReceiverInit() {
        var caps = Z.canFDX | Z.canOVIO
        if !options.forceCRC16 { caps |= Z.canFC32 }
        if options.escapeControls { caps |= Z.escCtl }
        link.sendHex(ZHeader(.rinit, zf0: caps))
    }

    private func removePartial() {
        guard let p = partial else { return }
        partial = nil
        // The mark goes by path: not on whatever might take the file's place.
        marks.wait()
        // Only if the path is still the file we created.
        var st = stat()
        if lstat(p.url.path, &st) == 0, UInt64(st.st_ino) == p.inode {
            try? FileManager.default.removeItem(at: p.url)
        }
    }

    /// Returns the saved file and its size, or nil if it was skipped.
    private func receiveFile(info: [UInt8]) throws -> (URL, Int)? {
        let meta = FileInfo(info)
        // The name as it may appear in logs and traces: it comes from the remote.
        let name = SessionLogger.escapeNote(meta.name)
        // "Files left" and "bytes left" count this file too.
        offeredFiles += 1
        link.fileNumber = (offeredFiles, meta.filesLeft.map { offeredFiles - 1 + $0 })
        link.batchBytes = meta.bytesLeft.map { (offeredBytes, offeredBytes + $0) }
        offeredBytes = min(offeredBytes + (meta.size ?? 0), 1 << 60)
        link.trace?.line(.rx, "  file \"\(name)\" fields \"\(SessionLogger.escapeNote(meta.rawFields))\" → "
            + "size \(meta.size.map(String.init) ?? "?"), mtime \(meta.modified.map { "\($0)" } ?? "none"), "
            + "mode \(meta.mode.map { String($0, radix: 8) } ?? "?")")
        let url: URL, handle: FileHandle
        do {
            (url, handle) = try Self.createUnique(in: directory, for: meta.name)
        } catch {
            link.log("Cannot save \(name) in \(directory.path): \(error.localizedDescription); skipping")
            link.sendHex(ZHeader(.skip))
            return nil
        }
        var st = stat()
        partial = (url, fstat(handle.fileDescriptor, &st) == 0 ? UInt64(st.st_ino) : 0)
        defer { try? handle.close() }
        marks.add(url)

        link.log("Receiving \(name)\(meta.size.map { " (\($0) bytes)" } ?? "") → \(url.lastPathComponent)")
        link.startFile(at: 0)
        link.progress("Receiving", url.lastPathComponent, 0, meta.size, force: true)

        var offset = 0
        // Resend requests since the data last moved forward: a sender stuck at one place fails
        // the file after 50, while one that keeps making progress may carry on, up to an overall
        // limit that grows with the file.
        var errors = 0, totalErrors = 0, progressAt = 0
        // Without new data by this time, ask again, however busy the line is with other things
        // (stale ZEOFs, ignored headers, noise).
        var progressDeadline = Uptime.now + timeout
        defer { reader.deadline = nil }
        func requestResend(_ why: String) throws {
            if offset > progressAt {
                errors = 0
                progressAt = offset
            }
            errors += 1
            totalErrors += 1
            if errors > 50 || totalErrors > 50 + offset / 4096 { throw ZmodemError.tooManyErrors("\(name): \(why)") }
            if totalErrors <= 10 || totalErrors % 10 == 0 { link.log("\(name): \(why); asking for data from \(offset)") }
            link.sendHex(ZHeader(.rpos, position: offset))
            progressDeadline = Uptime.now + timeout
        }

        link.sendHex(ZHeader(.rpos, position: 0))
        while true {
            reader.waitingFor = "ZDATA/ZEOF for \(name) at \(offset)"
            reader.deadline = progressDeadline
            let h: ZHeader?
            do {
                // After an error the sender's in-flight data arrives before it reacts, so allow plenty of noise.
                h = try reader.readHeader(timeout: timeout, garbageLimit: 1 << 22)
            } catch ZmodemError.timeout {
                try requestResend("no data")
                continue
            }
            reader.deadline = nil
            guard let h else {
                try requestResend("bad header")
                continue
            }

            switch h.frame {
            case .data:
                guard h.position == offset else {
                    // Data from before our last ZRPOS; ask again so the sender rewinds.
                    try requestResend("data at \(h.position), expected \(offset)")
                    continue
                }
                progressDeadline = Uptime.now + timeout
                let runStart = offset
                defer {
                    if let trace = link.trace, !trace.verbose, offset > runStart {
                        trace.line(.rx, "  data \(runStart)..<\(offset) (\(offset - runStart) bytes)")
                    }
                }
                subpackets: while true {
                    let packet: ZReader.Subpacket
                    do {
                        packet = try reader.readSubpacket(crc32: h.crc32, timeout: timeout)
                    } catch ZmodemError.timeout {
                        try requestResend("timeout in data")
                        break subpackets
                    }
                    switch packet {
                    case let .bad(why):
                        try requestResend(why)
                        break subpackets
                    case let .data(bytes, end):
                        // ZMODEM positions are 32 bits.
                        guard offset + bytes.count <= Int(UInt32.max) else {
                            throw ZmodemError.fileError("\(name) is larger than ZMODEM's 4 GiB limit")
                        }
                        do {
                            try handle.write(contentsOf: bytes)
                        } catch {
                            throw ZmodemError.fileError("Cannot write \(url.lastPathComponent): \(error.localizedDescription)")
                        }
                        offset += bytes.count
                        progressDeadline = Uptime.now + timeout
                        link.trace?.dataBytesIn += bytes.count
                        link.progress("Receiving", url.lastPathComponent, offset, meta.size)
                        switch end {
                        case Z.crcW:
                            link.sendHex(ZHeader(.ack, position: offset))
                            break subpackets
                        case Z.crcQ:
                            link.sendHex(ZHeader(.ack, position: offset))
                        case Z.crcE:
                            break subpackets
                        default:
                            continue
                        }
                    }
                }
            case .eof:
                // A ZEOF for a different offset may have left before our ZRPOS arrived, so ignore
                // it (as lrzsz does). The progress deadline keeps running, so a sender repeating
                // ZEOF can't stop us from asking for the data again.
                guard h.position == offset else {
                    link.trace?.note("ignoring ZEOF at \(h.position); have \(offset) bytes")
                    continue
                }
                if let size = meta.size, size != offset {
                    link.log("\(name): announced \(size) bytes but received \(offset)")
                }
                try? handle.close()
                if let mtime = meta.modified {
                    try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
                }
                partial = nil
                link.fileFinished()
                link.progress("Received", url.lastPathComponent, offset, meta.size, force: true)
                link.log("Received \(url.lastPathComponent) (\(offset) bytes)")
                return (url, offset)
            case .file:
                // The sender didn't see our ZRPOS; read its offer again and answer.
                _ = try readOfferSubpacket(h)
                link.sendHex(ZHeader(.rpos, position: offset))
            case .skip:
                removePartial()
                return nil
            case .nak:
                link.sendHex(ZHeader(.rpos, position: offset))
            case .abort, .ferr, .can, .fin:
                throw ZmodemError.remoteCancelled
            default:
                continue
            }
        }
    }

    /// The ZFILE subpacket: "name\0size mtime mode serial filesleft bytesleft\0".
    struct FileInfo {
        var name: String
        var size: Int?
        var modified: Date?
        var mode: Int?
        /// Files and bytes still to come in the batch, this file included (optional; lrzsz and the
        /// Slocum send them).
        var filesLeft: Int?
        var bytesLeft: Int?
        /// Everything after the name, as sent, for diagnostics.
        var rawFields = ""

        // The numbers come from the remote: clamp them, so arithmetic on them can't overflow
        // (which traps, taking the app down). A size can't exceed ZMODEM's 32-bit positions anyway.
        static let maxSize = Int(UInt32.max)
        static let maxFiles = 1_000_000
        static let maxBatchBytes = 1 << 50
        /// 9999-12-31: later modification times are nonsense.
        static let maxTime = 253_402_300_799

        init(_ bytes: [UInt8]) {
            let parts = bytes.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
            name = String(decoding: parts.first ?? [], as: UTF8.self)
            rawFields = parts.count > 1 ? String(decoding: parts[1].prefix { $0 != 0 }, as: UTF8.self) : ""
            let fields = rawFields.split(separator: " ")
            size = fields.count > 0 ? Int(fields[0]).map { min(max($0, 0), Self.maxSize) } : nil
            if fields.count > 1, let t = Int(fields[1], radix: 8), t > 0, t <= Self.maxTime {
                modified = Date(timeIntervalSince1970: TimeInterval(t))
            }
            if fields.count > 2 { mode = Int(fields[2], radix: 8) }
            if fields.count > 4, let n = Int(fields[4]), n > 0 { filesLeft = min(n, Self.maxFiles) }
            if fields.count > 5, let n = Int(fields[5]), n > 0 { bytesLeft = min(n, Self.maxBatchBytes) }
        }
    }

    /// A safe local name for `remoteName`, as stem and extension: the last path component only;
    /// no leading dots, control characters, invisible formatting characters (bidirectional
    /// overrides, zero-width characters) or ':'; and short enough for "name (9999).ext" to fit
    /// in 255 bytes.
    static func safeName(_ remoteName: String) -> (stem: String, ext: String) {
        var base = remoteName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        base = String(String.UnicodeScalarView(base.unicodeScalars.filter { s in
            switch s.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return s != ":"
            }
        }))
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "received" }
        var stem = base, ext = ""
        if let dot = base.lastIndex(of: "."), base.distance(from: dot, to: base.endIndex) <= 33 {
            stem = String(base[..<dot])
            ext = String(base[base.index(after: dot)...])
        }
        let room = 255 - " (9999)".utf8.count - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        while stem.utf8.count > room { stem.removeLast() }
        return (stem, ext)
    }

    private static func name(_ stem: String, _ ext: String, _ n: Int) -> String {
        let s = n == 0 ? stem : "\(stem) (\(n))"
        return ext.isEmpty ? s : "\(s).\(ext)"
    }

    /// Creates a new file with a safe name in `directory`, "name (1).ext" style if the name is
    /// taken. It never replaces anything, even a file another window created a moment ago, and
    /// never follows a symlink.
    static func createUnique(in directory: URL, for remoteName: String) throws -> (URL, FileHandle) {
        let (stem, ext) = safeName(remoteName)
        for n in 0..<10_000 {
            let url = directory.appendingPathComponent(name(stem, ext, n))
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd >= 0 { return (url, FileHandle(fileDescriptor: fd, closeOnDealloc: true)) }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }

    /// The first unused safe name for `remoteName` in `directory` (for files lrzsz received,
    /// which are then moved there; a move never replaces an existing file).
    static func uniqueURL(in directory: URL, for remoteName: String) -> URL {
        let (stem, ext) = safeName(remoteName)
        let fm = FileManager.default
        var n = 0
        var url = directory.appendingPathComponent(name(stem, ext, 0))
        while fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            n += 1
            url = directory.appendingPathComponent(name(stem, ext, n))
        }
        return url
    }

    /// Marks a received file as downloaded, as browsers do, so Gatekeeper checks it before it can
    /// run: a received `.command` file or app would otherwise open without a prompt.
    static func quarantine(_ url: URL) {
        #if os(macOS)
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineAgentName": "SerialTerm", "LSQuarantineType": "LSQuarantineTypeOtherDownload"]
        var url = url
        try? url.setResourceValues(values)
        #endif
    }
}

/// Marks received files as downloaded (`ZmodemReceiver.quarantine`) on another thread, so the
/// answer to the sender doesn't wait for it: on a busy Mac it has taken seconds, and a sender
/// that hears nothing for its timeout offers the file again. `wait` before a file is moved,
/// removed, or reported received.
final class QuarantineMarks {
    private let group = DispatchGroup()

    /// On a thread of its own: with GCD's global threads all busy, a block can wait seconds to start.
    func add(_ url: URL) {
        group.enter()
        let thread = Thread { [group] in
            ZmodemReceiver.quarantine(url)
            group.leave()
        }
        thread.name = "Quarantine mark"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Returns once every file added has been marked.
    func wait() {
        group.wait()
    }
}
