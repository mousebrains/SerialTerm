// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Darwin
import Foundation
import Testing
@testable import SerialCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SerialTermTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Makes `fd` fail every write, the way a full disk or a vanished volume would.
private func breakWrites(to fd: Int32) {
    let readOnly = open("/dev/null", O_RDONLY)
    dup2(readOnly, fd)
    close(readOnly)
}

struct LogFileTests {
    /// Two windows starting their logs in the same second used to share one file and overwrite
    /// each other's lines.
    @Test func sameNameGetsItsOwnFile() throws {
        let url = try tempDir().appendingPathComponent("SerialTerm-2026-10-21-120000.log")
        let a = try SessionLogger(url: url), b = try SessionLogger(url: url)
        #expect(a.url == url)
        #expect(b.url.lastPathComponent == "SerialTerm-2026-10-21-120000-2.log")
        for i in 0..<200 {
            a.note("A \(i)")
            b.note("B \(i)")
        }
        a.flush()
        b.flush()
        let linesA = try String(contentsOf: a.url, encoding: .utf8).split(separator: "\n")
        let linesB = try String(contentsOf: b.url, encoding: .utf8).split(separator: "\n")
        #expect(linesA.count == 200 && linesA.enumerated().allSatisfy { $1.hasSuffix(" -- A \($0)") })
        #expect(linesB.count == 200 && linesB.enumerated().allSatisfy { $1.hasSuffix(" -- B \($0)") })
    }

    @Test func traceNamesDontCollideEither() throws {
        let url = try tempDir().appendingPathComponent(ZmodemTrace.defaultFileName())
        let a = try ZmodemTrace(url: url, level: .frames), b = try ZmodemTrace(url: url, level: .frames)
        #expect(a.url != b.url)
        #expect(b.url.lastPathComponent.hasSuffix("-zmodem-2.log"))
    }

    /// A write error used to raise an Objective-C exception and abort the app.
    @Test func writeErrorStopsTheLogInsteadOfCrashing() throws {
        let logger = try SessionLogger(url: try tempDir().appendingPathComponent("t.log"))
        let failures = Inbox<Error>()
        logger.onFailure = { failures.add($0) }
        logger.note("before")
        logger.flush()
        breakWrites(to: logger.file.fileDescriptor)
        logger.note("after")
        logger.note("and again")
        logger.flush()
        #expect(failures.all.count == 1)
    }

    @Test func traceWriteErrorIsReportedOnce() throws {
        let trace = try ZmodemTrace(url: try tempDir().appendingPathComponent("z.log"), level: .frames)
        let failures = Inbox<Error>()
        trace.onFailure = { failures.add($0) }
        breakWrites(to: trace.file.fileDescriptor)
        for i in 0..<10 { trace.note("line \(i)") }
        trace.summary(outcome: "test", duration: 1)
        #expect(failures.all.count == 1)
    }

    /// Notes quote remote file names; a newline in one used to forge a log line.
    @Test func notesAreOneLine() {
        #expect(SessionLogger.escapeNote("a\n2026-10-21 12:00:00.000 RX forged") == "a\\n2026-10-21 12:00:00.000 RX forged")
        #expect(SessionLogger.escapeNote("\u{202E}fdp.exe") == "\\u{202E}fdp.exe")
        #expect(SessionLogger.escapeNote("Received DAT_001.P (12 KB) → café") == "Received DAT_001.P (12 KB) → café")
        #expect(SessionLogger.escapeNote("tab\tesc\u{1B}nel\u{85}") == "tab\\tesc\\enel\\x85")
    }
}

struct PacingCancelTests {
    /// Cancelling used to leave the echo wait in place, so the next key (even Ctrl-C) waited out
    /// the echo timeout and "No echo" appeared after a deliberate cancel.
    @Test func cancelEndsTheEchoWait() throws {
        let sender = PacedSender()
        sender.pacing = Pacing(waitForEcho: true, echoTimeout: 3)
        let out = Inbox<(Date, Data)>()
        let pending = Inbox<(Int, Bool)>()
        sender.output = { out.add((Date(), $0)) }
        sender.onPending = { pending.add(($0, $1)) }
        sender.send(Data("ab".utf8))  // "a" goes out; no echo comes
        #expect(out.wait(timeout: 1) { $0.count == 1 })
        sender.cancel()
        let typed = Date()
        sender.send(Data([0x03]))
        try #require(out.wait(timeout: 1) { $0.count == 2 })
        #expect(out.all[1].0.timeIntervalSince(typed) < 0.5)
        #expect(String(decoding: out.all.map(\.1).reduce(Data(), +), as: UTF8.self) == "a\u{03}")
        usleep(200_000)
        #expect(!pending.all.contains { $0.1 }, "no 'No echo' after a cancel")
    }

    /// The character showing up further on in the device's output isn't its echo.
    @Test func echoMustComeFirst() {
        let sender = PacedSender()
        sender.pacing = Pacing(waitForEcho: true, echoTimeout: 0.3)
        let pending = Inbox<(Int, Bool)>()
        sender.output = { [weak sender] _ in
            sender?.received(Data(repeating: UInt8(ascii: "x"), count: PacedSender.echoWindow) + Data("l".utf8))
        }
        sender.onPending = { pending.add(($0, $1)) }
        sender.send(Data("lm".utf8))
        #expect(pending.wait(timeout: 3) { $0.contains { $0.1 } }, "timed out rather than matching a late 'l'")
    }
}

@Suite(.serialized)
struct SerialPortRobustnessTests {
    /// A refused rate used to leave the line at the 9600 placeholder with the new framing.
    /// IOSSIOSPEED always fails on a pty, which stands in for a driver that refuses a rate.
    @Test func refusedRateRestoresTheOldSettings() throws {
        let pty = try PtyPair()
        let port = SerialPort(path: pty.slavePath, config: SerialConfig(baudRate: 115_200))
        try port.open()
        defer { port.close() }
        #expect(throws: SerialError.self) {
            try port.reconfigure(SerialConfig(baudRate: 460_800, dataBits: 7, parity: .even))
        }
        var t = termios()
        #expect(tcgetattr(pty.master, &t) == 0)
        #expect(cfgetospeed(&t) == 115_200)
        #expect(t.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS8))
        #expect(t.c_cflag & tcflag_t(PARENB) == 0)
        #expect(port.config.baudRate == 115_200)
    }

    /// After a discard, the rest of the chunk being written used to keep going out.
    @Test func discardStopsTheWriteInProgress() throws {
        let pty = try PtyPair()
        let port = SerialPort(path: pty.slavePath, config: SerialConfig())
        try port.open()
        defer { port.close() }
        port.write(Data(repeating: 0x55, count: 1_000_000))  // far more than the pty buffers
        usleep(200_000)
        port.discardPendingWrites()
        #expect(port.waitForPendingWrites(maxPending: 0, timeout: 2))
        var got = 0
        while case let d = pty.readFromPort(timeout: 0.5), !d.isEmpty { got += d.count }
        #expect(got < 200_000, "\(got) bytes still went out after the discard")
    }

    /// The port's descriptor used to be inherited by programs the app starts (the lrzsz runner).
    @Test func descriptorIsNotInherited() throws {
        let pty = try PtyPair()
        func descriptors() -> Set<Int32> {
            Set((0..<min(getdtablesize(), 4096)).filter { fd in
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                return fcntl(fd, F_GETPATH, &path) == 0 && String(cString: path) == pty.slavePath
            })
        }
        let before = descriptors()
        let port = SerialPort(path: pty.slavePath, config: SerialConfig())
        try port.open()
        defer { port.close() }
        let opened = descriptors().subtracting(before)
        #expect(opened.count == 1)
        for fd in opened { #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0) }
    }

    /// Waits on a line that isn't moving (flow control holding it) can time out or be stopped.
    @Test func waitsCanTimeOutOrStop() throws {
        let pty = try PtyPair()
        let port = SerialPort(path: pty.slavePath, config: SerialConfig())
        try port.open()
        defer { port.close() }
        port.write(Data(repeating: 0x55, count: 1_000_000))
        var start = Date()
        #expect(!port.waitForPendingWrites(maxPending: 0, timeout: 0.3))
        #expect(Date().timeIntervalSince(start) < 1)
        start = Date()
        #expect(!port.waitForPendingWrites(maxPending: 1000, until: { true }))
        #expect(Date().timeIntervalSince(start) < 0.5)
        port.discardPendingWrites()
    }
}

struct ExternalTransferCommandTests {
    @Test func namesThatLookLikeOptions() throws {
        let (_, args, _) = try ExternalTransfer.command(for: .xmodemReceive(URL(fileURLWithPath: "/tmp/-ZZ.bin")))
        #expect(args.suffix(2) == ["--", "-ZZ.bin"])
        let (_, plain, _) = try ExternalTransfer.command(for: .xmodemReceive(URL(fileURLWithPath: "/tmp/ZZ.bin")))
        #expect(plain.last == "ZZ.bin" && !plain.contains("--"))
        #expect(TransferKind.xmodemSend(URL(fileURLWithPath: "/tmp/-x.bin")).remoteReceiveCommand == "rx '--' '-x.bin'\r")
        #expect(TransferKind.xmodemSend(URL(fileURLWithPath: "/tmp/it's.bin")).remoteReceiveCommand == "rx 'it'\\''s.bin'\r")
    }

    /// "\r\n" is one Character in Swift, so splitting on "\r" or "\n" kept CRLFs in messages.
    @Test func statusLines() {
        #expect(ExternalTransfer.latestStatusLine("\r\nTransfer incomplete\r\n") == "Transfer incomplete")
        #expect(ExternalTransfer.latestStatusLine("Bytes Sent:   1024\rBytes Sent:   2048\r") == "Bytes Sent:   2048")
        #expect(ExternalTransfer.latestStatusLine(" \r\n \n") == nil)
    }
}

@Suite(.serialized, .enabled(if: ExternalTransfer.findTool(["lsz", "sz"]) != nil, "lrzsz not installed (brew install lrzsz)"))
struct ExternalTransferBehaviourTests {
    /// lsz's output used to go straight into an unbounded queue: on a slow line the whole file
    /// queued up, lsz's ZEOF timer expired, and a cancel waited behind it all.
    @Test func lszIsHeldBackAndCancelDiscardsFirst() throws {
        let file = try tempDir().appendingPathComponent("f.bin")
        try Data(repeating: 1, count: 1000).write(to: file)
        let t = try ExternalTransfer(kind: .zmodemSend([file]), workingDirectory: file.deletingLastPathComponent())
        let calls = Inbox<String>()
        let finished = Inbox<Bool>()
        t.onOutput = { calls.add($0 == ExternalTransfer.abortSequence ? "abort" : "output") }
        t.waitForOutput = { calls.add("wait \($0)") }
        t.discardOutput = { calls.add("discard") }
        t.onFinish = { ok, _ in finished.add(ok) }
        try t.start()
        #expect(calls.wait(timeout: 5) { $0.contains("wait \(ExternalTransfer.maxQueuedOutput)") })
        t.cancel()
        #expect(finished.wait(timeout: 5) { !$0.isEmpty })
        let after = calls.all.drop { $0 != "discard" }
        #expect(after.first == "discard" && after.dropFirst().first == "abort")
    }

    /// A transfer that can't start (here: its folder is gone) used to leave the window stuck
    /// "transferring": `transferStarted` with no `transferFinished`, after typing `rx` to the remote.
    @Test func failedStartIsReportedAndTypesNothing() throws {
        let pty = try PtyPair()
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try Data(repeating: 1, count: 100).write(to: file)
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()),
                              downloadDirectory: dir.appendingPathComponent("no-such-folder"))
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        #expect(throws: Session.TransferStartFailed.self) { try session.startTransfer(.xmodemSend(file), startRemote: true) }
        #expect(events.wait(timeout: 2) { $0.count >= 2 })
        guard case .transferStarted = events.all.first, case let .transferFinished(success, _) = events.all.last else {
            Issue.record("events: \(events.all)")
            return
        }
        #expect(!success)
        #expect(!session.isTransferring)
        #expect(pty.readFromPort(timeout: 0.5).isEmpty, "nothing typed to the remote")
    }
}

@Suite(.serialized)
struct SessionLifecycleTests {
    /// Disconnecting mid-transfer used to close the port first and cancel later, from a handler
    /// that ran after the window had let go of the session: no abort reached the remote and the
    /// transfer carried on.
    @Test func closeDuringTransferAbortsTheRemote() throws {
        let pty = try PtyPair()
        let dir = try tempDir()
        let file = dir.appendingPathComponent("f.bin")
        try Data(repeating: 1, count: 100_000).write(to: file)
        var session: Session? = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: dir)
        try session?.open()
        try session?.startTransfer(.zmodemSend([file]))  // nobody answers; the sender waits for ZRINIT
        #expect(pty.readFromPort(timeout: 1).count > 0)  // "rz\r" and ZRQINIT
        weak let released = session
        session?.close()
        session = nil
        let after = pty.readFromPort(timeout: 1)
        #expect(after.range(of: ExternalTransfer.abortSequence) != nil, "abort sent before the port closed")
        #expect(released == nil)
    }

    /// A remote that keeps starting a transfer and aborting it used to restart a failing receive
    /// many times a second, with a beep each time.
    @Test func repeatedAutomaticFailuresPause() throws {
        let pty = try PtyPair()
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: try tempDir())
        var options = ZmodemOptions()
        options.traceLevel = .off
        session.zmodemOptions = options
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        var e = ZEncoder()
        let rqinit = Data(e.hexHeader(ZHeader(.rqinit)))
        for _ in 0..<5 {
            pty.writeToPort(rqinit)
            usleep(150_000)
            pty.writeToPort(Data(repeating: 0x18, count: 5))  // the remote aborts at once
            usleep(250_000)
            _ = pty.readFromPort(timeout: 0.05)
        }
        let started = events.all.filter { if case .transferStarted = $0 { true } else { false } }.count
        #expect(started == 3)
        #expect(events.all.contains { if case .notice = $0 { true } else { false } })
    }
}

extension ZmodemEndToEndTests {
    /// lrz keeps names the built-in receiver makes safe, such as ".profile"; files it receives
    /// are now moved into the download folder under the same safe names.
    @Test func lrzszReceiveUsesSafeNames() throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        try Data("dot file".utf8).write(to: src.appendingPathComponent(".hidden"))
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: dst)
        session.autoZmodem = false
        session.useExternalZmodem = true
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        try session.startTransfer(.zmodemReceive)
        let remote = try runRemote(["lsz", "sz"], ["-b", ".hidden"], in: src, pty: pty)
        defer { remote.stop() }
        #expect(events.wait(timeout: 30) { $0.contains { if case .transferFinished = $0 { true } else { false } } })
        for case let .transferFinished(success, message) in events.all { #expect(success, "\(message)") }
        let names = try FileManager.default.contentsOfDirectory(atPath: dst.path)
        #expect(names == ["hidden"], "\(names)")
        #expect(try Data(contentsOf: dst.appendingPathComponent("hidden")) == Data("dot file".utf8))
        let values = try dst.appendingPathComponent("hidden").resourceValues(forKeys: [.quarantinePropertiesKey])
        #expect(values.quarantineProperties?["LSQuarantineAgentName"] as? String == "SerialTerm", "marked as downloaded")
    }
}
