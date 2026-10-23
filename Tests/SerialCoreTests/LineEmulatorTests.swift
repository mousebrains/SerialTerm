// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Darwin
import Foundation
import Testing
@testable import SerialCore

/// An end of an emulated line opened directly, to test the line itself: writes from a thread of its
/// own, and keeps what it reads with the time it came.
final class LineEnd: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var chunks: [(time: TimeInterval, bytes: [UInt8])] = []
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)
    private var started: TimeInterval?

    init(_ path: String) throws {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 65_536)
            while !lock.withLock({ stopped }) {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 50) > 0 else { continue }
                let n = read(fd, &buf, buf.count)
                if n > 0 { lock.withLock { chunks.append((Uptime.now, Array(buf[0..<n]))) } }
            }
            done.signal()
        }.start()
    }

    deinit {
        lock.withLock { stopped = true }
        done.wait()
        close(fd)
    }

    /// Writes all of `bytes`, as fast as the line takes them, from a thread of its own: GCD's
    /// global queue can take seconds to start a block while many tests start at once.
    func send(_ bytes: [UInt8]) {
        let fd = fd
        Thread { [self] in
            lock.withLock { started = Uptime.now }
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n > 0 { off += n } else {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 100) < 0 { return }
                }
            }
        }.start()
    }

    var received: [UInt8] { lock.withLock { chunks.flatMap(\.bytes) } }
    /// When the last `send` started writing.
    var sendStarted: TimeInterval? { lock.withLock { started } }
    var reads: [(time: TimeInterval, bytes: [UInt8])] { lock.withLock { chunks } }

    /// Waits until `count` bytes have come, or `timeout` passes.
    @discardableResult
    func wait(for count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Uptime.now + timeout
        while Uptime.now < deadline {
            if received.count >= count { return true }
            usleep(5_000)
        }
        return received.count >= count
    }

    /// Waits until nothing has come for `quiet` seconds (counting from now if nothing has yet).
    func waitForQuiet(_ quiet: TimeInterval, timeout: TimeInterval) {
        let begin = Uptime.now
        let deadline = begin + timeout
        while Uptime.now < deadline {
            let last = lock.withLock { chunks.last?.time } ?? begin
            if Uptime.now - max(last, begin) >= quiet { return }
            usleep(10_000)
        }
    }
}

func randomBytes(_ count: Int, seed: UInt64 = 7) -> [UInt8] {
    var rng = SplitMix64(seed: seed)
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
}

@Suite(.serialized)
struct LineEmulatorTests {
    @Test func deliversAtTheLineRate() throws {
        let line = try LineEmulator(both: .init(baud: 230_400))
        let a = try LineEnd(line.a.slavePath), b = try LineEnd(line.b.slavePath)
        let data = randomBytes(11_520)  // 0.5 s at 230400 8N1
        a.send(data)
        #expect(b.wait(for: data.count, timeout: 5))
        let start = a.sendStarted ?? .nan
        let took = (b.reads.last?.time ?? start) - start
        #expect(b.received == data)
        #expect(took >= 0.49 && took < 0.75, "took \(took) s for 0.5 s of line")
    }

    @Test func addsItsLatency() throws {
        let line = try LineEmulator(both: .init(latency: 0.2))
        let a = try LineEnd(line.a.slavePath), b = try LineEnd(line.b.slavePath)
        a.send([0x41])
        #expect(b.wait(for: 1, timeout: 2))
        let start = a.sendStarted ?? .nan
        let took = (b.reads.first?.time ?? start) - start
        #expect(took >= 0.2 && took < 0.35, "took \(took) s")
    }

    /// However late packets are, they arrive whole and in order, as on a modem link.
    @Test func keepsOrderWhateverTheJitter() throws {
        let jitters: [LineEmulator.Jitter] = [.uniform(0.01), .exponential(mean: 0.003), .retries(probability: 0.2, delay: 0.01)]
        for (i, jitter) in jitters.enumerated() {
            let line = try LineEmulator(both: .init(baud: 1_000_000, jitter: jitter, packets: .init(size: 32, idle: 0.002)),
                                        seed: UInt64(i))
            let a = try LineEnd(line.a.slavePath), b = try LineEnd(line.b.slavePath)
            let data = randomBytes(30_000)
            a.send(data)
            #expect(b.wait(for: data.count, timeout: 10))
            #expect(b.received == data, "\(jitter)")
        }
    }

    /// A slow line holds a sending `SerialPort` back, as hardware does; an instant one doesn't.
    @Test func holdsTheWriterOff() throws {
        for baud in [9_600.0, nil] {
            let line = try LineEmulator(both: .init(baud: baud, buffer: 512))
            let port = SerialPort(path: line.a.slavePath, config: SerialConfig())
            try port.open()
            defer { port.close() }
            let b = try LineEnd(line.b.slavePath)
            port.write(Data(repeating: 0x41, count: 20_000))
            let drained = port.waitForPendingWrites(maxPending: 15_000, timeout: 1)
            let delivered = line.log.bytes(.delivered, "A→B")
            if baud != nil {
                // In 1 s, a 9600-baud line sends about 960 bytes, and the writer has the line's
                // buffer and the pty's 1 KB beyond that.
                #expect(!drained, "the writer got ahead of the line")
                #expect(delivered > 600 && delivered < 1_400, "delivered \(delivered) bytes in about 1 s")
            } else {
                #expect(drained)
                #expect(b.wait(for: 20_000, timeout: 5))
            }
        }
    }

    /// Without flow control, a full line loses what doesn't fit.
    @Test func losesWhatDoesntFitWithoutFlowControl() throws {
        let line = try LineEmulator(both: .init(baud: 9_600, buffer: 256, overrun: .drop))
        let a = try LineEnd(line.a.slavePath), b = try LineEnd(line.b.slavePath)
        let data = randomBytes(4_000)
        a.send(data)
        usleep(200_000)
        b.waitForQuiet(0.3, timeout: 5)
        let got = b.received
        #expect(got.count + line.log.bytes(.overrun, "A→B") == data.count)
        #expect(got.count >= 256 && got.count < 600, "\(got.count) bytes got through")
        #expect(Array(got.prefix(256)) == Array(data.prefix(256)))
    }

    /// A packet short of full waits for the idle timer, as an FTDI adapter's partial USB packet does.
    @Test func aPartPacketWaitsForTheIdleTimer() throws {
        let line = try LineEmulator(both: .init(baud: 1_000_000, packets: .init(size: 62, idle: 0.05)))
        let a = try LineEnd(line.a.slavePath), b = try LineEnd(line.b.slavePath)
        a.send(randomBytes(100))
        #expect(b.wait(for: 100, timeout: 2))
        let packets = line.log.events(.delivered, "A→B")
        #expect(packets.map(\.bytes.count) == [62, 38])
        if packets.count == 2 {
            let gap = packets[1].time - packets[0].time
            #expect(gap >= 0.045 && gap < 0.1, "partial packet came \(gap) s after the full one")
        }
    }

    /// Random damage depends only on the seed and the stream, so a failure replays.
    @Test func damageReplaysFromItsSeed() throws {
        func run(seed: UInt64) throws -> (bytes: [UInt8], flips: Int, drops: Int, noise: Int) {
            let line = try LineEmulator(both: .init(bitErrorRate: 1e-4, dropRate: 1e-4, noiseRate: 1e-4), seed: seed)
            let a = try LineEnd(line.a.slavePath), b = try LineEnd(line.b.slavePath)
            a.send(randomBytes(200_000))
            b.waitForQuiet(0.3, timeout: 10)
            return (b.received, line.log.events(.flipped).count, line.log.events(.dropped).count, line.log.events(.noise).count)
        }
        let first = try run(seed: 1), again = try run(seed: 1), other = try run(seed: 2)
        #expect(first.bytes == again.bytes)
        #expect(first.bytes != other.bytes)
        #expect(first.bytes.count == 200_000 - first.drops + first.noise)
        // Expected 160 flips (200,000 bytes × 8 bits × 1e-4) and 20 each of drops and noise; these
        // bounds are about 5 standard deviations.
        #expect((100...230).contains(first.flips), "\(first.flips) flipped bits")
        #expect((3...45).contains(first.drops), "\(first.drops) dropped bytes")
        #expect((3...45).contains(first.noise), "\(first.noise) noise bytes")
    }

    @Test func anOutageLosesWhatsSentDuringIt() throws {
        let line = try LineEmulator(both: .init(outages: [0.3..<0.6]))
        let a = try LineEnd(line.a.slavePath), b = try LineEnd(line.b.slavePath)
        let start = Uptime.now
        a.send(Array("before ".utf8))
        usleep(useconds_t(max(0, start + 0.45 - Uptime.now) * 1e6))
        a.send(Array("during ".utf8))
        usleep(useconds_t(max(0, start + 0.75 - Uptime.now) * 1e6))
        a.send(Array("after".utf8))
        #expect(b.wait(for: 12, timeout: 2))
        b.waitForQuiet(0.1, timeout: 1)
        #expect(String(decoding: b.received, as: UTF8.self) == "before after")
        #expect(line.log.bytes(.lost, "A→B") == 7)
    }

    /// A stall holds up the bytes that complete its pattern, once.
    @Test func aStallHoldsUpItsPatternOnce() throws {
        let line = try LineEmulator(both: .init(baud: 1_000_000, stall: .init(pattern: Array("ab".utf8), duration: 0.3)))
        let a = try LineEnd(line.a.slavePath), b = try LineEnd(line.b.slavePath)
        func took(_ text: String, total: Int) -> TimeInterval {
            a.send(Array(text.utf8))
            #expect(b.wait(for: total, timeout: 2))
            let start = a.sendStarted ?? .nan
            return (b.reads.last?.time ?? start) - start
        }
        let before = took("xa", total: 2)
        let stalled = took("b", total: 3)
        let after = took("ab", total: 5)
        #expect(String(decoding: b.received, as: UTF8.self) == "xabab")
        #expect(before < 0.1 && after < 0.1, "\(before) s and \(after) s without the stall")
        #expect(stalled >= 0.3 && stalled < 0.45, "\(stalled) s with it")
    }
}

/// Transfers across an emulated line: SerialTerm's own ZMODEM at both ends, or lrzsz at one, with
/// the line's time and damage between them.
@Suite(.serialized)
struct TransfersOverEmulatedLineTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeFiles(in dir: URL, sizes: [Int]) throws -> [URL] {
        try sizes.enumerated().map { i, size in
            let url = dir.appendingPathComponent("file\(i).bin")
            try Data(randomBytes(size, seed: UInt64(i + 1))).write(to: url)
            return url
        }
    }

    struct Outcome {
        var send: (ok: Bool, message: String)?
        var receive: (ok: Bool, message: String)?
        var elapsed: TimeInterval
        var senderTrace = ""
        var receiverTrace = ""
    }

    /// Sends `files` with a Session at end A to a Session at end B, which starts receiving by
    /// itself, as SerialTerm does when a remote sends. On failure prints both traces and the wire.
    func zmodem(_ files: [URL], over line: LineEmulator, into dst: URL, sender senderOptions: ZmodemOptions = ZmodemOptions(),
                receiver receiverOptions: ZmodemOptions = ZmodemOptions(), timeout: TimeInterval = 60) throws -> Outcome {
        let traces = try tempDir()
        func session(_ path: String, _ dir: URL, _ name: String, _ options: ZmodemOptions) throws -> Session {
            let s = Session(port: SerialPort(path: path, config: SerialConfig()), downloadDirectory: dir)
            let sub = traces.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            s.traceDirectory = sub
            s.zmodemOptions = options
            return s
        }
        let sender = try session(line.a.slavePath, files[0].deletingLastPathComponent(), "sender", senderOptions)
        let receiver = try session(line.b.slavePath, dst, "receiver", receiverOptions)
        let sent = Inbox<(Bool, String)>(), received = Inbox<(Bool, String)>()
        sender.onEvent = { if case let .transferFinished(ok, message) = $0 { sent.add((ok, message)) } }
        receiver.onEvent = { if case let .transferFinished(ok, message) = $0 { received.add((ok, message)) } }
        try sender.open()
        defer { sender.close() }
        try receiver.open()
        defer { receiver.close() }

        let start = Uptime.now
        try sender.startTransfer(.zmodemSend(files))
        _ = sent.wait(timeout: timeout) { !$0.isEmpty }
        _ = received.wait(timeout: 5) { !$0.isEmpty }
        func trace(_ s: Session) -> String { s.lastTraceURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }
        let outcome = Outcome(send: sent.all.first, receive: received.all.first, elapsed: Uptime.now - start,
                              senderTrace: trace(sender), receiverTrace: trace(receiver))
        if outcome.send?.ok != true || outcome.receive?.ok != true {
            // Every transfer each side ran, oldest first (a stray header can start another).
            for name in ["sender", "receiver"] {
                let dir = traces.appendingPathComponent(name, isDirectory: true)
                let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                print("=== \(name): \(urls.count) transfer(s); results \(name == "sender" ? sent.all : received.all) ===")
                for url in urls {
                    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    print("=== \(name) trace \(url.lastPathComponent) ===\n" + text.split(separator: "\n").suffix(120).joined(separator: "\n"))
                }
            }
            print("=== wire (last 200 events) ===\n" + line.log.text.split(separator: "\n").suffix(200).joined(separator: "\n"))
        }
        return outcome
    }

    func expectDelivered(_ files: [URL], to dst: URL, _ outcome: Outcome) throws {
        #expect(outcome.send?.ok == true, "send: \(outcome.send?.message ?? "no result")")
        #expect(outcome.receive?.ok == true, "receive: \(outcome.receive?.message ?? "no result")")
        for f in files {
            let got = try? Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent))
            #expect(got == (try Data(contentsOf: f)), "\(f.lastPathComponent) differs")
        }
    }

    /// A fast cable through a USB adapter that sends 62-byte packets, and holds a partial one for
    /// 1 ms (an FTDI chip with its timer at 1 ms).
    @Test func zmodemOverAFastCable() throws {
        let line = try LineEmulator(both: .init(baud: 2_000_000, latency: 0.001, packets: .init(size: 62, idle: 0.001)))
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [0, 1, 1025, 300_000])
        try expectDelivered(files, to: dst, try zmodem(files, over: line, into: dst))
    }

    @Test func zmodemOverANoisyLine() throws {
        let noisy = LineEmulator.Line(baud: 1_000_000, bitErrorRate: 3e-6, dropRate: 3e-7, noiseRate: 3e-7)
        let line = try LineEmulator(both: noisy, seed: 3)
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [400_000, 150_000])
        try expectDelivered(files, to: dst, try zmodem(files, over: line, into: dst, timeout: 90))
        #expect(line.log.events(.flipped, "A→B").count > 0, "the line did no damage")
    }

    /// A satellite call: slow, with a long delay, and an error-correcting modem's resends showing as
    /// jitter. The numbers are illustrative, not measured.
    @Test func zmodemOverASatelliteCall() throws {
        let call = LineEmulator.Line(baud: 4_800, latency: 0.7, jitter: .retries(probability: 0.1, delay: 0.5),
                                     packets: .init(size: 64, idle: 0.05))
        let line = try LineEmulator(both: call, seed: 4)
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [1_500])
        let outcome = try zmodem(files, over: line, into: dst, timeout: 90)
        try expectDelivered(files, to: dst, outcome)
        print("satellite call: \(outcome.elapsed) s for 1,500 bytes")
    }

    /// A cable through an FTDI adapter with its timer at 1 ms, at a rate near the Slocum's 921600:
    /// the line under the scenarios below, which also run over instant in-memory links.
    static let cable = LineEmulator.Line(baud: 1_000_000, latency: 0.001, packets: .init(size: 62, idle: 0.001))
    static let zrpos = Array("**\u{18}B09".utf8)
    static let zrinit = Array("**\u{18}B01".utf8)
    static let zdata: [UInt8] = {
        var e = ZEncoder()
        return Array(e.binaryHeader(ZHeader(.data, position: 0), crc32: true).prefix(4))
    }()

    static func options(timeout: TimeInterval) -> ZmodemOptions {
        var o = ZmodemOptions()
        o.timeout = timeout
        return o
    }

    /// The receiver's ZRINIT reply to ZEOF is lost once: the whole file used to be resent.
    @Test func aLostReplyToZEOFResendsLittle() throws {
        let src = try tempDir(), dst = try tempDir()
        let size = 300_000
        let files = try makeFiles(in: src, sizes: [size])
        var back = Self.cable
        let lostReply = HeaderDropper(Array("**\u{18}B01".utf8), occurrence: 1, length: 21, after: Self.zrpos)
        back.filter = lostReply
        let line = try LineEmulator(aToB: Self.cable, bToA: back)
        let options = Self.options(timeout: 0.5)
        try expectDelivered(files, to: dst, try zmodem(files, over: line, into: dst, sender: options, receiver: options))
        #expect(lostReply.dropped, "the scenario didn't happen")
        let sent = line.log.bytes(.delivered, "A→B")
        #expect(sent < size + 64_000, "sent \(sent) bytes for a \(size)-byte file")
    }

    /// What a Slocum glider does at 921600 baud: it loses data, asks for a resend, loses data
    /// again, and then goes quiet (here its second ZRPOS is lost). Repeating ZEOF gets nowhere,
    /// since the receiver is waiting for data; resending from the last confirmed position does.
    @Test func recoversWhenTheReceiverGoesQuietAfterAnError() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [50_000])
        var forward = Self.cable, back = Self.cable
        forward.filter = FilterChain(Mangler(flipAt: [5_000]), PatternMangler(after: Self.zdata, occurrence: 2, distance: 3_000))
        // The receiver reports the first error at 4096 and the damage after the rewind at 6144.
        // Lose the second report: by its position, as a slow answer to the offer brings repeats
        // of ZRPOS 0 before it. (Hex header: 21 bytes with XON.)
        var e = ZEncoder()
        back.filter = HeaderDropper(Array(e.hexHeader(ZHeader(.rpos, position: 6_144)).prefix(14)), occurrence: 1, length: 21)
        let line = try LineEmulator(aToB: forward, bToA: back)
        // The receiver never asks again by itself within the test.
        let outcome = try zmodem(files, over: line, into: dst, sender: Self.options(timeout: 0.3), receiver: Self.options(timeout: 60))
        try expectDelivered(files, to: dst, outcome)
        #expect(outcome.senderTrace.contains("resending from the last confirmed position"), "the scenario didn't happen")
    }

    /// The glider at 921600 does that over and over: each burst overruns it and it goes quiet
    /// again, a little further on. Prodding must keep going while it makes progress, and not stop
    /// at the cap of 30 rewinds a file.
    @Test(arguments: [(60_000, 5), (120_000, 16)])
    func keepsProddingAReceiverThatKeepsGoingQuiet(size: Int, episodes: Int) throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [size])
        var forward = Self.cable, back = Self.cable
        // ZDATA headers alternate: data (damaged here), then a prod the receiver answers with its
        // position, then the data from there (damaged again), and so on.
        let manglers: [any LineFilter] = stride(from: 1, through: 2 * episodes - 1, by: 2).map {
            PatternMangler(after: Self.zdata, occurrence: $0, distance: 2_500)
        }
        forward.filter = FilterChain(manglers)
        back.filter = FirstZRPOSDropper()
        let line = try LineEmulator(aToB: forward, bToA: back)
        let outcome = try zmodem(files, over: line, into: dst, sender: Self.options(timeout: 0.3), receiver: Self.options(timeout: 60),
                                 timeout: 90)
        try expectDelivered(files, to: dst, outcome)
        let prods = outcome.senderTrace.components(separatedBy: "resending from the last confirmed position").count - 1
        #expect(prods >= episodes - 1, "only \(prods) prods for \(episodes) episodes")
    }

    /// The answer to the file offer comes late, after the sender has offered the file twice more:
    /// as when creating the file takes the receiver over a second (under load, with security
    /// software vetting new files). The answers to the later offers follow the first. They aren't
    /// error reports, and going back to the start for them resent data, or, with one of them
    /// then ignored as a duplicate and a ZEOF answer late, the whole file. With the first data
    /// damaged too, the receiver's own ZRPOS 0 follows those answers, and is acted on.
    @Test(arguments: [false, true])
    func aLateAnswerToTheOfferIsntAnErrorReport(firstDataDamaged: Bool) throws {
        let src = try tempDir(), dst = try tempDir()
        let size = 200_000
        let files = try makeFiles(in: src, sizes: [size])
        var forward = Self.cable, back = Self.cable
        if firstDataDamaged { forward.filter = PatternMangler(after: Self.zdata, occurrence: 1, distance: 400) }
        back.stall = .init(pattern: Self.zrpos, duration: 1.2)
        let line = try LineEmulator(aToB: forward, bToA: back)
        let outcome = try zmodem(files, over: line, into: dst, sender: Self.options(timeout: 0.5))
        try expectDelivered(files, to: dst, outcome)
        #expect(outcome.senderTrace.contains("offering file0.bin again"), "the scenario didn't happen")
        let resends = outcome.senderTrace.split(separator: "\n").filter { $0.contains("Resending") }
        #expect(resends.count == (firstDataDamaged ? 1 : 0), "\(resends)")
        if firstDataDamaged { #expect(resends.first?.contains("from 0 (receiver reported an error)") == true, "\(resends)") }
        // A rewind costs what's in flight by the time the sender reads the ZRPOS.
        let sent = line.log.bytes(.delivered, "A→B")
        #expect(sent < size + (firstDataDamaged ? 64_000 : 16_000), "sent \(sent) bytes for a \(size)-byte file")
    }

    /// The answer to the first file's ZEOF comes late, so the sender, taking the silence for a
    /// receiver still waiting for data, resends from the last position it confirmed: here the
    /// start, as a 20 KB file has no ZCRCQ. The receiver has the whole file. It has to let that
    /// data go by, and not take it for noise and give up on the batch.
    @Test func aLateAnswerToZEOFDoesntEndTheBatch() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [20_000, 20_000])
        var back = Self.cable
        // The receiver's ZRINITs: the 1st opens the session, the 2nd answers the first ZEOF.
        back.stall = .init(pattern: Self.zrinit, occurrence: 2, duration: 0.8)
        let line = try LineEmulator(aToB: Self.cable, bToA: back)
        let outcome = try zmodem(files, over: line, into: dst, sender: Self.options(timeout: 0.5))
        try expectDelivered(files, to: dst, outcome)
        #expect(outcome.senderTrace.contains("Resending file0.bin from 0 (no reply to ZEOF"), "the scenario didn't happen")
    }

    /// lrz answers each offer it sees with a ZRPOS too, so its late answer is followed by stale ones.
    @Test(.enabled(if: Lrzsz.installed, "lrzsz not installed (brew install lrzsz)"))
    func aLateAnswerFromLrzIsntAnErrorReport() throws {
        var back = Self.cable
        back.stall = .init(pattern: Self.zrpos, duration: 1.2)
        let line = try LineEmulator(aToB: Self.cable, bToA: back)
        let src = try tempDir(), dst = try tempDir()
        let size = 200_000
        let files = try makeFiles(in: src, sizes: [size])
        let session = Session(port: SerialPort(path: line.a.slavePath, config: SerialConfig()), downloadDirectory: src)
        session.traceDirectory = try tempDir()
        session.zmodemOptions = Self.options(timeout: 0.5)
        let events = Inbox<SessionEvent>()
        session.onEvent = { event in
            events.add(event)
            if case .remoteWaitingForFiles = event { try? session.startTransfer(.zmodemSend(files)) }
        }
        try session.open()
        defer { session.close() }
        signal(SIGPIPE, SIG_IGN)
        let remote = try line.run(try #require(Lrzsz.find(["lrz", "rz"])), ["-b"], in: dst)
        defer { if remote.isRunning { remote.terminate() } }

        #expect(events.wait(timeout: 60) { $0.contains { if case .transferFinished = $0 { true } else { false } } })
        for case let .transferFinished(success, message) in events.all { #expect(success, "\(message)") }
        let trace = session.lastTraceURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        #expect(trace.contains("offering file0.bin again"), "the scenario didn't happen")
        #expect(trace.contains("the answer to an earlier offer"), "lrz didn't answer the repeated offers")
        let resends = trace.split(separator: "\n").filter { $0.contains("Resending") }
        #expect(resends.isEmpty, "\(resends)")
        #expect(line.log.bytes(.delivered, "A→B") < size + 16_000)
        let got = try? Data(contentsOf: dst.appendingPathComponent("file0.bin"))
        #expect(got == (try Data(contentsOf: files[0])))
    }

    /// lsb on its own terminal sends a batch to SerialTerm's YMODEM receiver, over lines whose
    /// replies come late or unevenly. (Over the pipe relay this once failed under load: "got block
    /// 0, expected 2", the end of the batch arriving where data was expected; issue #19.)
    @Test(.enabled(if: Lrzsz.installed, "lrzsz not installed (brew install lrzsz)"),
          arguments: ["fast", "slow replies", "jitter"])
    func ymodemFromLsb(over kind: String) throws {
        var l = LineEmulator.Line(baud: 1_000_000)
        switch kind {
        case "slow replies": l.latency = 0.4
        case "jitter": l = .init(baud: 115_200, jitter: .exponential(mean: 0.15), packets: .init(size: 64, idle: 0.01))
        default: break
        }
        let line = try LineEmulator(both: l, seed: 6)
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [8, 5_000, 1_024])
        let session = Session(port: SerialPort(path: line.a.slavePath, config: SerialConfig()), downloadDirectory: dst)
        session.autoZmodem = false
        session.traceDirectory = try tempDir()
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }
        signal(SIGPIPE, SIG_IGN)
        let remote = try line.run(try #require(Lrzsz.find(["lsb", "sb"])), ["-b"] + files.map(\.lastPathComponent), in: src)
        defer { if remote.isRunning { remote.terminate() } }
        try session.startTransfer(.ymodemReceive)

        let finished = events.wait(timeout: 90) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
        #expect(finished, "\(kind)")
        for case let .transferFinished(success, message) in events.all {
            #expect(success, "\(kind): \(message)")
            if !success, let url = session.lastTraceURL, let trace = try? String(contentsOf: url, encoding: .utf8) {
                print("=== YMODEM trace (\(kind)) ===\n" + trace.split(separator: "\n").suffix(120).joined(separator: "\n"))
            }
        }
        for f in files {
            let got = try? Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent))
            #expect(got == (try Data(contentsOf: f)), "\(kind): \(f.lastPathComponent) differs")
        }
    }

    /// lrzsz at end B with the pty as its terminal, as on a device; no relay in between.
    @Test(.enabled(if: Lrzsz.installed, "lrzsz not installed (brew install lrzsz)"),
          arguments: ["remote sends", "remote receives"])
    func lrzszOnItsOwnTerminal(direction: String) throws {
        let noisy = LineEmulator.Line(baud: 1_000_000, bitErrorRate: 2e-6)
        let line = try LineEmulator(both: noisy, seed: 5)
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [300_000, 1234, 0])
        let remoteSends = direction == "remote sends"

        let session = Session(port: SerialPort(path: line.a.slavePath, config: SerialConfig()),
                              downloadDirectory: remoteSends ? dst : src)
        session.traceDirectory = try tempDir()
        let events = Inbox<SessionEvent>()
        session.onEvent = { event in
            events.add(event)
            if case .remoteWaitingForFiles = event { try? session.startTransfer(.zmodemSend(files)) }
        }
        try session.open()
        defer { session.close() }
        signal(SIGPIPE, SIG_IGN)
        let tool = try #require(Lrzsz.find(remoteSends ? ["lsz", "sz"] : ["lrz", "rz"]))
        let remote = try line.run(tool, remoteSends ? ["-b"] + files.map(\.lastPathComponent) : ["-b"], in: remoteSends ? src : dst)
        defer { if remote.isRunning { remote.terminate() } }

        let finished = events.wait(timeout: 60) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
        #expect(finished)
        for case let .transferFinished(success, message) in events.all {
            #expect(success, "\(direction): \(message)")
            if !success, let url = session.lastTraceURL, let trace = try? String(contentsOf: url, encoding: .utf8) {
                print("=== trace (\(direction)) ===\n" + trace.split(separator: "\n").suffix(120).joined(separator: "\n"))
            }
        }
        let deadline = Uptime.now + 10
        while remote.isRunning && Uptime.now < deadline { usleep(20_000) }
        #expect(!remote.isRunning, "lrzsz still running")
        for f in files {
            let got = try? Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent))
            #expect(got == (try Data(contentsOf: f)), "\(f.lastPathComponent) differs")
        }
    }
}
