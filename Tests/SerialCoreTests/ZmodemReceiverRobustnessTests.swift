// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Darwin
import Foundation
import Testing
@testable import SerialCore

/// Drives a bare receive (`ZmodemTransfer(.zmodemReceive)`) with hand-built frames, playing a
/// sender that may be broken or hostile.
final class RxHarness: @unchecked Sendable {
    let dst: URL
    let receiver: ZmodemTransfer
    let out = Inbox<Data>()
    let results = Inbox<(Bool, String)>()
    let logs = Inbox<String>()
    var e = ZEncoder()

    init(timeout: TimeInterval, traceURL: URL? = nil, level: ZmodemOptions.TraceLevel = .off) throws {
        dst = FileManager.default.temporaryDirectory.appendingPathComponent("ZScratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        var options = ZmodemOptions()
        options.timeout = timeout
        options.traceLevel = level
        receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: options, traceURL: traceURL)
        receiver.onOutput = { [out] in out.add($0) }
        receiver.onFinish = { [results] in results.add(($0, $1)) }
        receiver.onLog = { [logs] in logs.add($0) }
    }

    func start() throws {
        try receiver.start()
        #expect(out.wait(timeout: 5) { !$0.isEmpty })
    }

    func offer(_ name: String, _ fields: String) {
        let info = Array(name.utf8) + [0] + Array(fields.utf8) + [0]
        receiver.feed(Data(e.binaryHeader(ZHeader(.file, zf0: Z.convBinary), crc32: true)
            + e.subpacket(Data(info), end: Z.crcW, crc32: true)))
    }

    func header(_ h: ZHeader) { receiver.feed(Data(e.binaryHeader(h, crc32: true))) }

    func data(_ bytes: [UInt8], end: UInt8) { receiver.feed(Data(e.subpacket(Data(bytes), end: end, crc32: true))) }

    var sent: Data { out.all.reduce(Data(), +) }
    func count(_ s: String) -> Int { occurrences(of: Data(s.utf8), in: sent) }
}

/// Flips the byte `distance` bytes after each of the first `times` occurrences of a pattern, in
/// one pass (many `PatternMangler`s are slow in a debug build).
final class RepeatedPatternMangler: @unchecked Sendable {
    private let lock = NSLock()
    private let pattern: [UInt8]
    private let distance: Int
    private var left: Int
    private var matched = 0
    private var countdown: Int?

    init(after pattern: [UInt8], times: Int, distance: Int) {
        self.pattern = pattern
        self.distance = distance
        left = times
    }

    func apply(_ data: Data) -> Data {
        lock.withLock {
            var out = [UInt8](data)
            for i in out.indices {
                if let c = countdown {
                    if c == 0 {
                        out[i] ^= 0x55
                        countdown = nil
                    } else {
                        countdown = c - 1
                    }
                }
                matched = out[i] == pattern[matched] ? matched + 1 : (out[i] == pattern[0] ? 1 : 0)
                if matched == pattern.count {
                    matched = 0
                    if left > 0, countdown == nil {
                        left -= 1
                        countdown = distance
                    }
                }
            }
            return Data(out)
        }
    }
}

/// The native receiver against senders that are broken, hostile or not senders at all. Each test is
/// a defect found in the review in issue #4 that the old receiver failed.
@Suite(.serialized)
struct ZmodemReceiverRobustnessTests {
    // MARK: Numbers in the file offer used to crash the app (integer overflow traps)

    @Test func hugeSizesInSuccessiveOffers() throws {
        let h = try RxHarness(timeout: 2)
        try h.start()
        h.offer("a.bin", "9223372036854775807 0 0 0")
        usleep(200_000)
        h.header(ZHeader(.eof, position: 0))
        usleep(300_000)
        h.offer("b.bin", "9223372036854775807 0 0 0")
        usleep(500_000)
        h.receiver.cancel()
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
    }

    @Test func hugeSizeAndASlowFirstByte() throws {
        let h = try RxHarness(timeout: 5)
        try h.start()
        h.offer("a.bin", "9223372036854775807 0 0 0")
        usleep(200_000)
        h.header(ZHeader(.data, position: 0))
        usleep(1_500_000)  // enough for a time-left estimate
        h.data([0x41], end: Z.crcG)
        usleep(500_000)
        h.receiver.cancel()
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
    }

    @Test func hugeBatchTotals() throws {
        let h = try RxHarness(timeout: 2)
        try h.start()
        h.offer("a.bin", "100000000000000000 0 0 0 2 100000000000000001")
        usleep(200_000)
        h.header(ZHeader(.eof, position: 0))
        usleep(300_000)
        h.offer("b.bin", "1 0 0 0 1 1")
        usleep(200_000)
        h.header(ZHeader(.data, position: 0))
        h.data([0x41], end: Z.crcG)
        usleep(500_000)
        h.receiver.cancel()
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
    }

    @Test func offerNumbersAreClamped() {
        let info = ZmodemReceiver.FileInfo(Array("x".utf8) + [0] + Array("99999999999999999999 77777777777777777777 644 0 -3 -1".utf8) + [0])
        #expect(info.size == nil)  // doesn't parse as an Int at all
        #expect(info.modified == nil)
        #expect(info.filesLeft == nil && info.bytesLeft == nil)
        let big = ZmodemReceiver.FileInfo(Array("x".utf8) + [0] + Array("9223372036854775807 1 644 0 9223372036854775807 9223372036854775807".utf8) + [0])
        #expect(big.size == ZmodemReceiver.FileInfo.maxSize)
        #expect(big.filesLeft == ZmodemReceiver.FileInfo.maxFiles)
        #expect(big.bytesLeft == ZmodemReceiver.FileInfo.maxBatchBytes)
        #expect(ZLink.duration(.infinity) == ZLink.duration(1e30))
    }

    // MARK: Waiting for a file used to go on forever while bytes kept arriving

    /// After a false auto-start, a device streaming ordinary output kept the receiver alive,
    /// swallowing the output and writing ZRINIT into the device.
    @Test func aStreamingDeviceEndsTheHandshake() throws {
        let h = try RxHarness(timeout: 0.3)
        try h.start()
        let line = Data("$PSAMPLE,12.345,67.890,1013.2,22.1\r\n".utf8)
        let until = Date().addingTimeInterval(6)
        while Date() < until && h.results.all.isEmpty {
            h.receiver.feed(line)
            usleep(5_000)
        }
        let finished = !h.results.all.isEmpty
        if !finished { h.receiver.cancel() }
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        #expect(finished, "receiver still running after 6 s of non-ZMODEM input with a 0.3 s timeout")
        #expect(h.count("**\u{18}B01") <= 2)
    }

    /// A device that echoes: our ZRINIT came back as a valid ZRINIT, answered with another, forever.
    @Test func anEchoingDeviceEndsTheHandshake() throws {
        let h = try RxHarness(timeout: 0.3)
        let r = h.receiver
        r.onOutput = { [out = h.out] data in
            out.add(data)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { r.feed(data) }
        }
        try r.start()
        let finished = h.results.wait(timeout: 3) { !$0.isEmpty }
        if !finished { r.cancel() }
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        #expect(finished, "receiver still answering its own echo after 3 s")
        #expect(h.count("**\u{18}B01") <= 5)
    }

    // MARK: Asking for data again used to be suppressed by other traffic

    /// Stale ZEOFs faster than a 50 ms floor stopped ZRPOS altogether.
    @Test func staleZEOFsDontStopResendRequests() throws {
        let h = try RxHarness(timeout: 0.5)
        try h.start()
        h.offer("stale.bin", "1000 0 100644 0 1 1000")
        usleep(100_000)
        let before = h.count("**\u{18}B09")
        for _ in 0..<150 {  // 3 s
            usleep(20_000)
            h.header(ZHeader(.eof, position: 1000))
        }
        let asks = h.count("**\u{18}B09") - before
        h.receiver.cancel()
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        #expect(asks >= 3, "receiver sent ZRPOS \(asks) times")
    }

    /// One noise byte every 0.2 s (under the 0.5 s timeout) kept the per-byte timeout from firing.
    @Test func tricklingNoiseDoesntStopResendRequests() throws {
        let h = try RxHarness(timeout: 0.5)
        try h.start()
        h.offer("t.bin", "1000 0 100644 0 1 1000")
        usleep(100_000)
        let before = h.count("**\u{18}B09")
        for _ in 0..<20 {  // 4 s
            usleep(200_000)
            h.receiver.feed(Data([0x41]))
        }
        let asks = h.count("**\u{18}B09") - before
        h.receiver.cancel()
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        #expect(asks >= 3, "receiver sent ZRPOS \(asks) times")
    }

    /// Headers the file loop ignores (here ZACK) kept restarting the timeout.
    @Test func ignoredHeadersDontStopResendRequests() throws {
        let h = try RxHarness(timeout: 0.5)
        try h.start()
        h.offer("i.bin", "1000 0 100644 0 1 1000")
        usleep(100_000)
        let before = h.count("**\u{18}B09")
        for _ in 0..<20 {
            usleep(200_000)
            h.header(ZHeader(.ack, position: 0))
        }
        let asks = h.count("**\u{18}B09") - before
        h.receiver.cancel()
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        #expect(asks >= 3, "receiver sent ZRPOS \(asks) times")
    }

    /// A ZFILE whose subpacket end was lost used to time out and abort the whole batch.
    @Test func aDamagedOfferIsNAKed() throws {
        let h = try RxHarness(timeout: 0.5)
        try h.start()
        let info = Array("t.bin".utf8) + [0] + Array("5 0 0 0".utf8) + [0]
        let sub = h.e.subpacket(Data(info), end: Z.crcW, crc32: true)
        h.receiver.feed(Data(h.e.binaryHeader(ZHeader(.file, zf0: Z.convBinary), crc32: true) + sub.prefix(sub.count - 7)))
        let done = h.results.wait(timeout: 2) { !$0.isEmpty }
        if !done {
            h.receiver.cancel()
            _ = h.results.wait(timeout: 5) { !$0.isEmpty }
        }
        #expect(!done, "one damaged offer ended the session")
        #expect(h.count("**\u{18}B06") >= 1, "no ZNAK")
    }

    /// The receiver's error budget used to be 50 per file, however much progress was made between
    /// errors: a long file over a noisy line failed.
    @Test func errorBudgetRenewsWithProgress() throws {
        let helper = ZmodemNativeTransferTests()
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [200_000])
        var options = ZmodemOptions()
        options.timeout = 2
        options.traceLevel = .frames
        let traceURL = dst.appendingPathComponent("trace.log")
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: src, options: options)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: options, traceURL: traceURL)
        // Damage the data 2.5 KB after each of the first 60 ZDATA headers: 60 errors, each after
        // some progress.
        var e = ZEncoder()
        let zdata = Array(e.binaryHeader(ZHeader(.data, position: 0), crc32: true).prefix(4))
        let damage = RepeatedPatternMangler(after: zdata, times: 60, distance: 2_500)
        sender.onOutput = { receiver.feed(damage.apply($0)) }
        receiver.onOutput = { sender.feed($0) }
        let results = Inbox<(String, Bool, String)>()
        sender.onFinish = { results.add(("send", $0, $1)) }
        receiver.onFinish = { results.add(("recv", $0, $1)) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 120) { $0.count == 2 })
        #expect(results.all.allSatisfy { $0.1 }, "\(results.all)")
        let got = try Data(contentsOf: dst.appendingPathComponent(files[0].lastPathComponent))
        #expect(got == (try Data(contentsOf: files[0])))
        // More than the old budget of 50 errors per file really happened.
        let trace = try String(contentsOf: traceURL, encoding: .utf8)
        let asked = trace.components(separatedBy: "TX ZRPOS").count - 1
        #expect(asked > 51, "only \(asked) ZRPOS sent")
    }

    // MARK: Files and names

    /// A planted symlink with the offered name is never followed or replaced.
    @Test func aPlantedSymlinkIsNeverFollowed() throws {
        let h = try RxHarness(timeout: 1)
        let outside = h.dst.deletingLastPathComponent().appendingPathComponent("ZOutside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(atPath: h.dst.appendingPathComponent("evil.txt").path,
                                                   withDestinationPath: outside.path)
        try h.start()
        h.offer("evil.txt", "5 0 0 0")
        usleep(200_000)
        h.header(ZHeader(.data, position: 0))
        h.data(Array("HELLO".utf8), end: Z.crcE)
        h.header(ZHeader(.eof, position: 5))
        usleep(300_000)
        h.header(ZHeader(.fin))
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        let link = try FileManager.default.attributesOfItem(atPath: h.dst.appendingPathComponent("evil.txt").path)
        #expect(link[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try Data(contentsOf: h.dst.appendingPathComponent("evil (1).txt")) == Data("HELLO".utf8))
    }

    /// Received files are marked as downloaded, so Gatekeeper checks them before they can run.
    @Test func receivedFilesAreQuarantined() throws {
        let h = try RxHarness(timeout: 1)
        try h.start()
        h.offer("run me.command", "5 0 0 0")
        usleep(200_000)
        h.header(ZHeader(.data, position: 0))
        h.data(Array("echo!".utf8), end: Z.crcE)
        h.header(ZHeader(.eof, position: 5))
        usleep(300_000)
        h.header(ZHeader(.fin))
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        let values = try h.dst.appendingPathComponent("run me.command").resourceValues(forKeys: [.quarantinePropertiesKey])
        #expect(values.quarantineProperties?["LSQuarantineAgentName"] as? String == "SerialTerm")
    }

    @Test func namesAreMadeSafe() {
        func name(_ remote: String) -> String {
            let (stem, ext) = ZmodemReceiver.safeName(remote)
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        #expect(name("..") == "received" && name("a/..") == "received" && name("/") == "received")
        #expect(name("../../etc/passwd") == "passwd" && name("C:\\x\\y.txt") == "y.txt")
        #expect(name(".profile") == "profile" && name("...") == "received")
        #expect(name("\u{202E}fdp.exe") == "fdp.exe", "bidirectional override")
        #expect(name("\u{85}nel") == "nel" && name("a\u{200B}") == "a" && name("a\u{0}b") == "ab")
        #expect(name("foo.") == "foo")
        let long = name(String(repeating: "é", count: 200) + ".txt")
        #expect(long.hasSuffix(".txt") && long.utf8.count + " (9999)".utf8.count <= 255)
    }

    /// A name too long for the file system used to make the file be skipped.
    @Test func longNamesAreShortened() throws {
        let h = try RxHarness(timeout: 1)
        try h.start()
        h.offer(String(repeating: "a", count: 300) + ".txt", "5 0 0 0")
        usleep(200_000)
        h.header(ZHeader(.data, position: 0))
        h.data(Array("HELLO".utf8), end: Z.crcE)
        h.header(ZHeader(.eof, position: 5))
        usleep(300_000)
        h.header(ZHeader(.fin))
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        #expect(h.results.all.first?.0 == true, "\(h.results.all)")
        let names = try FileManager.default.contentsOfDirectory(atPath: h.dst.path)
        #expect(names.count == 1 && names[0].hasSuffix(".txt") && names[0].utf8.count <= 255)
    }

    /// The remote's file name went raw into the session log, where a newline forged a log line.
    @Test func remoteNamesCantForgeLogLines() throws {
        let h = try RxHarness(timeout: 1)
        try h.start()
        h.offer("x.bin\n2026-10-21 12:00:00.000 RX $FORGED,1,2,3\\r\u{1B}[2J", "5 0 0 0")
        usleep(300_000)
        h.header(ZHeader(.fin))
        #expect(h.results.wait(timeout: 5) { $0.count == 1 })
        #expect(!h.logs.all.isEmpty)
        #expect(h.logs.all.allSatisfy { !$0.contains("\n") && !$0.contains("\u{1B}") }, "\(h.logs.all)")
    }
}

@Suite(.serialized)
struct ZmodemSessionLeftoverTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SerialTermTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Output that only looked like a ZMODEM start (a header inside a file being listed) used to
    /// disappear: neither shown nor logged, while ZRINITs went into the device and typing was lost.
    @Test func aFalseStartShowsTheDevicesOutput() throws {
        let pty = try PtyPair()
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: try tempDir())
        var o = ZmodemOptions()
        o.timeout = 0.5
        o.traceLevel = .off
        session.zmodemOptions = o
        let shown = Inbox<Data>()
        session.onDisplay = { shown.add($0) }
        try session.open()
        defer { session.close() }
        pty.writeToPort(Data("$ cat capture.txt\r\nline with **\u{18}B00 in it\r\n".utf8))
        usleep(200_000)
        for i in 0..<100 {  // 5 s of a streaming instrument
            pty.writeToPort(Data("$PSAMPLE,\(i),12.345,67.890,1013.25,22.125,35.001\r\n".utf8))
            usleep(50_000)
        }
        // It gave up by itself (within about a second here; allow for slow machines).
        let deadline = Date().addingTimeInterval(5)
        while session.isTransferring && Date() < deadline { usleep(50_000) }
        #expect(!session.isTransferring)
        let toDevice = pty.readFromPort(timeout: 0.5)
        #expect(occurrences(of: Data("**\u{18}B01".utf8), in: toDevice) <= 2, "ZRINITs written into the device")
        let text = String(decoding: shown.all.reduce(Data(), +), as: UTF8.self)
        #expect(text.components(separatedBy: "PSAMPLE").count - 1 == 100, "\(text)")
        // And typing reaches the device again.
        session.sendFromUser(Data("stop\r".utf8))
        #expect(String(decoding: pty.readFromPort(timeout: 1), as: UTF8.self) == "stop\r")
    }

    /// The remote's prompt right after a transfer (in the same read as ZFIN, with or without "OO")
    /// used to be swallowed.
    @Test(arguments: [true, false])
    func thePromptAfterATransferIsShown(sendOO: Bool) throws {
        let pty = try PtyPair()
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: try tempDir())
        var o = ZmodemOptions()
        o.timeout = 2
        o.traceLevel = .off
        session.zmodemOptions = o
        let shown = Inbox<Data>(), events = Inbox<SessionEvent>()
        session.onDisplay = { shown.add($0) }
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }
        var e = ZEncoder()
        pty.writeToPort(Data("before$ sz x\r\n".utf8) + Data(e.hexHeader(ZHeader(.rqinit))))
        _ = pty.readFromPort(timeout: 1)  // ZRINIT
        pty.writeToPort(Data(e.hexHeader(ZHeader(.fin))) + Data(((sendOO ? "OO" : "") + "GliderDos N -1 >").utf8))
        #expect(events.wait(timeout: 10) { $0.contains { if case .transferFinished = $0 { true } else { false } } })
        usleep(300_000)
        let text = String(decoding: shown.all.reduce(Data(), +), as: UTF8.self)
        #expect(text.hasSuffix("GliderDos N -1 >"), "\(text.debugDescription)")
        #expect(!text.contains("OOGlider"))
    }

    /// A ZRQINIT split across reads used to start the receive without the read that completed
    /// it: its bytes were dropped, and the trace never showed the opening frame.
    @Test func aSplitOpeningFrameReachesTheReceiver() throws {
        let pty = try PtyPair()
        let dir = try tempDir()
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: dir)
        var o = ZmodemOptions()
        o.timeout = 1
        session.zmodemOptions = o
        session.traceDirectory = dir
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }
        var e = ZEncoder()
        let rqinit = Data(e.hexHeader(ZHeader(.rqinit)))
        pty.writeToPort(Data("sz x\r\n".utf8) + rqinit.prefix(3))
        usleep(200_000)
        pty.writeToPort(rqinit.dropFirst(3))
        #expect(events.wait(timeout: 2) { $0.contains { if case .transferStarted = $0 { true } else { false } } })
        _ = pty.readFromPort(timeout: 0.5)  // ZRINIT
        session.cancelTransfer()
        #expect(events.wait(timeout: 5) { $0.contains { if case .transferFinished = $0 { true } else { false } } })
        let traceURL = try #require(session.lastTraceURL)
        var trace = ""
        let deadline = Date().addingTimeInterval(2)
        repeat {
            usleep(50_000)
            trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
        } while !trace.contains("FAILED") && Date() < deadline
        #expect(trace.contains("opening bytes that triggered auto-start"), "\(trace)")
        #expect(trace.contains("RX ZRQINIT"), "\(trace)")
    }
}
