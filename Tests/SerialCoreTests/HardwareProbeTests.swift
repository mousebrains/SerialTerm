// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
import Testing
@testable import SerialCore

/// Talks to a real device; only runs when SERIALTERM_PROBE_PORT is set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SERIALTERM_PROBE_PORT"] != nil))
struct HardwareProbeTests {
    @Test func openAndGetReply() throws {
        let path = ProcessInfo.processInfo.environment["SERIALTERM_PROBE_PORT"]!
        let port = SerialPort(path: path, config: SerialConfig(baudRate: 115_200))
        let got = Inbox<Data>()
        port.onData = { got.add($0) }
        try port.open()
        defer { port.close() }
        port.write(Data("\r".utf8))
        _ = got.wait(timeout: 2) { $0.reduce(Data(), +).count > 10 }
        let text = String(decoding: got.all.reduce(Data(), +), as: UTF8.self)
        print("PROBE REPLY:", text.debugDescription)
        #expect(!text.isEmpty)
    }
}

/// Sends a file to a real device running a shell with lrzsz, then checks it with md5sum over the
/// same line. Runs only when SERIALTERM_PROBE_PORT and SERIALTERM_PROBE_SEND_FILE are set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SERIALTERM_PROBE_SEND_FILE"] != nil))
struct HardwareSendTests {
    @Test func sendFileAndVerify() throws {
        let env = ProcessInfo.processInfo.environment
        let path = env["SERIALTERM_PROBE_PORT"]!
        let file = URL(fileURLWithPath: env["SERIALTERM_PROBE_SEND_FILE"]!)
        let traceDir = URL(fileURLWithPath: env["SERIALTERM_PROBE_TRACE_DIR"] ?? NSTemporaryDirectory())

        let session = Session(port: SerialPort(path: path, config: SerialConfig()), downloadDirectory: traceDir)
        session.traceDirectory = traceDir
        session.autoZmodem = false  // we start the send ourselves
        let shown = Inbox<Data>()
        let events = Inbox<SessionEvent>()
        session.onDisplay = { shown.add($0) }
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        let start = Date()
        try session.startTransfer(.zmodemSend([file]))
        let finished = events.wait(timeout: 600) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
        let seconds = Date().timeIntervalSince(start)
        #expect(finished)
        for case let .transferFinished(success, message) in events.all {
            print("PROBE SEND: \(success ? "OK" : "FAILED") \(message) in \(String(format: "%.1f", seconds)) s")
            #expect(success)
        }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
        print("PROBE RATE: \(String(format: "%.2f", Double(size) / seconds / 1e6)) MB/s")
        if let url = session.lastTraceURL { print("PROBE TRACE: \(url.path)") }

        // Ask the device for the checksum of what it received.
        Thread.sleep(forTimeInterval: 0.5)
        let before = shown.all.count
        session.sendFromUser(Data("md5sum '\(file.lastPathComponent)'\r".utf8))
        _ = shown.wait(timeout: 30) { items in
            String(decoding: items.dropFirst(before).reduce(Data(), +), as: UTF8.self).contains(file.lastPathComponent + "\r\n")
                && items.count > before + 1
        }
        Thread.sleep(forTimeInterval: 1)
        print("PROBE REMOTE:", String(decoding: shown.all.dropFirst(before).reduce(Data(), +), as: UTF8.self).debugDescription)
    }
}

/// Raw receive throughput of a device shell (no ZMODEM): streams N 'A' bytes into `head -c N`.
/// Runs only when SERIALTERM_PROBE_PORT and SERIALTERM_PROBE_RAW are set.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SERIALTERM_PROBE_RAW"] != nil))
struct HardwareRawThroughputTests {
    func measure(into target: String) throws -> Double {
        let path = ProcessInfo.processInfo.environment["SERIALTERM_PROBE_PORT"]!
        let port = SerialPort(path: path, config: SerialConfig())
        let shown = Inbox<Data>()
        port.onData = { shown.add($0) }
        try port.open()
        defer { port.close() }

        let n = 20_000_000
        port.write(Data("stty raw -echo; head -c \(n) > \(target); stty sane; echo RAWDONE\r".utf8))
        port.waitForPendingWrites()
        Thread.sleep(forTimeInterval: 1)
        let chunk = Data(repeating: 0x41, count: 16 * 1024)
        let start = Date()
        var sent = 0
        while sent < n {
            let c = min(chunk.count, n - sent)
            port.write(chunk.prefix(c))
            sent += c
            port.waitForPendingWrites(maxPending: 64 * 1024)
        }
        port.waitForPendingWrites()
        #expect(shown.wait(timeout: 120) { String(decoding: $0.reduce(Data(), +), as: UTF8.self).contains("RAWDONE\r\n") })
        let seconds = Date().timeIntervalSince(start)
        let rate = Double(n) / seconds / 1e6
        print("PROBE RAW → \(target): \(String(format: "%.2f", rate)) MB/s (\(String(format: "%.1f", seconds)) s)")
        return rate
    }

    @Test func rawReceiveRates() throws {
        _ = try measure(into: "/dev/null")
        _ = try measure(into: "~/tpw/rawtest.bin")
        // Tidy up the test file.
        let port = SerialPort(path: ProcessInfo.processInfo.environment["SERIALTERM_PROBE_PORT"]!, config: SerialConfig())
        try port.open()
        port.write(Data("rm -f ~/tpw/rawtest.bin\r".utf8))
        port.waitForPendingWrites()
        Thread.sleep(forTimeInterval: 0.5)
        port.close()
    }
}

/// XMODEM against a real device's lrzsz, through SerialTerm's lrzsz runner. Runs only when
/// SERIALTERM_PROBE_PORT and SERIALTERM_PROBE_XMODEM are set; the device shell should be in a scratch dir.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SERIALTERM_PROBE_XMODEM"] != nil))
struct HardwareXmodemTests {
    final class Rig {
        let session: Session
        let shown = Inbox<Data>()
        let events = Inbox<SessionEvent>()
        init(downloads: URL) throws {
            let path = ProcessInfo.processInfo.environment["SERIALTERM_PROBE_PORT"]!
            session = Session(port: SerialPort(path: path, config: SerialConfig()), downloadDirectory: downloads)
            session.onDisplay = { [shown] in shown.add($0) }
            session.onEvent = { [events] in events.add($0) }
            try session.open()
        }
        func shell(_ command: String, wait: TimeInterval = 1.5) -> String {
            let before = shown.all.count
            session.sendFromUser(Data((command + "\r").utf8))
            Thread.sleep(forTimeInterval: wait)
            return String(decoding: shown.all.dropFirst(before).reduce(Data(), +), as: UTF8.self)
        }
        func waitForFinish(_ timeout: TimeInterval = 120) -> (Bool, String, [String]) {
            _ = events.wait(timeout: timeout) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
            var statuses: [String] = []
            var result = (false, "no result")
            for e in events.all {
                if case let .transferStatus(s) = e { statuses.append(s) }
                if case let .transferFinished(ok, msg) = e { result = (ok, msg) }
            }
            return (result.0, result.1, statuses)
        }
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func toolsOnDevice() throws {
        let rig = try Rig(downloads: try tempDir())
        defer { rig.session.close() }
        print("PROBE TOOLS:", rig.shell("pwd; for t in sx rx sb rb sz rz; do printf '%s: ' $t; command -v $t || echo missing; done; ls -l $(command -v rx sx) 2>&1 | cat").debugDescription)
    }

    @Test func allFourDirections() throws {
        let dir = try tempDir()
        var rng = SystemRandomNumberGenerator()
        var files: [URL] = []
        for (name, size) in [("xy one.bin", 10_000), ("xytwo.bin", 70_001)] {
            let url = dir.appendingPathComponent(name)
            try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: url)
            files.append(url)
        }
        func md5(_ url: URL) -> String { Insecure_md5((try? Data(contentsOf: url)) ?? Data()) }

        // XMODEM send: SerialTerm types "rx 'name'".
        do {
            let rig = try Rig(downloads: dir)
            defer { rig.session.close() }
            _ = rig.shell("rm -f 'xy one.bin' xytwo.bin", wait: 0.5)
            try rig.session.startTransfer(.xmodemSend(files[0]), startRemote: true)
            let (ok, msg, _) = rig.waitForFinish()
            print("PROBE X SEND: \(ok) \(msg)")
            Thread.sleep(forTimeInterval: 1)
            print("PROBE X SEND REMOTE:", rig.shell("ls -l 'xy one.bin'; head -c 10000 'xy one.bin' | md5sum").debugDescription)
            print("PROBE X SEND LOCAL:", md5(files[0]))
        }
        // XMODEM receive: remote sx announces itself; we answer with a receive.
        do {
            let rig = try Rig(downloads: dir)
            defer { rig.session.close() }
            let dst = dir.appendingPathComponent("x back.bin")
            rig.session.onEvent = { [weak session = rig.session, events = rig.events] event in
                events.add(event)
                if case .remoteXmodemSending = event { try? session?.startTransfer(.xmodemReceive(dst)) }
            }
            _ = rig.shell("sx 'xy one.bin'", wait: 0.1)
            let (ok, msg, _) = rig.waitForFinish()
            let got = (try? Data(contentsOf: dst)) ?? Data()
            print("PROBE X RECEIVE: \(ok) \(msg); \(got.count) bytes; first 10000 match: \(got.prefix(10_000) == (try Data(contentsOf: files[0])))")
        }
        // YMODEM send of two files: SerialTerm types "rb".
        do {
            let rig = try Rig(downloads: dir)
            defer { rig.session.close() }
            Thread.sleep(forTimeInterval: 1)
            _ = rig.shell("rm -f 'xy one.bin'", wait: 0.5)
            try rig.session.startTransfer(.ymodemSend(files), startRemote: true)
            let (ok, msg, _) = rig.waitForFinish()
            print("PROBE Y SEND: \(ok) \(msg)")
            Thread.sleep(forTimeInterval: 1)
            print("PROBE Y SEND REMOTE:", rig.shell("ls -l 'xy one.bin' xytwo.bin; md5sum 'xy one.bin' xytwo.bin").debugDescription)
            print("PROBE Y SEND LOCAL:", files.map { md5($0) })
        }
        // YMODEM receive of two files: remote sb announces itself; receive starts automatically.
        do {
            let back = dir.appendingPathComponent("yback")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            let rig = try Rig(downloads: back)
            defer { rig.session.close() }
            _ = rig.shell("sb 'xy one.bin' xytwo.bin", wait: 0.1)
            let (ok, msg, _) = rig.waitForFinish()
            print("PROBE Y RECEIVE: \(ok) \(msg)")
            for f in files {
                let got = back.appendingPathComponent(f.lastPathComponent)
                print("PROBE Y RECEIVE \(f.lastPathComponent): exact match \((try? Data(contentsOf: got)) == (try Data(contentsOf: f)))")
            }
            Thread.sleep(forTimeInterval: 1)
            print("PROBE CLEANUP:", rig.shell("rm -f 'xy one.bin' xytwo.bin; ls").debugDescription)
        }
    }
    @Test func whatDoesSbSend() throws {
        let rig = try Rig(downloads: try tempDir())
        defer { rig.session.close() }
        rig.session.autoZmodem = false
        _ = rig.shell("printf hello > t.txt", wait: 0.5)
        let out = rig.shell("sb t.txt", wait: 3)
        print("PROBE SB OUTPUT:", out.debugDescription)
        rig.session.abortRemoteTransfer()
        Thread.sleep(forTimeInterval: 2)
        print("PROBE AFTER:", rig.shell("rm -f t.txt; ls -l $(command -v sb); readlink -f $(command -v sb)").debugDescription)
    }
    @Test func sbWithAutoStart() throws {
        let dir = try tempDir()
        let rig = try Rig(downloads: dir)
        defer { rig.session.close() }
        rig.session.traceDirectory = dir
        _ = rig.shell("printf hello > t1.txt; printf world > t2.txt", wait: 0.5)
        let start = Date()
        rig.session.onEvent = { [events = rig.events] e in
            events.add(e)
            print("PROBE EVENT +\(String(format: "%.1f", Date().timeIntervalSince(start)))s:", e)
        }
        rig.session.sendFromUser(Data("sb t1.txt t2.txt\r".utf8))
        let (ok, msg, _) = rig.waitForFinish(60)
        print("PROBE SB RESULT: \(ok) \(msg) after \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        print("PROBE SHOWN:", String(decoding: rig.shown.all.reduce(Data(), +), as: UTF8.self).suffix(300).debugDescription)
        if let t = rig.session.lastTraceURL, let text = try? String(contentsOf: t, encoding: .utf8) {
            print("PROBE TRACE HEAD:\n" + text.split(separator: "\n").prefix(8).joined(separator: "\n"))
        }
        print("PROBE FILES:", (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        Thread.sleep(forTimeInterval: 1)
        _ = rig.shell("rm -f t1.txt t2.txt", wait: 0.5)
    }
    @Test func ymodemReceiveManual() throws {
        let dir = try tempDir()
        let rig = try Rig(downloads: dir)
        defer { rig.session.close() }
        _ = rig.shell("head -c 30000 /dev/urandom > y1.bin; head -c 5000 /dev/urandom > y2.bin; md5sum y1.bin y2.bin", wait: 1)
        let sums = rig.shell("md5sum y1.bin y2.bin", wait: 1)
        _ = rig.shell("sb y1.bin y2.bin", wait: 1)
        let start = Date()
        try rig.session.startTransfer(.ymodemReceive)
        let (ok, msg, statuses) = rig.waitForFinish(60)
        print("PROBE YRX: \(ok) \(msg) after \(String(format: "%.1f", Date().timeIntervalSince(start))) s; last status \(statuses.last ?? "")")
        print("PROBE REMOTE SUMS:", sums.debugDescription)
        for n in ["y1.bin", "y2.bin"] {
            let d = (try? Data(contentsOf: dir.appendingPathComponent(n))) ?? Data()
            print("PROBE LOCAL \(n): \(d.count) bytes \(Insecure_md5(d))")
        }
        Thread.sleep(forTimeInterval: 1)
        _ = rig.shell("rm -f y1.bin y2.bin", wait: 0.5)
    }
    /// Cancel an XMODEM send mid-transfer; the device's rx must give up and return to the shell.
    @Test func cancelXmodemSend() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("cancel.bin")
        try Data(repeating: 0x5A, count: 1_000_000).write(to: file)
        let rig = try Rig(downloads: dir)
        defer { rig.session.close() }
        try rig.session.startTransfer(.xmodemSend(file), startRemote: true)
        _ = rig.events.wait(timeout: 30) { $0.filter { if case .transferStatus = $0 { true } else { false } }.count > 4 }
        let cancelled = Date()
        rig.session.cancelTransfer()
        _ = rig.waitForFinish(10)
        // Poll the shell until it answers.
        var answer = ""
        while Date().timeIntervalSince(cancelled) < 30 {
            answer = rig.shell("echo ALIVE$((40+2))", wait: 1)
            if answer.contains("ALIVE42") { break }
        }
        print("PROBE CANCEL: shell answered after \(String(format: "%.1f", Date().timeIntervalSince(cancelled))) s: \(answer.contains("ALIVE42"))")
        #expect(answer.contains("ALIVE42"))
        _ = rig.shell("rm -f cancel.bin", wait: 0.5)
    }
    /// XMODEM send speed to the device with 128- and 1024-byte blocks.
    @Test func xmodem1KSpeed() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("speed.bin")
        var rng = SystemRandomNumberGenerator()
        let content = Data((0..<512_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        try content.write(to: file)
        for oneK in [false, true] {
            let rig = try Rig(downloads: dir)
            defer { rig.session.close() }
            rig.session.xmodem1K = oneK
            _ = rig.shell("rm -f speed.bin", wait: 0.5)
            let start = Date()
            try rig.session.startTransfer(.xmodemSend(file), startRemote: true)
            let (ok, msg, _) = rig.waitForFinish(300)
            let seconds = Date().timeIntervalSince(start)
            Thread.sleep(forTimeInterval: 1)
            let remote = rig.shell("head -c 512000 speed.bin | md5sum", wait: 1)
            print("PROBE XMODEM\(oneK ? "-1K" : "    "): \(ok) \(msg) \(String(format: "%.1f", seconds)) s = \(Int(Double(content.count) / seconds)) B/s; md5 match \(remote.contains(Insecure_md5(content)))")
        }
        let rig = try Rig(downloads: dir)
        _ = rig.shell("rm -f speed.bin", wait: 0.5)
        rig.session.close()
    }
}

func Insecure_md5(_ data: Data) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/md5")
    p.arguments = ["-q"]
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    try? p.run()
    inPipe.fileHandleForWriting.write(data)
    try? inPipe.fileHandleForWriting.close()
    p.waitUntilExit()
    return String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
