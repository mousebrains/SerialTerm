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

    /// The file being written, removed if the transfer fails part way.
    private var partial: URL?
    /// Files offered so far in this session, and their announced bytes, for batch progress.
    private var offeredFiles = 0
    private var offeredBytes = 0

    func run() throws -> Result {
        var result = Result()
        defer {
            if let partial { try? FileManager.default.removeItem(at: partial) }
        }

        // When auto-started, the sender's opening ZRQINIT is already waiting; read it (so it's
        // traced) before answering, rather than answering twice.
        if reader.hasPendingInput, let first = try? reader.readHeader(timeout: 1, garbageLimit: 64) {
            if first.frame != .rqinit { link.log("Sender opened with \(first.name) rather than ZRQINIT") }
        }
        sendReceiverInit()
        var timeouts = 0
        while true {
            reader.waitingFor = "a file from the sender"
            let h: ZHeader?
            do {
                h = try reader.readHeader(timeout: timeout)
            } catch ZmodemError.timeout {
                timeouts += 1
                if timeouts > 10 { throw ZmodemError.protocolError("No ZMODEM sender") }
                sendReceiverInit()
                continue
            }
            guard let h else {
                sendReceiverInit()
                continue
            }
            timeouts = 0

            switch h.frame {
            case .rqinit, .eof, .data:
                // Sender (re)starting, or it missed our ZRINIT after the last file.
                sendReceiverInit()
            case .sinit:
                // Carries the sender's attention string; we have no use for it.
                _ = try reader.readSubpacket(crc32: h.crc32, timeout: timeout)
                link.sendHex(ZHeader(.ack, position: 1))
            case .file:
                guard case let .data(info, _) = try reader.readSubpacket(crc32: h.crc32, timeout: timeout) else {
                    link.sendHex(ZHeader(.nak))
                    continue
                }
                if let url = try receiveFile(info: info) {
                    result.received.append(url)
                    result.bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
                sendReceiverInit()
            case .fin:
                link.sendHex(ZHeader(.fin))
                link.waitForOutput()
                // The sender closes with "OO"; read it so it doesn't reach the terminal.
                for _ in 0..<2 {
                    guard let b = try? reader.byte(timeout: 1), b == 0x4F else { break }
                }
                return result
            case .command:
                // Never run commands sent by the remote.
                _ = try reader.readSubpacket(crc32: h.crc32, timeout: timeout)
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

    private func sendReceiverInit() {
        // Full duplex, can receive while writing to disk, CRC-32; buffer size 0 = stream freely.
        var caps = Z.canFDX | Z.canOVIO
        if !options.forceCRC16 { caps |= Z.canFC32 }
        if options.escapeControls { caps |= Z.escCtl }
        link.sendHex(ZHeader(.rinit, zf0: caps))
    }

    /// Returns the saved file, or nil if it was skipped.
    private func receiveFile(info: [UInt8]) throws -> URL? {
        let meta = FileInfo(info)
        // "Files left" and "bytes left" count this file too.
        offeredFiles += 1
        link.fileNumber = (offeredFiles, meta.filesLeft.map { offeredFiles - 1 + $0 })
        link.batchBytes = meta.bytesLeft.map { (offeredBytes, offeredBytes + $0) }
        offeredBytes += meta.size ?? 0
        link.trace?.line(.rx, "  file \"\(meta.name)\" fields \"\(meta.rawFields)\" → size \(meta.size.map(String.init) ?? "?"), "
            + "mtime \(meta.modified.map { "\($0)" } ?? "none"), mode \(meta.mode.map { String($0, radix: 8) } ?? "?")")
        let url = Self.uniqueURL(in: directory, for: meta.name)
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            link.log("Cannot create \(url.path); skipping")
            link.sendHex(ZHeader(.skip))
            return nil
        }
        partial = url
        defer { try? handle.close() }

        link.log("Receiving \(meta.name)\(meta.size.map { " (\($0) bytes)" } ?? "") → \(url.lastPathComponent)")
        link.startFile(at: 0)
        link.progress("Receiving", url.lastPathComponent, 0, meta.size, force: true)

        var offset = 0
        var errors = 0
        func requestResend(_ why: String) throws {
            errors += 1
            if errors > 50 { throw ZmodemError.tooManyErrors("\(meta.name): \(why)") }
            if errors <= 10 || errors % 10 == 0 { link.log("\(meta.name): \(why); asking for data from \(offset)") }
            link.sendHex(ZHeader(.rpos, position: offset))
        }

        link.sendHex(ZHeader(.rpos, position: 0))
        var staleEOFDeadline: Date?
        while true {
            reader.waitingFor = "ZDATA/ZEOF for \(meta.name) at \(offset)"
            let wait = staleEOFDeadline.map { max(0.05, $0.timeIntervalSinceNow) } ?? timeout
            let deadline = Date().addingTimeInterval(wait)
            staleEOFDeadline = nil
            let h: ZHeader?
            do {
                // After an error the sender's in-flight data arrives before it reacts, so allow plenty of noise.
                h = try reader.readHeader(timeout: wait, garbageLimit: 1 << 22)
            } catch ZmodemError.timeout {
                try requestResend("timeout")
                continue
            }
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
                        do {
                            try handle.write(contentsOf: bytes)
                        } catch {
                            throw ZmodemError.fileError("Cannot write \(url.lastPathComponent): \(error.localizedDescription)")
                        }
                        offset += bytes.count
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
                // it (as lrzsz does) but keep our timeout running: a sender repeating ZEOF faster
                // than that would otherwise stop us from ever asking for the data again.
                guard h.position == offset else {
                    link.trace?.note("ignoring ZEOF at \(h.position); have \(offset) bytes")
                    staleEOFDeadline = deadline
                    continue
                }
                if let size = meta.size, size != offset {
                    link.log("\(meta.name): announced \(size) bytes but received \(offset)")
                }
                try? handle.close()
                if let mtime = meta.modified {
                    try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
                }
                partial = nil
                link.fileFinished()
                link.progress("Received", url.lastPathComponent, offset, meta.size, force: true)
                link.log("Received \(url.lastPathComponent) (\(offset) bytes)")
                return url
            case .file:
                // The sender didn't see our ZRPOS; read its offer again and answer.
                _ = try reader.readSubpacket(crc32: h.crc32, timeout: timeout)
                link.sendHex(ZHeader(.rpos, position: offset))
            case .skip:
                try? fm.removeItem(at: url)
                partial = nil
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

        init(_ bytes: [UInt8]) {
            let parts = bytes.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
            name = String(decoding: parts.first ?? [], as: UTF8.self)
            rawFields = parts.count > 1 ? String(decoding: parts[1].prefix { $0 != 0 }, as: UTF8.self) : ""
            let fields = rawFields.split(separator: " ")
            size = fields.count > 0 ? Int(fields[0]) : nil
            if fields.count > 1, let t = Int(fields[1], radix: 8), t > 0 {
                modified = Date(timeIntervalSince1970: TimeInterval(t))
            }
            if fields.count > 2 { mode = Int(fields[2], radix: 8) }
            if fields.count > 4, let n = Int(fields[4]), n > 0 { filesLeft = n }
            if fields.count > 5, let n = Int(fields[5]), n > 0 { bytesLeft = n }
        }
    }

    /// A safe local name: last path component only, no leading dots, no control characters,
    /// and "name (1).ext" style if the file already exists.
    static func uniqueURL(in directory: URL, for remoteName: String) -> URL {
        var base = remoteName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        base = String(base.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != ":" })
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "received" }

        let fm = FileManager.default
        var url = directory.appendingPathComponent(base)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 1
        while fm.fileExists(atPath: url.path) {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            url = directory.appendingPathComponent(name)
            n += 1
        }
        return url
    }
}
