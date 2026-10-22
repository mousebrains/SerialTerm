// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
import Testing
@testable import SerialCore

/// A serial line with a byte rate, an output queue the sender can wait on and discard, like
/// SerialPort's write queue (pending = queued, not yet transmitted).
final class SlowLine: @unchecked Sendable {
    private let cond = NSCondition()
    private var queue: [UInt8] = []
    private var stopped = false
    private(set) var paused = false
    private var _delivered = 0
    private var _discarded = 0
    let bytesPerSecond: Double
    let deliver: (Data) -> Void

    init(bytesPerSecond: Double, deliver: @escaping (Data) -> Void) {
        self.bytesPerSecond = bytesPerSecond
        self.deliver = deliver
        let t = Thread { [self] in pump() }
        t.start()
    }

    var delivered: Int { cond.withLock { _delivered } }
    var pending: Int { cond.withLock { queue.count } }
    var discards: Int { cond.withLock { _discarded } }

    func write(_ d: Data) {
        cond.withLock { queue += d; cond.broadcast() }
    }

    func waitForPending(_ maxPending: Int) {
        cond.lock()
        while queue.count > maxPending && !stopped { _ = cond.wait(until: Date().addingTimeInterval(0.05)) }
        cond.unlock()
    }

    func discard() { cond.withLock { queue.removeAll(); _discarded += 1 } }
    func pause(_ p: Bool) { cond.withLock { paused = p; cond.broadcast() } }
    func stop() { cond.withLock { stopped = true; cond.broadcast() } }

    private func pump() {
        while true {
            cond.lock()
            while (queue.isEmpty || paused) && !stopped { cond.wait() }
            if stopped { cond.unlock(); return }
            let chunk = Array(queue.prefix(256))
            cond.unlock()
            usleep(UInt32(Double(chunk.count) / bytesPerSecond * 1_000_000))
            cond.lock()
            // A discard while "on the wire" doesn't recall it, like a byte already in the UART.
            let n = min(chunk.count, queue.count)
            if queue.starts(with: chunk) { queue.removeFirst(n) }
            _delivered += chunk.count
            cond.broadcast()
            cond.unlock()
            deliver(Data(chunk))
        }
    }
}

/// A minimal scripted ZMODEM receiver.
final class FakeReceiver: @unchecked Sendable {
    let channel = ByteChannel()
    var send: (Data) -> Void = { _ in }
    var buffer = 0
    var caps: UInt8 = Z.canFDX | Z.canOVIO | Z.canFC32
    /// Reply to ZEOF; nil = ZRINIT.
    var eofReply: ZFrameType?
    var eofSilent = false
    /// After the first ZEOF, never answer anything again.
    var deadAfterEOF = false
    private let lock = NSLock()
    private var _eofs = 0
    private var _maxRun = 0
    private var _done = false
    var eofs: Int { lock.withLock { _eofs } }
    var maxRun: Int { lock.withLock { _maxRun } }
    var done: Bool { lock.withLock { _done } }

    func feed(_ d: Data) { channel.append(d) }
    func stop() { channel.cancel() }

    func start() {
        let t = Thread { [self] in run() }
        t.start()
    }

    private func run() {
        defer { lock.withLock { _done = true } }
        var e = ZEncoder()
        let r = ZReader(channel)
        func hex(_ h: ZHeader) { send(Data(e.hexHeader(h))) }
        var pos = 0
        while !channel.isCancelled {
            let h: ZHeader?
            do { h = try r.readHeader(timeout: 5) } catch { if channel.isCancelled { return } else { continue } }
            guard let h else { continue }
            if deadAfterEOF && eofs > 0 { continue }
            switch h.frame {
            case .rqinit:
                hex(ZHeader(type: ZFrameType.rinit.rawValue, p: [UInt8(buffer & 0xFF), UInt8(buffer >> 8 & 0xFF), 0, caps], format: Z.hex))
            case .file:
                _ = try? r.readSubpacket(crc32: h.crc32, timeout: 5)
                pos = 0
                hex(ZHeader(.rpos, position: 0))
            case .data:
                guard h.position == pos else { hex(ZHeader(.rpos, position: pos)); continue }
                var run = 0
                sub: while true {
                    guard let p = try? r.readSubpacket(crc32: h.crc32, timeout: 5) else { break }
                    switch p {
                    case .bad:
                        hex(ZHeader(.rpos, position: pos))
                        break sub
                    case let .data(b, end):
                        pos += b.count
                        run += b.count
                        lock.withLock { _maxRun = max(_maxRun, run) }
                        if end == Z.crcW { hex(ZHeader(.ack, position: pos)); break sub }
                        if end == Z.crcQ { hex(ZHeader(.ack, position: pos)); run = 0 }
                        if end == Z.crcE { break sub }
                    }
                }
            case .eof:
                lock.withLock { _eofs += 1 }
                if eofSilent { continue }
                if let reply = eofReply { hex(ZHeader(reply)) } else { hex(ZHeader(.rinit, zf0: caps)) }
            case .fin:
                hex(ZHeader(.fin))
                return
            default:
                break
            }
        }
    }
}

/// Drops the first ZRINIT the receiver sends after it has accepted a file (its reply to ZEOF).
final class EOFReplyDropper: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = false
    private var dropped = false
    func apply(_ d: Data) -> Data {
        lock.withLock {
            if d.range(of: Data("**\u{18}B09".utf8)) != nil { accepted = true }
            if accepted, !dropped, let r = d.range(of: Data("**\u{18}B01".utf8)) {
                dropped = true
                var out = d
                out.removeSubrange(r.lowerBound..<min(d.endIndex, r.lowerBound + 21))
                return out
            }
            return d
        }
    }
}

/// The native sender against odd, slow, noisy, lossy and hostile receivers. Each test is a defect
/// found in the review in issue #4 that the old sender failed.
@Suite(.serialized)
struct ZmodemSenderRobustnessTests {
    let helper = ZmodemNativeTransferTests()

    /// A cancel during a streamed send used to be noticed only at the next read, at ZEOF.
    @Test func cancelStopsAStreamingSendPromptly() throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [2_000_000])
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst)
        sender.onOutput = { usleep(UInt32($0.count) * 10); receiver.feed($0) }  // ~100 KB/s
        receiver.onOutput = { sender.feed($0) }
        let finished = Inbox<(Date, Bool, String)>()
        sender.onFinish = { finished.add((Date(), $0, $1)) }
        receiver.onFinish = { _, _ in }
        let progress = Inbox<String>()
        sender.onStatus = { progress.add($0) }
        try receiver.start()
        try sender.start()
        #expect(progress.wait(timeout: 10) { $0.count > 5 })
        let cancelledAt = Date()
        sender.cancel()
        #expect(finished.wait(timeout: 60) { !$0.isEmpty })
        let f = try #require(finished.all.first)
        let delay = f.0.timeIntervalSince(cancelledAt)
        #expect(delay < 3, "sender took \(delay) s to honour cancel")
        receiver.cancel()
    }

    /// One stray '*' or CAN on the back channel while streaming used to time out and fail the send.
    @Test(arguments: [UInt8(0x2A), 0x18])
    func aStrayByteOnTheBackChannelIsIgnored(noise: UInt8) throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [400_000])
        var options = ZmodemOptions()
        options.timeout = 1
        var recvOptions = ZmodemOptions()
        recvOptions.timeout = 10  // lrzsz rz's default; the Slocum's is unknown
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: recvOptions)
        let lock = NSLock()
        var sent = 0, injected = false
        sender.onOutput = { d in
            receiver.feed(d)
            let inject: Bool = lock.withLock {
                sent += d.count
                if sent > 100_000 && !injected { injected = true; return true }
                return false
            }
            if inject { sender.feed(Data([noise])) }
        }
        receiver.onOutput = { sender.feed($0) }
        let results = Inbox<(String, Bool, String)>()
        sender.onFinish = { results.add(("send", $0, $1)) }
        receiver.onFinish = { results.add(("recv", $0, $1)) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 30) { $0.count == 2 })
        #expect(results.all.allSatisfy { $0.1 }, "\(results.all)")
    }

    /// A receiver answering every ZEOF with ZNAK (or ZACK) used to get ZEOFs forever.
    @Test(arguments: [ZFrameType.nak, .ack])
    func zeofRetriesAreBounded(reply: ZFrameType) throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [5000])
        var options = ZmodemOptions()
        options.timeout = 1
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let fake = FakeReceiver()
        fake.eofReply = reply
        fake.send = { sender.feed($0) }
        sender.onOutput = { fake.feed($0) }
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        fake.start()
        try sender.start()
        // Give the sender 3 s; a bounded sender gives up after ~11 ZEOFs.
        _ = results.wait(timeout: 3) { !$0.isEmpty }
        let eofs = fake.eofs
        let gaveUp = !results.all.isEmpty
        sender.cancel()
        fake.stop()
        _ = results.wait(timeout: 5) { !$0.isEmpty }
        #expect(eofs <= 11, "sender sent \(eofs) ZEOFs (gave up by itself: \(gaveUp))")
    }

    /// After ZEOF the remote leaves rz and streams instrument data: ZEOFs used to go on forever.
    @Test func zeofRetriesAreBoundedUnderNoise() throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [5000])
        var options = ZmodemOptions()
        options.timeout = 1
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let fake = FakeReceiver()
        fake.eofSilent = true
        fake.send = { sender.feed($0) }
        sender.onOutput = { fake.feed($0) }
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        fake.start()
        try sender.start()
        let deadline = Date().addingTimeInterval(10)
        while fake.eofs == 0 && Date() < deadline { usleep(10_000) }
        // ~100 KB/s of "instrument data" for 6 s.
        let start = Date()
        while Date().timeIntervalSince(start) < 6 && results.all.isEmpty {
            sender.feed(Data((0..<1000).map { _ in UInt8.random(in: 0x30...0x7A) }))
            usleep(10_000)
        }
        let eofs = fake.eofs
        let gaveUp = !results.all.isEmpty
        sender.cancel()
        fake.stop()
        _ = results.wait(timeout: 5) { !$0.isEmpty }
        #expect(gaveUp || eofs <= 11, "sender sent \(eofs) ZEOFs without giving up")
    }

    /// The receiver vanishes after the data (zr timed out, the glider is back at its prompt): it used
    /// to be sent the whole file three more times.
    @Test func aReceiverThatHasGoneGetsLittleResent() throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let size = 100_000
        let files = try helper.makeFiles(in: src, sizes: [size])
        var options = ZmodemOptions()
        options.timeout = 0.3
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let fake = FakeReceiver()
        fake.eofSilent = true
        fake.deadAfterEOF = true
        fake.send = { sender.feed($0) }
        let lock = NSLock()
        var afterEOF = 0
        sender.onOutput = { d in
            if fake.eofs > 0 { lock.withLock { afterEOF += d.count } }
            fake.feed(d)
        }
        let logs = Inbox<String>()
        sender.onLog = { logs.add($0) }
        let results = Inbox<(Date, Bool, String)>()
        sender.onFinish = { results.add((Date(), $0, $1)) }
        fake.start()
        try sender.start()
        var firstEOF: Date?
        let deadline = Date().addingTimeInterval(60)
        while results.all.isEmpty && Date() < deadline {
            if firstEOF == nil && fake.eofs > 0 { firstEOF = Date() }
            usleep(5_000)
        }
        let r = try #require(results.all.first)
        #expect(!r.1, "a receiver that has gone can't have the file")
        let extra = lock.withLock { afterEOF }
        #expect(extra < size, "\(extra) bytes pushed at a receiver that had gone")
        fake.stop()
    }

    /// The receiver advertises a buffer: no more than that may go between ACKs, nor in one subpacket.
    @Test(arguments: [1500, 512])
    func windowRespectsTheReceiversBuffer(buffer: Int) throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [20_000])
        var options = ZmodemOptions()
        options.timeout = 1
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let fake = FakeReceiver()
        fake.buffer = buffer
        fake.send = { sender.feed($0) }
        sender.onOutput = { fake.feed($0) }
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        fake.start()
        try sender.start()
        #expect(results.wait(timeout: 20) { !$0.isEmpty })
        #expect(fake.maxRun <= buffer, "sent \(fake.maxRun) bytes to a receiver with a \(buffer)-byte buffer")
        fake.stop()
    }

    /// The receiver's ZRINIT reply to ZEOF is lost once: the whole file used to be resent.
    @Test func aLostReplyToZEOFResendsLittle() throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let size = 300_000
        let files = try helper.makeFiles(in: src, sizes: [size])
        var options = ZmodemOptions()
        options.timeout = 0.5
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: options)
        let dropper = EOFReplyDropper()
        let lock = NSLock()
        var sent = 0
        sender.onOutput = { d in lock.withLock { sent += d.count }; receiver.feed(d) }
        receiver.onOutput = { sender.feed(dropper.apply($0)) }
        let logs = Inbox<String>()
        sender.onLog = { logs.add($0) }
        let results = Inbox<(String, Bool, String)>()
        sender.onFinish = { results.add(("send", $0, $1)) }
        receiver.onFinish = { results.add(("recv", $0, $1)) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 60) { $0.count == 2 })
        let total = lock.withLock { sent }
        #expect(total < size + 64_000, "sent \(total) bytes for a \(size)-byte file")
    }

    /// Windowed send over a slow line: the ZACK timeout used to start while the window was still queued.
    @Test func zackWaitStartsOnceTheWindowHasGone() throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [64_000])
        var sendOptions = ZmodemOptions(), recvOptions = ZmodemOptions()
        sendOptions.timeout = 1
        sendOptions.window = 16_384
        recvOptions.timeout = 30
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: sendOptions)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: recvOptions)
        let line = SlowLine(bytesPerSecond: 12_000) { receiver.feed($0) }  // 16 KB takes ~1.4 s
        defer { line.stop() }
        sender.onOutput = { line.write($0) }
        sender.waitForOutput = { line.waitForPending($0) }
        sender.discardOutput = { line.discard() }
        receiver.onOutput = { sender.feed($0) }
        let logs = Inbox<String>()
        sender.onLog = { logs.add($0) }
        let results = Inbox<(String, Bool, String)>()
        sender.onFinish = { results.add(("send", $0, $1)) }
        receiver.onFinish = { results.add(("recv", $0, $1)) }
        try receiver.start()
        try sender.start()
        _ = results.wait(timeout: 150) { $0.contains { $0.0 == "send" } }
        let rewinds = logs.all.filter { $0.contains("no ZACK") }
        #expect(results.all.first { $0.0 == "send" }?.1 == true, "\(results.all)")
        #expect(rewinds.isEmpty, "\(rewinds)")
        receiver.cancel()
    }

    /// 16 overrun-and-go-quiet episodes, each further on (like a Slocum at 921600), used to hit the
    /// cap of 30 rewinds per file.
    @Test func aReceiverMakingProgressIsNotCappedAt30() throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [120_000])
        var senderOptions = ZmodemOptions(), receiverOptions = ZmodemOptions()
        senderOptions.timeout = 0.3
        receiverOptions.timeout = 60
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: senderOptions)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: receiverOptions)
        var e = ZEncoder()
        let zdata = Array(e.binaryHeader(ZHeader(.data, position: 0), crc32: true).prefix(4))
        let manglers = stride(from: 1, through: 31, by: 2).map { PatternMangler(after: zdata, occurrence: $0, distance: 2_500) }
        let silent = FirstZRPOSDropper()
        sender.onOutput = { d in receiver.feed(manglers.reduce(d) { $1.apply($0) }) }
        receiver.onOutput = { d in sender.feed(silent.apply(d)) }
        let logs = Inbox<String>()
        sender.onLog = { logs.add($0) }
        let results = Inbox<(String, Bool, String)>()
        sender.onFinish = { results.add(("send", $0, $1)) }
        receiver.onFinish = { results.add(("recv", $0, $1)) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 90) { $0.count == 2 })
        let resends = logs.all.filter { $0.hasPrefix("Resending") }
        #expect(results.all.allSatisfy { $0.1 }, "\(results.all); \(resends.count) rewinds")
    }

    /// After the receiver cancels mid-stream, queued file data used to go out to its shell.
    @Test func remoteCancelDiscardsQueuedData() throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [1_000_000])
        var options = ZmodemOptions()
        options.timeout = 1
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let fake = FakeReceiver()
        let line = SlowLine(bytesPerSecond: 100_000) { fake.feed($0) }
        defer { line.stop(); fake.stop() }
        fake.send = { sender.feed($0) }
        sender.onOutput = { line.write($0) }
        sender.waitForOutput = { line.waitForPending($0) }
        sender.discardOutput = { line.discard() }
        let results = Inbox<(Bool, String, Int, Int)>()
        sender.onFinish = { results.add(($0, $1, line.delivered, line.pending)) }
        fake.start()
        try sender.start()
        let deadline = Date().addingTimeInterval(10)
        while line.delivered < 150_000 && Date() < deadline { usleep(10_000) }
        // The remote aborts: 10 CANs then 10 backspaces (lrzsz canit).
        sender.feed(Data(repeating: 0x18, count: 10) + Data(repeating: 0x08, count: 10))
        #expect(results.wait(timeout: 10) { !$0.isEmpty })
        let r = try #require(results.all.first)
        line.waitForPending(0)
        let after = line.delivered - r.2
        #expect(after < 2_000, "\(after) bytes of file data went out after the transfer ended")
    }

    /// Output blocked (CTS low, XOFF): a local cancel used to never complete.
    @Test func cancelCompletesWhileOutputIsBlocked() throws {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        let files = try helper.makeFiles(in: src, sizes: [500_000])
        var options = ZmodemOptions()
        options.timeout = 1
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let fake = FakeReceiver()
        let line = SlowLine(bytesPerSecond: 200_000) { fake.feed($0) }
        defer { line.stop(); fake.stop() }
        fake.send = { sender.feed($0) }
        sender.onOutput = { line.write($0) }
        sender.waitForOutput = { line.waitForPending($0) }
        sender.discardOutput = { line.discard() }
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        fake.start()
        try sender.start()
        let deadline = Date().addingTimeInterval(10)
        while line.delivered < 50_000 && Date() < deadline { usleep(10_000) }
        line.pause(true)
        usleep(500_000)
        sender.cancel()
        let finished = results.wait(timeout: 4) { !$0.isEmpty }
        line.pause(false)
        _ = results.wait(timeout: 20) { !$0.isEmpty }
        #expect(finished, "cancel did not complete while output was blocked")
    }
}
