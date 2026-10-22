// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
import Testing
@testable import SerialCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("XmodemTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func randomData(_ n: Int) -> Data {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
}

private func roundUp(_ n: Int, _ to: Int) -> Int { (n + to - 1) / to * to }

struct XmodemCodecTests {
    @Test func checksumBlock() {
        let b = X.block(1, [0x41, 0x42], size: 128, crc: false, pad: X.eofPad)
        #expect(b.count == 132)
        #expect(Array(b[0..<5]) == [X.soh, 1, 0xFE, 0x41, 0x42])
        #expect(b[5..<131].allSatisfy { $0 == X.eofPad })
        let sum: Int = 0x41 + 0x42 + 126 * 0x1A
        #expect(b[131] == UInt8(sum & 0xFF))
    }

    @Test func crcBlock() {
        let data = Array("123456789".utf8)
        let b = X.block(255, data, size: 1024, crc: true, pad: 0)
        #expect(b.count == 1029)
        #expect(Array(b[0..<3]) == [X.stx, 255, 0])
        let crc = CRC.crc16(b[3..<1027])
        #expect(b[1027] == UInt8(crc >> 8) && b[1028] == UInt8(crc & 0xFF))
        // Without padding, the payload's CRC is the published CRC-16/XMODEM check value.
        #expect(Array(X.block(1, data, size: 9, crc: true, pad: 0).suffix(2)) == [0x31, 0xC3])
    }

    @Test func ymodemHeaderRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let header = X.header(name: "with space.txt", size: 1234, modified: date, filesLeft: 2, bytesLeft: 5000)
        let info = ZmodemReceiver.FileInfo(header)
        #expect(info.name == "with space.txt")
        #expect(info.size == 1234)
        #expect(info.modified == date)
        #expect(info.filesLeft == 2 && info.bytesLeft == 5000)
        #expect(ZmodemReceiver.FileInfo([UInt8](repeating: 0, count: 128)).name.isEmpty)
    }
}

/// A native sender and receiver back to back.
struct XmodemNativeTransferTests {
    struct Outcome {
        var send: (ok: Bool, message: String)
        var receive: (ok: Bool, message: String)
    }

    /// `slowly`: pause this long per write, so a cancel lands mid-transfer.
    func transfer(send: TransferKind, receive: TransferKind, into dst: URL, oneK: Bool = false, crcAttempts: Int = 3,
                  forward: Mangler? = nil, back: Mangler? = nil, slowly: useconds_t = 0, traces: URL? = nil,
                  cancel: ((XmodemTransfer, XmodemTransfer) -> Void)? = nil) throws -> Outcome {
        let sender = XmodemTransfer(kind: send, directory: dst, xmodem1K: oneK, traceLevel: traces == nil ? .off : .frames,
                                    traceURL: traces?.appendingPathComponent("send.log"))
        let receiver = XmodemTransfer(kind: receive, directory: dst, traceLevel: traces == nil ? .off : .frames,
                                      traceURL: traces?.appendingPathComponent("receive.log"))
        sender.timeout = 1
        receiver.timeout = 1
        receiver.crcAttempts = crcAttempts
        sender.onOutput = {
            if slowly > 0 { usleep(slowly) }
            receiver.feed(forward?.apply($0) ?? $0)
        }
        receiver.onOutput = { sender.feed(back?.apply($0) ?? $0) }
        let results = Inbox<(String, Bool, String)>()
        sender.onFinish = { results.add(("send", $0, $1)) }
        receiver.onFinish = { results.add(("receive", $0, $1)) }
        try receiver.start()
        try sender.start()
        if let cancel {
            usleep(300_000)
            cancel(sender, receiver)
        }
        #expect(results.wait(timeout: 60) { $0.count == 2 })
        let s = results.all.first { $0.0 == "send" }.map { ($0.1, $0.2) } ?? (false, "no result")
        let r = results.all.first { $0.0 == "receive" }.map { ($0.1, $0.2) } ?? (false, "no result")
        return Outcome(send: s, receive: r)
    }

    /// XMODEM pads the last block with 0x1A to a multiple of 128, with 1K blocks too.
    @Test(arguments: [false, true])
    func xmodemSizes(oneK: Bool) throws {
        let src = try tempDir(), dst = try tempDir()
        for size in [0, 1, 127, 128, 129, 1023, 1024, 1025, 3000, 70_000] {
            let file = src.appendingPathComponent("f\(size).bin")
            let content = randomData(size)
            try content.write(to: file)
            let out = dst.appendingPathComponent("out\(size).bin")
            let o = try transfer(send: .xmodemSend(file), receive: .xmodemReceive(out), into: dst, oneK: oneK)
            #expect(o.send.ok, "\(size): \(o.send.message)")
            #expect(o.receive.ok, "\(size): \(o.receive.message)")
            let got = try Data(contentsOf: out)
            #expect(got.count == roundUp(size, 128), "\(size) → \(got.count)")
            #expect(got.prefix(size) == content, "\(size)")
            #expect(got.dropFirst(size).allSatisfy { $0 == X.eofPad })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).allSatisfy { !$0.hasSuffix(".part") })
    }

    /// A receiver that asks for the checksum (NAK) gets it, in 1K blocks as lrzsz's receiver accepts.
    @Test(arguments: [false, true])
    func xmodemChecksumMode(oneK: Bool) throws {
        let src = try tempDir(), dst = try tempDir()
        let file = src.appendingPathComponent("f.bin")
        let content = randomData(5000)
        try content.write(to: file)
        let out = dst.appendingPathComponent("out.bin")
        let o = try transfer(send: .xmodemSend(file), receive: .xmodemReceive(out), into: dst, oneK: oneK, crcAttempts: 0)
        #expect(o.send.ok && o.receive.ok, "\(o)")
        #expect(try Data(contentsOf: out).prefix(5000) == content)
    }

    @Test func xmodemReplacesTheChosenFile() throws {
        let src = try tempDir(), dst = try tempDir()
        let file = src.appendingPathComponent("f.bin")
        try randomData(300).write(to: file)
        let out = dst.appendingPathComponent("out.bin")
        try Data("old".utf8).write(to: out)
        let o = try transfer(send: .xmodemSend(file), receive: .xmodemReceive(out), into: dst)
        #expect(o.send.ok && o.receive.ok, "\(o)")
        #expect(try Data(contentsOf: out).prefix(300) == Data(contentsOf: file))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["out.bin"])
    }

    @Test func ymodemBatch() throws {
        let src = try tempDir(), dst = try tempDir()
        let names = ["empty.bin", "one.bin", "b128.bin", "b129.bin", "k1.bin", "k1plus.bin", "with space.txt", "ünïcødé.dat"]
        let sizes = [0, 1, 128, 129, 1024, 1025, 300_001, 4000]
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        var files: [URL] = []
        for (name, size) in zip(names, sizes) {
            let url = src.appendingPathComponent(name)
            try randomData(size).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            files.append(url)
        }
        let o = try transfer(send: .ymodemSend(files), receive: .ymodemReceive, into: dst)
        #expect(o.send.ok, "\(o.send.message)")
        #expect(o.receive.ok, "\(o.receive.message)")
        #expect(o.receive.message.hasPrefix("Received 8 files"), "\(o.receive.message)")
        for f in files {
            let got = dst.appendingPathComponent(f.lastPathComponent)
            #expect(try Data(contentsOf: got) == Data(contentsOf: f), "\(f.lastPathComponent)")
            let date = try got.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            #expect(date == modified, "\(f.lastPathComponent)")
        }
    }

    @Test func ymodemNeverOverwrites() throws {
        let src = try tempDir(), dst = try tempDir()
        let file = src.appendingPathComponent("data.txt")
        try Data("new".utf8).write(to: file)
        try Data("old".utf8).write(to: dst.appendingPathComponent("data.txt"))
        let o = try transfer(send: .ymodemSend([file]), receive: .ymodemReceive, into: dst)
        #expect(o.send.ok && o.receive.ok, "\(o)")
        #expect(try Data(contentsOf: dst.appendingPathComponent("data.txt")) == Data("old".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("data (1).txt")) == Data("new".utf8))
    }

    /// Damaged and lost data, and damaged ACKs: the receiver NAKs, the sender repeats, a block
    /// that arrives twice is written once.
    @Test(arguments: ["xmodem", "ymodem"])
    func recoversFromNoise(protocolName: String) throws {
        let src = try tempDir(), dst = try tempDir()
        let file = src.appendingPathComponent("noisy.bin")
        let content = randomData(60_000)
        try content.write(to: file)
        let forward = Mangler(flipAt: [500, 5_000, 5_100, 40_000], dropAt: [20_000: 37, 50_000: 600])
        let back = Mangler(flipAt: [5, 20, 21])
        let out = dst.appendingPathComponent("noisy.bin")
        let traces = try tempDir()
        let o = protocolName == "xmodem"
            ? try transfer(send: .xmodemSend(file), receive: .xmodemReceive(out), into: dst, oneK: true,
                           forward: forward, back: back, traces: traces)
            : try transfer(send: .ymodemSend([file]), receive: .ymodemReceive, into: dst, forward: forward, back: back,
                           traces: traces)
        if !o.send.ok || !o.receive.ok {
            for name in ["send.log", "receive.log"] {
                print("=== \(protocolName) \(name) ===\n" + ((try? String(contentsOf: traces.appendingPathComponent(name), encoding: .utf8)) ?? "none"))
            }
        }
        #expect(o.send.ok, "\(o.send.message)")
        #expect(o.receive.ok, "\(o.receive.message)")
        #expect(try Data(contentsOf: out).prefix(content.count) == content)
        // Each kind of damage was seen and repaired.
        let sent = try String(contentsOf: traces.appendingPathComponent("send.log"), encoding: .utf8)
        let received = try String(contentsOf: traces.appendingPathComponent("receive.log"), encoding: .utf8)
        #expect(received.contains("bad block: CRC-16 mismatch"), "\(received)")
        #expect(received.contains("bad block: cut short"), "\(received)")
        #expect(received.contains("duplicate block"), "\(received)")
        // The receiver's NAKs drive the resends; the sender's own, much longer timeout never fires.
        #expect(sent.contains("NAK for block") && !sent.contains("no reply to block"), "\(sent)")
        #expect(sent.contains("summary: OK") && received.contains("summary: OK"))
    }

    /// Either end cancelling stops the other, and leaves no partial file.
    @Test(arguments: ["xmodem sender", "xmodem receiver", "ymodem sender", "ymodem receiver"])
    func cancelStopsBothEnds(which: String) throws {
        let src = try tempDir(), dst = try tempDir()
        let file = src.appendingPathComponent("big.bin")
        try randomData(3_000_000).write(to: file)
        let out = dst.appendingPathComponent("big.bin")
        let xmodem = which.hasPrefix("xmodem")
        if xmodem { try Data("old".utf8).write(to: out) }
        let bySender = which.hasSuffix("sender")
        let o = try transfer(send: xmodem ? .xmodemSend(file) : .ymodemSend([file]),
                             receive: xmodem ? .xmodemReceive(out) : .ymodemReceive,
                             into: dst, oneK: true, slowly: 500) { sender, receiver in
            (bySender ? sender : receiver).cancel()
        }
        #expect(!o.send.ok && !o.receive.ok, "\(o)")
        #expect((bySender ? o.send : o.receive).message == "Cancelled", "\(o)")
        #expect((bySender ? o.receive : o.send).message == "Cancelled by the remote", "\(o)")
        if xmodem {
            #expect(try Data(contentsOf: out) == Data("old".utf8), "the chosen file is left alone")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path) == ["big.bin"])
        } else {
            #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).isEmpty, "no partial file")
        }
    }

    @Test func ymodemReceiverRefusesAnXmodemSender() throws {
        let src = try tempDir(), dst = try tempDir()
        let file = src.appendingPathComponent("f.bin")
        try randomData(1000).write(to: file)
        let o = try transfer(send: .xmodemSend(file), receive: .ymodemReceive, into: dst)
        #expect(!o.receive.ok && o.receive.message.contains("isn't using YMODEM"), "\(o.receive.message)")
        #expect(!o.send.ok, "\(o.send.message)")
    }
}

/// One end of a transfer against a scripted remote.
final class XmodemProbe: @unchecked Sendable {
    let transfer: XmodemTransfer
    let sent = Inbox<Data>()
    let finished = Inbox<(Bool, String)>()
    let leftover = Inbox<Data>()

    init(_ kind: TransferKind, directory: URL, timeout: TimeInterval = 1, receiveCommand: String? = nil) {
        transfer = XmodemTransfer(kind: kind, directory: directory, receiveCommand: receiveCommand)
        transfer.timeout = timeout
        transfer.onOutput = { [sent] in sent.add($0) }
        transfer.onFinish = { [finished] in finished.add(($0, $1)) }
        transfer.onLeftover = { [leftover] in leftover.add($0) }
    }

    var output: Data { sent.all.reduce(Data(), +) }

    /// Waits for the output (since `from`) to satisfy `done`.
    @discardableResult
    func waitForOutput(from: Int = 0, timeout: TimeInterval = 3, _ done: (Data) -> Bool) -> Bool {
        sent.wait(timeout: timeout) { done($0.reduce(Data(), +).dropFirst(from)) }
    }

    func feed(_ bytes: [UInt8]) { transfer.feed(Data(bytes)) }
    func feed(_ text: String) { transfer.feed(Data(text.utf8)) }

    func result(timeout: TimeInterval = 10) -> (ok: Bool, message: String)? {
        _ = finished.wait(timeout: timeout) { !$0.isEmpty }
        return finished.all.first.map { (ok: $0.0, message: $0.1) }
    }
}

struct XmodemScriptedTests {
    /// The remote echoes the typed `rx 'Config.bin'`, and its receiver prints a banner, before
    /// it asks with a 'C'. A 'C' with more text right after isn't the receiver asking.
    @Test func echoedCIsNotARequest() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("Config.bin")
        try randomData(100).write(to: file)
        let probe = XmodemProbe(.xmodemSend(file), directory: dir, receiveCommand: "rx 'Config.bin'\r")
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0 == Data("rx 'Config.bin'\r".utf8) })
        let typed = probe.output.count
        usleep(50_000)
        probe.feed("rx 'C")
        usleep(50_000)  // within the quiet time that makes a 'C' a request
        probe.feed("onfig.bin'\r\nrx: ready to receive Config.bin\r\n")
        usleep(1_000_000)
        #expect(probe.output.count == typed, "nothing sent before the receiver asked")
        probe.feed([X.crcRequest])
        #expect(probe.waitForOutput(from: typed) { $0.first == X.soh })
        probe.transfer.cancel()
        #expect(probe.result()?.message == "Cancelled")
    }

    /// A shell that has no `rx`: the sender gives up, and what the shell said is shown.
    @Test func noReceiverShowsWhatTheRemoteSaid() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try randomData(100).write(to: file)
        let probe = XmodemProbe(.xmodemSend(file), directory: dir, timeout: 0.3, receiveCommand: "rx 'f.bin'\r")
        try probe.transfer.start()
        #expect(probe.waitForOutput { !$0.isEmpty })
        probe.feed("rx 'f.bin'\r\n-sh: rx: not found\r\n$ ")
        let r = try #require(probe.result())
        #expect(!r.ok && r.message.contains("No XMODEM receiver"), "\(r.message)")
        let shown = String(decoding: probe.leftover.all.reduce(Data(), +), as: UTF8.self)
        #expect(shown.contains("rx: not found"), "\(shown)")
    }

    /// Blocks sent so far: each goes out in one write.
    private func blocks(_ probe: XmodemProbe) -> Int {
        probe.sent.all.filter { $0.count >= 131 && ($0.first == X.soh || $0.first == X.stx) }.count
    }

    /// EOTs sent so far: each goes out alone (a 0x04 in a block's data doesn't count).
    private func eots(_ probe: XmodemProbe) -> Int {
        probe.sent.all.filter { $0 == Data([X.eot]) }.count
    }

    /// Mid-transfer a 'C' is noise (or a late repeat): it mustn't send the block again, which
    /// would put two copies, and two ACKs, in flight.
    @Test func strayCDoesNotRepeatABlock() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try randomData(300).write(to: file)
        let probe = XmodemProbe(.xmodemSend(file), directory: dir)
        try probe.transfer.start()
        probe.feed([X.crcRequest])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 1 })
        probe.feed([X.ack])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 2 })
        probe.feed([X.crcRequest])
        usleep(500_000)
        #expect(blocks(probe) == 2, "block 2 sent again on a stray 'C'")
        probe.feed([X.ack])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 3 })
        probe.transfer.cancel()
        _ = probe.result()
    }

    /// A YMODEM receiver whose ACK of EOT was lost asks for the next file with 'C': the sender
    /// takes that as the ACK and answers it at once, rather than waiting a minute.
    @Test func ymodemCAfterEOTMovesOn() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try randomData(100).write(to: file)
        let probe = XmodemProbe(.ymodemSend([file]), directory: dir)
        try probe.transfer.start()
        probe.feed([X.crcRequest])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 1 })  // block 0
        probe.feed([X.ack, X.crcRequest])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 2 })  // block 1
        probe.feed([X.ack])
        #expect(probe.waitForOutput { _ in self.eots(probe) == 1 })
        let n = probe.output.count
        probe.feed([X.crcRequest])
        #expect(probe.waitForOutput(from: n, timeout: 1) { $0.prefix(3) == Data([X.soh, 0, 0xFF]) }, "the end of the batch")
        probe.feed([X.ack])
        let r = try #require(probe.result())
        #expect(r.ok, "\(r.message)")
    }

    /// On a long round trip the receiver's repeated 'C' crosses the first block on its way. A
    /// second copy sent for it would have been ACKed too, and that ACK taken for the next block's.
    @Test func crossingCDoesNotDuplicateTheFirstBlock() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try randomData(300).write(to: file)
        let probe = XmodemProbe(.xmodemSend(file), directory: dir)
        try probe.transfer.start()
        probe.feed([X.crcRequest])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 1 })
        probe.feed([X.crcRequest])  // sent before the block arrived
        usleep(500_000)
        #expect(blocks(probe) == 1, "block 1 sent twice")
        probe.feed([X.ack])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 2 })
        probe.transfer.cancel()
        _ = probe.result()
    }

    /// An answer after the last block's ACK means the ACKs ran a block behind: a NAK is the last
    /// block's real answer, so it goes again before EOT, rather than the file ending short.
    @Test func lateNAKAfterTheLastBlockSendsItAgain() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try randomData(200).write(to: file)
        let probe = XmodemProbe(.xmodemSend(file), directory: dir)
        try probe.transfer.start()
        probe.feed([X.crcRequest])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 1 })
        probe.feed([X.ack])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 2 })
        probe.feed([X.ack, X.nak])  // the NAK: block 2 was damaged
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 3 }, "the last block sent again")
        #expect(eots(probe) == 0)
        probe.feed([X.ack])
        #expect(probe.waitForOutput { _ in self.eots(probe) == 1 })
        probe.transfer.cancel()
        _ = probe.result()
    }

    /// The receiver ACKed EOT and exited, but the ACK was lost and the shell's prompt came instead.
    /// Another EOT would be a ^D at that prompt, which logs out of many shells.
    @Test func shellAfterEOTEndsTheSend() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try randomData(100).write(to: file)
        let probe = XmodemProbe(.xmodemSend(file), directory: dir)
        try probe.transfer.start()
        probe.feed([X.crcRequest])
        #expect(probe.waitForOutput { _ in self.blocks(probe) == 1 })
        probe.feed([X.ack])
        #expect(probe.waitForOutput { _ in self.eots(probe) == 1 })
        let n = probe.output.count
        probe.feed("\r\n$ ")
        let r = try #require(probe.result())
        #expect(r.ok, "\(r.message)")
        #expect(probe.output.count == n, "nothing more sent to the shell")
    }

    /// A receiver quick enough to ask while the command's echo was still being taken in.
    @Test func quickRequestDuringTheEchoIsKept() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try randomData(100).write(to: file)
        let t = XmodemTransfer(kind: .xmodemSend(file), directory: dir, receiveCommand: "rx 'f.bin'\r")
        t.timeout = 1
        let sent = Inbox<Data>(), finished = Inbox<Bool>()
        t.onOutput = { data in
            sent.add(data)
            // The echo and the receiver's 'C', before the sender looks.
            if data == Data("rx 'f.bin'\r".utf8) { t.feed(Data("rx 'f.bin'\r\n".utf8) + Data([X.crcRequest])) }
        }
        t.onFinish = { ok, _ in finished.add(ok) }
        try t.start()
        #expect(sent.wait(timeout: 2) { $0.contains { $0.first == X.soh } }, "waited for another 'C'")
        t.cancel()
        _ = finished.wait(timeout: 5) { !$0.isEmpty }
    }

    @Test func remoteCancelStopsTheSender() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try randomData(5000).write(to: file)
        let probe = XmodemProbe(.xmodemSend(file), directory: dir)
        try probe.transfer.start()
        probe.feed([X.crcRequest])
        #expect(probe.waitForOutput { $0.first == X.soh })
        probe.feed([X.can, X.can])
        let r = try #require(probe.result())
        #expect(!r.ok && r.message == "Cancelled by the remote", "\(r.message)")
        #expect(probe.output.range(of: Data(X.abortSequence)) == nil, "no abort back to a remote that gave up")
    }

    /// The first EOT is NAKed in case it was noise: a block after it carries on, and a real
    /// EOT comes again.
    @Test func firstEOTIsNAKed() throws {
        let dir = try tempDir()
        let out = dir.appendingPathComponent("out.bin")
        let probe = XmodemProbe(.xmodemReceive(out), directory: dir)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        var n = probe.output.count
        probe.feed(X.block(1, Array("first".utf8), size: 128, crc: true, pad: X.eofPad))
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.ack]) })
        n = probe.output.count
        probe.feed([X.eot])  // noise
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.nak]) })
        n = probe.output.count
        probe.feed(X.block(2, Array("second".utf8), size: 128, crc: true, pad: X.eofPad))
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.ack]) })
        n = probe.output.count
        probe.feed([X.eot])
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.nak]) })
        n = probe.output.count
        probe.feed([X.eot])
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.ack]) })
        #expect(probe.result()?.ok == true)
        let got = try Data(contentsOf: out)
        #expect(got.count == 256)
        #expect(got.prefix(5) == Data("first".utf8) && got[128..<134] == Data("second".utf8))
    }

    /// An EOT is one unchecked byte: one alone is never taken as the end. The receiver keeps
    /// asking for it again, so noise can't end a file early; a real sender repeats it.
    @Test func singleEOTIsNotTakenAsTheEnd() throws {
        let dir = try tempDir()
        let out = dir.appendingPathComponent("out.bin")
        try Data("old".utf8).write(to: out)
        let probe = XmodemProbe(.xmodemReceive(out), directory: dir)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        probe.feed(X.block(1, Array("only".utf8), size: 128, crc: true, pad: X.eofPad))
        #expect(probe.waitForOutput { $0.contains(X.ack) })
        let n = probe.output.count
        probe.feed([X.eot])
        #expect(probe.waitForOutput(from: n, timeout: 5) { $0.filter { $0 == X.nak }.count >= 2 }, "asks for EOT again")
        #expect(probe.finished.all.isEmpty, "a lone EOT ended the file")
        #expect(try Data(contentsOf: out) == Data("old".utf8))
        probe.feed([X.eot])
        let r = try #require(probe.result())
        #expect(r.ok, "\(r.message)")
        #expect(try Data(contentsOf: out).prefix(4) == Data("only".utf8))
    }

    /// Data from the sender with no 0x01, 0x02, 0x04 or CAN in it, to place those by hand.
    private func plain(_ n: Int) -> [UInt8] {
        let special: Set<UInt8> = [0x01, 0x02, 0x04, 0x18]
        return (0..<n).map { i -> UInt8 in
            let b = UInt8(truncatingIfNeeded: i)
            return special.contains(b) ? 0x55 : b
        }
    }

    /// A block whose start byte was lost (a dropped USB packet) is read from its number on. A
    /// 0x04 in it, the number of block 4 among them, used to count as EOT: the file ended early
    /// and was reported complete.
    @Test func eotInsideABlockIsNotTheEnd() throws {
        let dir = try tempDir()
        let out = dir.appendingPathComponent("out.bin")
        let probe = XmodemProbe(.xmodemReceive(out), directory: dir)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        var data: [[UInt8]] = []
        for n in 1...3 {
            data.append(plain(128))
            let before = probe.output.count
            probe.feed(X.block(UInt8(n), data.last!, size: 128, crc: true, pad: X.eofPad))
            #expect(probe.waitForOutput(from: before) { $0 == Data([X.ack]) })
        }
        var four = plain(128)
        four[10] = X.eot
        four[90] = X.eot
        data.append(four)
        let block = X.block(4, four, size: 128, crc: true, pad: X.eofPad)
        var n = probe.output.count
        probe.feed(Array(block.dropFirst()))  // its SOH lost: 0x04 (the number) comes first
        #expect(probe.waitForOutput(from: n, timeout: 4) { $0.contains(X.nak) })
        #expect(!probe.output.dropFirst(n).contains(X.ack), "nothing in it was taken for EOT")
        n = probe.output.count
        probe.feed(block)
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.ack]) })
        probe.feed([X.eot])
        #expect(probe.waitForOutput(from: n) { $0.last == X.nak })
        probe.feed([X.eot])
        let r = try #require(probe.result())
        #expect(r.ok, "\(r.message)")
        #expect(try Data(contentsOf: out) == Data(data.joined()))
    }

    /// A 0x04 of noise just before a block isn't an EOT, and isn't answered: an answer to it as
    /// well as the block's would have put a second copy of the block in flight.
    @Test func noiseBeforeABlockGetsOneAnswer() throws {
        let dir = try tempDir()
        let probe = XmodemProbe(.xmodemReceive(dir.appendingPathComponent("out.bin")), directory: dir)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        probe.feed(X.block(1, plain(128), size: 128, crc: true, pad: X.eofPad))
        #expect(probe.waitForOutput { $0.contains(X.ack) })
        let n = probe.output.count
        probe.feed([X.eot] + X.block(2, plain(128), size: 128, crc: true, pad: X.eofPad))
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.ack]) })
        usleep(300_000)
        #expect(probe.output.dropFirst(n) == Data([X.ack]), "\(ZmodemTrace.hex(Array(probe.output.dropFirst(n))))")
        probe.transfer.cancel()
    }

    /// On a slow line a 1K block takes seconds to go by (8.6 s at 1200 baud). One whose start
    /// byte was damaged into SOH is found bad after 132 bytes; the NAK waits until the rest has
    /// gone by too, so that isn't read for block starts and answered again.
    @Test func aSlowDamagedBlockGetsOneNAK() throws {
        let dir = try tempDir()
        let probe = XmodemProbe(.xmodemReceive(dir.appendingPathComponent("out.bin")), directory: dir, timeout: 3)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        probe.feed(X.block(1, plain(1024), size: 1024, crc: true, pad: X.eofPad))
        #expect(probe.waitForOutput { $0.contains(X.ack) })
        let n = probe.output.count
        var damaged = X.block(2, plain(1024), size: 1024, crc: true, pad: X.eofPad)
        damaged[0] = X.soh
        for chunk in stride(from: 0, to: damaged.count, by: 32) {
            probe.feed(Array(damaged[chunk..<min(chunk + 32, damaged.count)]))
            usleep(150_000)  // ~4.8 s for the block; it is found bad after ~0.6 s
        }
        #expect(probe.output.count == n, "a NAK went out while the block was still arriving")
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.nak]) })
        usleep(500_000)
        #expect(probe.output.dropFirst(n) == Data([X.nak]))
        probe.transfer.cancel()
    }

    /// The sender started on our NAK (its first answer) or on a 'C': the first block's length
    /// says which check it uses.
    @Test(arguments: [(3, false), (0, true)])
    func firstBlockSettlesTheCheck(crcAttempts: Int, crc: Bool) throws {
        let dir = try tempDir()
        let out = dir.appendingPathComponent("out.bin")
        let probe = XmodemProbe(.xmodemReceive(out), directory: dir)
        probe.transfer.crcAttempts = crcAttempts
        try probe.transfer.start()
        #expect(probe.waitForOutput { !$0.isEmpty })
        // The receiver asked for the other one.
        probe.feed(X.block(1, Array("first".utf8), size: 128, crc: crc, pad: X.eofPad))
        #expect(probe.waitForOutput { $0.contains(X.ack) })
        let n = probe.output.count
        probe.feed(X.block(2, Array("second".utf8), size: 128, crc: crc, pad: X.eofPad))
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.ack]) })
        probe.feed([X.eot])
        #expect(probe.waitForOutput(from: n) { $0.last == X.nak })
        probe.feed([X.eot])
        let r = try #require(probe.result())
        #expect(r.ok, "\(r.message)")
        #expect(try Data(contentsOf: out)[128..<134] == Data("second".utf8))
    }

    /// Damaged first blocks don't make the receiver give up on CRC-16: the sender is there, and
    /// has chosen it.
    @Test func damagedFirstBlocksKeepCRC() throws {
        let dir = try tempDir()
        let probe = XmodemProbe(.xmodemReceive(dir.appendingPathComponent("out.bin")), directory: dir)
        try probe.transfer.start()
        var damaged = X.block(1, plain(128), size: 128, crc: true, pad: X.eofPad)
        damaged[50] ^= 0x55
        for _ in 0..<4 {
            let n = probe.output.count
            #expect(probe.waitForOutput(from: max(0, n - 1)) { $0.last == X.crcRequest })
            probe.feed(damaged)
            #expect(probe.waitForOutput(from: n, timeout: 4) { $0.contains(X.crcRequest) })
        }
        #expect(!probe.output.contains(X.nak), "fell back to the checksum: \(ZmodemTrace.hex(Array(probe.output)))")
        probe.transfer.cancel()
    }

    @Test func ymodemShortFileIsNotKept() throws {
        let dir = try tempDir()
        let probe = XmodemProbe(.ymodemReceive, directory: dir)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        var n = probe.output.count
        probe.feed(X.block(0, X.header(name: "f.bin", size: 4096, modified: nil, filesLeft: 1, bytesLeft: 4096),
                           size: 128, crc: true, pad: 0))
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.ack, X.crcRequest]) })
        n = probe.output.count
        probe.feed(X.block(1, plain(1024), size: 1024, crc: true, pad: X.eofPad))
        #expect(probe.waitForOutput(from: n) { $0 == Data([X.ack]) })
        probe.feed([X.eot])
        #expect(probe.waitForOutput(from: n) { $0.last == X.nak })
        probe.feed([X.eot])
        let r = try #require(probe.result())
        #expect(!r.ok && r.message.contains("only 1024 of the 4096 bytes"), "\(r.message)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func outOfStepBlockAborts() throws {
        let dir = try tempDir()
        let probe = XmodemProbe(.xmodemReceive(dir.appendingPathComponent("out.bin")), directory: dir)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        probe.feed(X.block(2, [1, 2, 3], size: 128, crc: true, pad: X.eofPad))
        let r = try #require(probe.result())
        #expect(!r.ok && r.message.contains("expected 1"), "\(r.message)")
        #expect(probe.output.range(of: Data(X.abortSequence)) != nil, "the sender is told to stop")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "no partial file")
    }

    /// After the batch: the remote's prompt goes to the terminal.
    @Test func promptAfterTheBatchIsShown() throws {
        let dir = try tempDir()
        let probe = XmodemProbe(.ymodemReceive, directory: dir)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        let n = probe.output.count
        probe.feed(X.block(0, [], size: 128, crc: true, pad: 0) + Array("$ ".utf8))
        let r = try #require(probe.result())
        #expect(r.ok && r.message == "No files received", "\(r.message)")
        #expect(probe.output.dropFirst(n).contains(X.ack))
        #expect(probe.leftover.all.reduce(Data(), +) == Data("$ ".utf8))
    }

    /// Started before the remote's `sb`: the 'C's reached its shell, which echoed them; that's shown.
    @Test func noSenderShowsWhatArrived() throws {
        let dir = try tempDir()
        let probe = XmodemProbe(.ymodemReceive, directory: dir, timeout: 0.1)
        try probe.transfer.start()
        #expect(probe.waitForOutput { $0.first == X.crcRequest })
        probe.feed("C\r\nsh: C: not found\r\n$ ")
        let r = try #require(probe.result(timeout: 20))
        #expect(!r.ok && r.message.contains("No YMODEM sender"), "\(r.message)")
        let shown = String(decoding: probe.leftover.all.reduce(Data(), +), as: UTF8.self)
        #expect(shown.contains("C: not found"), "\(shown)")
    }
}
