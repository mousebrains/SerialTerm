// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
import Testing
@testable import SerialCore

/// The built-in XMODEM and YMODEM against lrzsz over a pty, as on a device running lrzsz.
extension ZmodemEndToEndTests {
    func finish(_ events: Inbox<SessionEvent>, _ label: String, timeout: TimeInterval = 60) {
        let done = events.wait(timeout: timeout) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
        #expect(done, "\(label): no result")
        for case let .transferFinished(success, message) in events.all { #expect(success, "\(label): \(message)") }
    }

    /// lrzsz's `rx` asks for the checksum unless given -c, which is what SerialTerm types; both
    /// modes, in 128- and 1024-byte blocks.
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func xmodemSendToLrx(crc: Bool, oneK: Bool) throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        let file = try makeFiles(in: src)[3]  // 300_001 bytes
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: src)
        session.xmodem1K = oneK
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        let remote = try runRemote(["lrx", "rx"], ["-b"] + (crc ? ["-c"] : []) + ["out.bin"], in: dst, pty: pty)
        defer { remote.stop() }
        try session.startTransfer(.xmodemSend(file))
        finish(events, "crc \(crc), 1K \(oneK)")
        remote.process.waitUntilExit()
        let original = try Data(contentsOf: file)
        let got = try Data(contentsOf: dst.appendingPathComponent("out.bin"))
        #expect(got.prefix(original.count) == original)
        #expect(got.count == (original.count + 127) / 128 * 128)
        #expect(got.dropFirst(original.count).allSatisfy { $0 == 0x1A })
    }

    @Test func xmodemReceiveFromLsx1K() throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        let file = try makeFiles(in: src)[3]
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: dst)
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        let out = dst.appendingPathComponent("got.bin")
        let remote = try runRemote(["lsx", "sx"], ["-b", "-k", file.lastPathComponent], in: src, pty: pty)
        defer { remote.stop() }
        try session.startTransfer(.xmodemReceive(out))
        finish(events, "lsx -k")
        let original = try Data(contentsOf: file)
        let got = try Data(contentsOf: out)
        #expect(got.prefix(original.count) == original)
        #expect(got.dropFirst(original.count).allSatisfy { $0 == 0x1A })
    }

    @Test func ymodemReceiveFromLsb() throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src)
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: dst)
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        let remote = try runRemote(["lsb", "sb"], ["-b"] + files.map(\.lastPathComponent), in: src, pty: pty)
        defer { remote.stop() }
        try session.startTransfer(.ymodemReceive)
        finish(events, "lsb")
        for f in files {
            #expect(try Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent)) == Data(contentsOf: f),
                    "\(f.lastPathComponent)")
        }
    }

    /// lrzsz on the far side of a line that corrupts and drops data, both ways.
    @Test(arguments: ["xmodem to rx", "xmodem from sx", "ymodem to rb", "ymodem from sb"])
    func xmodemOverNoisyLine(direction: String) throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        var rng = SystemRandomNumberGenerator()
        let file = src.appendingPathComponent("noisy.bin")
        try Data((0..<120_000).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: file)
        let noise = Mangler(flipAt: [3_000, 40_000, 40_100, 90_000], dropAt: [60_000: 300])
        let toRemote = direction.contains(" to ")
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()),
                              downloadDirectory: toRemote ? src : dst)
        session.xmodem1K = true
        let traces = try tempDir()
        session.traceDirectory = traces
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        let out = dst.appendingPathComponent("noisy.bin")
        let remote: RemoteProgram
        switch direction {
        case "xmodem to rx":
            remote = try runRemote(["lrx", "rx"], ["-b", "-c", "noisy.bin"], in: dst, pty: pty, toRemote: noise)
            try session.startTransfer(.xmodemSend(file))
        case "xmodem from sx":
            remote = try runRemote(["lsx", "sx"], ["-b", "-k", "noisy.bin"], in: src, pty: pty, fromRemote: noise)
            try session.startTransfer(.xmodemReceive(out))
        case "ymodem to rb":
            remote = try runRemote(["lrb", "rb"], ["-b"], in: dst, pty: pty, toRemote: noise)
            try session.startTransfer(.ymodemSend([file]))
        default:
            remote = try runRemote(["lsb", "sb"], ["-b", "noisy.bin"], in: src, pty: pty, fromRemote: noise)
            try session.startTransfer(.ymodemReceive)
        }
        defer { remote.stop() }
        finish(events, direction, timeout: 120)
        if toRemote { remote.process.waitUntilExit() }
        let original = try Data(contentsOf: file)
        #expect(try Data(contentsOf: out).prefix(original.count) == original, "\(direction)")
        // The trace shows the damage being repaired.
        let trace = try String(contentsOf: try #require(session.lastTraceURL), encoding: .utf8)
        #expect(trace.contains(toRemote ? "NAK for block" : "bad block"), "\(direction)")
    }

    /// A lost USB packet takes a 1K block's start byte with it; the block's data has 0x04s in it.
    /// Receiving, that once ended the file early, reported complete, over the chosen file.
    /// Sending to lrzsz's rx, which NAKs again and again for one such block, every copy sent at
    /// once was cut up too, until it gave up.
    @Test(arguments: ["from sx", "to rx"])
    func lostBlockStart(direction: String) throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        var rng = SystemRandomNumberGenerator()
        var content: [UInt8] = (0..<4096).map { _ in
            var b: UInt8
            repeat { b = UInt8.random(in: 0...255, using: &rng) } while [0x01, 0x02, 0x04, 0x18].contains(b)
            return b
        }
        content[2048 + 100] = 0x04
        content[2048 + 200] = 0x04
        let file = src.appendingPathComponent("f.bin")
        try Data(content).write(to: file)
        let fromRemote = direction == "from sx"
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()),
                              downloadDirectory: fromRemote ? dst : src)
        session.xmodem1K = true
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        let out = dst.appendingPathComponent(fromRemote ? "got.bin" : "f.bin")
        let drop = Mangler(dropAt: [2058: 1])  // the STX of block 3
        let remote: RemoteProgram
        if fromRemote {
            try Data("the previous version".utf8).write(to: out)
            remote = try runRemote(["lsx", "sx"], ["-b", "-k", "f.bin"], in: src, pty: pty, fromRemote: drop)
            try session.startTransfer(.xmodemReceive(out))
        } else {
            remote = try runRemote(["lrx", "rx"], ["-b", "-c", "f.bin"], in: dst, pty: pty, toRemote: drop)
            try session.startTransfer(.xmodemSend(file))
        }
        defer { remote.stop() }
        finish(events, direction)
        if !fromRemote { remote.process.waitUntilExit() }
        #expect(try Data(contentsOf: out).prefix(4096) == Data(content), "\(direction)")
    }
}
