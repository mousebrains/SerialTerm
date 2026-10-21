// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
import Testing
@testable import SerialCore

/// Timing checks use lower bounds only, so a slow machine can't make them fail.
struct PacingTests {
    /// Runs `sender` and returns each chunk it wrote with the time since the first one.
    func run(_ pacing: Pacing, _ text: String, cancelAfter: TimeInterval? = nil) -> [(at: TimeInterval, bytes: String)] {
        let sender = PacedSender()
        sender.pacing = pacing
        let out = Inbox<(Date, Data)>()
        let done = Inbox<Int>()
        sender.output = { out.add((Date(), $0)) }
        sender.onPending = { n, _ in done.add(n) }
        sender.send(Data(text.utf8))
        if let cancelAfter {
            usleep(UInt32(cancelAfter * 1_000_000))
            sender.cancel()
            usleep(300_000)
        } else {
            #expect(done.wait(timeout: 10) { $0.last == 0 })
        }
        let chunks = out.all
        guard let first = chunks.first?.0 else { return [] }
        return chunks.map { ($0.0.timeIntervalSince(first), String(decoding: $0.1, as: UTF8.self)) }
    }

    @Test func limitsCharactersPerSecond() {
        let chunks = run(Pacing(charactersPerSecond: 50), "0123456789")
        #expect(chunks.map(\.bytes) == "0123456789".map { String($0) })
        #expect(chunks.last!.at >= 9.0 / 50 * 0.95)  // nine gaps of 20 ms
    }

    @Test func pausesAfterEachLine() {
        // No character limit: each line goes out whole, then the pause.
        let chunks = run(Pacing(lineDelay: 0.1), "ls\rpwd\r\nexit")
        #expect(chunks.map(\.bytes) == ["ls\r", "pwd\r", "\nexit"])
        #expect(chunks[1].at >= 0.095)
        #expect(chunks[2].at >= 0.195)
    }

    @Test func crlfIsOneLineEnd() {
        let chunks = run(Pacing(charactersPerSecond: 1000, lineDelay: 0.1), "a\r\nb")
        #expect(chunks.map(\.bytes) == ["a", "\r", "\n", "b"])
        // The pause comes after CR only; LF follows at the character rate.
        #expect(chunks[2].at - chunks[1].at >= 0.095)
        #expect(chunks[3].at - chunks[2].at < 0.09)
    }

    @Test func lfAloneIsALineEnd() {
        let chunks = run(Pacing(lineDelay: 0.1), "a\nb")
        #expect(chunks.map(\.bytes) == ["a\n", "b"])
        #expect(chunks[1].at >= 0.095)
    }

    @Test func cancelDropsTheRest() {
        let chunks = run(Pacing(charactersPerSecond: 20), String(repeating: "x", count: 100), cancelAfter: 0.2)
        #expect(chunks.count >= 2 && chunks.count < 20)
    }

    @Test func keepsOrderAcrossSends() {
        let sender = PacedSender()
        sender.pacing = Pacing(charactersPerSecond: 500)
        let out = Inbox<Data>()
        let done = Inbox<Int>()
        sender.output = { out.add($0) }
        sender.onPending = { n, _ in done.add(n) }
        for word in ["one ", "two ", "three"] { sender.send(Data(word.utf8)) }
        #expect(done.wait(timeout: 10) { $0.last == 0 && out.all.count == 13 })
        #expect(String(decoding: out.all.reduce(Data(), +), as: UTF8.self) == "one two three")
    }

    @Test func decodesOldSettings() throws {
        let p = try JSONDecoder().decode(Pacing.self, from: Data(#"{"charactersPerSecond":30}"#.utf8))
        #expect(p == Pacing(charactersPerSecond: 30))
        #expect(!Pacing().isOn && Pacing().summary.isEmpty)
        #expect(Pacing(charactersPerSecond: 30, lineDelay: 0.5, waitForEcho: true).summary == "echo + 30 char/s + 0.5 s/line")
    }

    @Test func echoMatching() {
        #expect(PacedSender.Echo(for: UInt8(ascii: "a")) == .byte(UInt8(ascii: "a")))
        #expect(PacedSender.Echo(for: 0x0D) == .lineEnd && PacedSender.Echo(for: 0x0A) == .lineEnd)
        #expect(PacedSender.Echo(for: 0x03) == .anything)
        #expect(!PacedSender.Echo.byte(0x61).isSatisfied(by: Data("bcd".utf8)))
        #expect(PacedSender.Echo.byte(0x61).isSatisfied(by: Data("xa".utf8)))
        #expect(PacedSender.Echo.lineEnd.isSatisfied(by: Data([0x0A])))
        #expect(PacedSender.Echo.anything.isSatisfied(by: Data("^C".utf8)))
    }

    /// A pretend device that echoes after `delay`, except for the characters in `silent`.
    func runWithEcho(_ text: String, delay: TimeInterval, silent: Set<Character> = [],
                     timeout: Double = 1) -> (chunks: [(at: TimeInterval, bytes: String)], missing: Bool) {
        let sender = PacedSender()
        sender.pacing = Pacing(waitForEcho: true, echoTimeout: timeout)
        let out = Inbox<(Date, Data)>()
        let done = Inbox<(Int, Bool)>()
        let device = DispatchQueue(label: "device")
        sender.output = { [weak sender] data in
            out.add((Date(), data))
            let s = String(decoding: data, as: UTF8.self)
            guard !s.contains(where: silent.contains) else { return }
            let echo = s == "\r" ? Data("\r\n".utf8) : data
            device.asyncAfter(deadline: .now() + delay) { sender?.received(echo) }
        }
        sender.onPending = { done.add(($0, $1)) }
        sender.send(Data(text.utf8))
        #expect(done.wait(timeout: 10) { $0.last?.0 == 0 })
        usleep(UInt32((delay + 0.05) * 1_000_000))
        let first = out.all.first!.0
        return (out.all.map { ($0.0.timeIntervalSince(first), String(decoding: $0.1, as: UTF8.self)) },
                done.all.contains { $0.1 })
    }

    @Test func waitsForEachEcho() {
        let r = runWithEcho("ls -l\r", delay: 0.03)
        #expect(r.chunks.map(\.bytes) == ["l", "s", " ", "-", "l", "\r"])
        #expect(r.chunks.last!.at >= 5 * 0.03 * 0.95)  // each waits for the one before
        #expect(!r.missing)
    }

    @Test func carriesOnWithoutEcho() {
        let r = runWithEcho("abc", delay: 0.01, silent: ["b"], timeout: 0.2)
        #expect(r.chunks.map(\.bytes) == ["a", "b", "c"])
        #expect(r.chunks[2].at - r.chunks[1].at >= 0.19)
        #expect(r.missing)
    }
}

@Suite(.serialized)
struct PacedSessionTests {
    @Test func pacesTypingButNotWhenOff() throws {
        let pty = try PtyPair()
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()),
                              downloadDirectory: FileManager.default.temporaryDirectory)
        try session.open()
        defer { session.close() }

        session.sendFromUser(Data("fast".utf8))
        #expect(String(decoding: pty.readFromPort(timeout: 1), as: UTF8.self) == "fast")

        session.pacing = Pacing(charactersPerSecond: 20)
        let start = Date()
        session.sendFromUser(Data("slow\r".utf8))
        var got = Data()
        while got.count < 5, Date().timeIntervalSince(start) < 5 { got += pty.readFromPort(timeout: 0.5) }
        #expect(String(decoding: got, as: UTF8.self) == "slow\r")
        #expect(Date().timeIntervalSince(start) >= 4.0 / 20 * 0.95)
    }
}
