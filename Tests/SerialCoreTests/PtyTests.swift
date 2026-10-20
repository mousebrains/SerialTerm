import Darwin
import Foundation
import Testing
@testable import SerialCore

/// A pseudo-terminal pair standing in for a serial cable: `SerialPort` opens the
/// slave side, and the test plays the remote device on the master side.
final class PtyPair {
    let master: Int32
    let slavePath: String
    private let slave: Int32

    init() throws {
        var m: Int32 = -1, s: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&m, &s, &name, nil, nil) == 0 else { throw POSIXError(.ENOTTY) }
        master = m
        // Keep the slave open so the master doesn't see hangups between opens.
        slave = s
        slavePath = String(cString: name)
    }

    deinit {
        close(master)
        close(slave)
    }

    func writeToPort(_ data: Data) {
        data.withUnsafeBytes { _ = write(master, $0.baseAddress, $0.count) }
    }

    func readFromPort(timeout: TimeInterval) -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { if !out.isEmpty { break } else { continue } }
            let n = read(master, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) }
        }
        return out
    }
}

/// Collects values from callbacks on other threads.
final class Inbox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ t: T) { lock.withLock { items.append(t) } }
    var all: [T] { lock.withLock { items } }

    func wait(timeout: TimeInterval, until done: ([T]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done(all) { return true }
            usleep(10_000)
        }
        return done(all)
    }
}

@Suite(.serialized)
struct SerialPortPtyTests {
    @Test func readsAndWritesThroughPty() throws {
        let pty = try PtyPair()
        let port = SerialPort(path: pty.slavePath, config: SerialConfig(baudRate: 115_200))
        let received = Inbox<Data>()
        port.onData = { received.add($0) }
        try port.open()
        defer { port.close() }

        pty.writeToPort(Data("hello from device\r\n".utf8))
        #expect(received.wait(timeout: 2) { $0.reduce(Data(), +) == Data("hello from device\r\n".utf8) })

        port.write(Data("ATZ\r".utf8))
        port.waitForPendingWrites()
        #expect(pty.readFromPort(timeout: 2) == Data("ATZ\r".utf8))
    }

    @Test func passesBinaryDataUnchanged() throws {
        let pty = try PtyPair()
        let port = SerialPort(path: pty.slavePath, config: SerialConfig())
        let received = Inbox<Data>()
        port.onData = { received.add($0) }
        try port.open()
        defer { port.close() }

        let all = Data((0...255).map(UInt8.init))
        pty.writeToPort(all)
        #expect(received.wait(timeout: 2) { $0.reduce(Data(), +).count >= 256 })
        #expect(received.all.reduce(Data(), +) == all)
    }

    @Test func reportsOpenFailure() {
        let port = SerialPort(path: "/dev/cu.does-not-exist", config: SerialConfig())
        #expect(throws: SerialError.self) { try port.open() }
    }
}

/// End-to-end ZMODEM over a pty, with lrzsz playing the remote side. Skipped if lrzsz isn't installed.
@Suite(.serialized, .enabled(if: ExternalTransfer.findTool(["lsz", "sz"]) != nil, "lrzsz not installed (brew install lrzsz)"))
struct ZmodemEndToEndTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SerialTermTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeFiles(in dir: URL) throws -> [URL] {
        var files: [URL] = []
        for (name, size) in [("one.bin", 100_000), ("two.txt", 1234), ("three.bin", 0), ("four.bin", 300_001)] {
            let url = dir.appendingPathComponent(name)
            try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ name.count) }).write(to: url)
            files.append(url)
        }
        return files
    }

    /// Runs an lrzsz program as the "remote device", relaying its stdio to the pty master.
    /// It gets pipes rather than the master itself: lrzsz changes and flushes its tty's
    /// modes, and on a pty those are shared with our side, which a real remote can't do.
    final class RemoteProgram {
        let process = Process()
        private let stdin = Pipe(), stdout = Pipe()
        private let source: DispatchSourceRead

        init(_ tool: URL, _ args: [String], in dir: URL, pty: PtyPair,
             fromRemote: Mangler? = nil, toRemote: Mangler? = nil) throws {
            process.executableURL = tool
            process.arguments = args
            process.currentDirectoryURL = dir
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            let master = pty.master
            stdout.fileHandleForReading.readabilityHandler = { h in
                let data = fromRemote?.apply(h.availableData) ?? h.availableData
                data.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = write(master, raw.baseAddress! + off, raw.count - off)
                        if n > 0 { off += n } else { usleep(1000) }
                    }
                }
            }
            let stdinHandle = stdin.fileHandleForWriting
            let toRemoteMangler = toRemote
            source = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue(label: "remote"))
            source.setEventHandler {
                var buf = [UInt8](repeating: 0, count: 65_536)
                let n = read(master, &buf, buf.count)
                if let slow = ProcessInfo.processInfo.environment["SERIALTERM_TEST_SLOW_REMOTE_US"], let us = UInt32(slow) {
                    usleep(us)  // simulate a slower machine (CI runners)
                }
                if n > 0 {
                    let d = Data(buf[0..<n])
                    try? stdinHandle.write(contentsOf: toRemoteMangler?.apply(d) ?? d)
                }
            }
            source.resume()
            try process.run()
        }

        func stop() {
            if process.isRunning { process.terminate() }
            stdout.fileHandleForReading.readabilityHandler = nil
            source.cancel()
        }
    }

    func runRemote(_ names: [String], _ args: [String], in dir: URL, pty: PtyPair,
                   fromRemote: Mangler? = nil, toRemote: Mangler? = nil) throws -> RemoteProgram {
        signal(SIGPIPE, SIG_IGN)
        return try RemoteProgram(try #require(ExternalTransfer.findTool(names)), args, in: dir, pty: pty,
                                 fromRemote: fromRemote, toRemote: toRemote)
    }

    /// XMODEM/YMODEM through the lrzsz runner, against lrzsz on the far side of a pty.
    @Test func xmodemReceiveIntoAFolder() throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        let file = try makeFiles(in: src)[0]
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: dst)
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        // A path with a folder used to make lrx refuse with "Security Violation".
        let target = dst.appendingPathComponent("sub dir", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let out = target.appendingPathComponent("received one.bin")
        let remote = try runRemote(["lsx", "sx"], ["-b", file.lastPathComponent], in: src, pty: pty)
        defer { remote.stop() }
        try session.startTransfer(.xmodemReceive(out))

        #expect(events.wait(timeout: 60) { $0.contains { if case .transferFinished = $0 { true } else { false } } })
        for case let .transferFinished(success, message) in events.all { #expect(success, "\(message)") }
        let original = try Data(contentsOf: file)
        let got = try Data(contentsOf: out)
        // XMODEM pads the last 128-byte block with 0x1A.
        #expect(got.prefix(original.count) == original)
        #expect(got.dropFirst(original.count).allSatisfy { $0 == 0x1A })
    }

    @Test func ymodemSendsABatch() throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src)
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: src)
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        let remote = try runRemote(["lrb", "rb"], ["-b"], in: dst, pty: pty)
        defer { remote.stop() }
        try session.startTransfer(.ymodemSend(files))

        #expect(events.wait(timeout: 60) { $0.contains { if case .transferFinished = $0 { true } else { false } } })
        for case let .transferFinished(success, message) in events.all { #expect(success, "\(message)") }
        remote.process.waitUntilExit()
        for f in files where (try Data(contentsOf: f)).count > 0 {
            #expect(try Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent)) == Data(contentsOf: f))
        }
    }

    /// Cancelling an XMODEM send stops the remote receiver promptly. (Over a pty the receiver is
    /// usually between blocks when the abort arrives, so this doesn't reproduce the mid-block case
    /// that the repeated abort exists for; that was seen, and is checked, on real hardware.)
    @Test func cancelStopsRemoteXmodemReceiver() throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        let big = src.appendingPathComponent("big.bin")
        try Data(repeating: 0x55, count: 5_000_000).write(to: big)
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: src)
        let statuses = Inbox<String>()
        session.onEvent = { if case let .transferStatus(s) = $0 { statuses.add(s) } }
        try session.open()
        defer { session.close() }

        let remote = try runRemote(["lrx", "rx"], ["-b", "out.bin"], in: dst, pty: pty)
        defer { remote.stop() }
        try session.startTransfer(.xmodemSend(big))
        #expect(statuses.wait(timeout: 10) { $0.count > 5 })  // well under way
        session.cancelTransfer()

        let deadline = Date().addingTimeInterval(8)
        while remote.process.isRunning && Date() < deadline { usleep(50_000) }
        #expect(!remote.process.isRunning, "remote rx still running after cancel")
    }

    @Test func recognisesLrzszXmodemAnnouncement() throws {
        let pty = try PtyPair()
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: try tempDir())
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }
        // Split across reads, as it may arrive.
        pty.writeToPort(Data("sx data.bin\r\nGive your local XMODEM rec".utf8))
        usleep(50_000)
        pty.writeToPort(Data("eive command now.\r\n".utf8))
        #expect(events.wait(timeout: 5) { $0.contains { if case .remoteXmodemSending = $0 { true } else { false } } })
    }

    /// The workaround settings must still interoperate with a standard implementation.
    @Test(arguments: ["crc16", "window", "small blocks", "escape controls"])
    func workaroundOptionsWorkWithLrzsz(option: String) throws {
        for remoteSends in [false, true] {
            let pty = try PtyPair()
            let src = try tempDir(), dst = try tempDir()
            let files = try makeFiles(in: src)
            var options = ZmodemOptions()
            switch option {
            case "crc16": options.forceCRC16 = true
            case "window": options.window = 4096
            case "small blocks": options.blockSize = 128
            default: options.escapeControls = true
            }
            let traceDir = try tempDir()
            let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()),
                                  downloadDirectory: remoteSends ? dst : src)
            session.zmodemOptions = options
            session.traceDirectory = traceDir
            let events = Inbox<SessionEvent>()
            session.onEvent = { event in
                events.add(event)
                if case .remoteWaitingForFiles = event { try? session.startTransfer(.zmodemSend(files)) }
            }
            try session.open()
            defer { session.close() }

            let remote = remoteSends
                ? try runRemote(["lsz", "sz"], ["-b"] + files.map(\.lastPathComponent), in: src, pty: pty)
                : try runRemote(["lrz", "rz"], ["-b"], in: dst, pty: pty)
            defer { remote.stop() }

            let finished = events.wait(timeout: 60) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
            #expect(finished, "\(option), remote sends: \(remoteSends)")
            for case let .transferFinished(success, message) in events.all {
                #expect(success, "\(option), remote sends: \(remoteSends): \(message)")
            }
            if !remoteSends { remote.process.waitUntilExit() }
            for f in files {
                #expect(try Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent)) == Data(contentsOf: f))
            }
            // Auto-started receives get the remote's opening frame in the trace.
            let trace = try String(contentsOf: try #require(session.lastTraceURL), encoding: .utf8)
            if remoteSends {
                #expect(trace.contains("opening bytes that triggered auto-start"))
                #expect(trace.contains("RX ZRQINIT hex"))
            }
        }
    }

    /// lrzsz on the far side of a line that corrupts data, against the built-in ZMODEM.
    @Test(arguments: ["remote sends", "remote receives"])
    func recoversWithLrzszOverNoisyLine(direction: String) throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        var rng = SystemRandomNumberGenerator()
        var files: [URL] = []
        for (i, size) in [400_000, 150_000].enumerated() {
            let url = src.appendingPathComponent("noisy\(i).bin")
            try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: url)
            files.append(url)
        }
        let noise = Mangler(flipAt: [30_000, 200_000, 200_100, 450_000], dropAt: [320_000: 300])
        let remoteSends = direction == "remote sends"

        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()),
                              downloadDirectory: remoteSends ? dst : src)
        session.traceDirectory = try tempDir()
        let events = Inbox<SessionEvent>()
        session.onEvent = { event in
            events.add(event)
            if case .remoteWaitingForFiles = event { try? session.startTransfer(.zmodemSend(files)) }
        }
        try session.open()
        defer { session.close() }

        let remote = remoteSends
            ? try runRemote(["lsz", "sz"], ["-b"] + files.map(\.lastPathComponent), in: src, pty: pty, fromRemote: noise)
            : try runRemote(["lrz", "rz"], ["-b"], in: dst, pty: pty, toRemote: noise)
        defer { remote.stop() }

        let finished = events.wait(timeout: 120) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
        #expect(finished)
        for case let .transferFinished(success, message) in events.all {
            #expect(success, "\(message)")
            if !success, let url = session.lastTraceURL, let trace = try? String(contentsOf: url, encoding: .utf8) {
                // Make CI failures diagnosable from the log alone.
                print("=== ZMODEM trace (\(direction)) ===\n" + trace.split(separator: "\n").suffix(150).joined(separator: "\n"))
            }
        }
        if !remoteSends { remote.process.waitUntilExit() }
        for f in files {
            #expect(try Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent)) == Data(contentsOf: f))
        }
        // The trace must show the damage and the recovery.
        let trace = try String(contentsOf: try #require(session.lastTraceURL), encoding: .utf8)
        if remoteSends {
            #expect(trace.contains("bad subpacket") && trace.contains("TX ZRPOS"))
        } else {
            #expect(trace.contains("RX ZRPOS") && trace.contains("Resending noisy"))
        }
    }

    @Test(arguments: [false, true])
    func remoteSendsMultipleFilesAutoReceive(useLrzsz: Bool) throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src)

        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: dst)
        session.useExternalZmodem = useLrzsz
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        let remote = try runRemote(["lsz", "sz"], ["-b"] + files.map(\.lastPathComponent), in: src, pty: pty)
        defer { remote.stop() }

        let finished = events.wait(timeout: 30) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
        #expect(finished)
        for case let .transferFinished(success, message) in events.all { #expect(success, "\(message)") }
        for f in files {
            #expect(try Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent)) == Data(contentsOf: f))
        }
    }

    @Test(arguments: [false, true])
    func remoteReceivesMultipleFiles(useLrzsz: Bool) throws {
        let pty = try PtyPair()
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src)

        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig()), downloadDirectory: src)
        session.useExternalZmodem = useLrzsz
        let events = Inbox<SessionEvent>()
        session.onEvent = { event in
            events.add(event)
            // What the app does after the user picks files.
            if case .remoteWaitingForFiles = event { try? session.startTransfer(.zmodemSend(files)) }
        }
        try session.open()
        defer { session.close() }

        let remote = try runRemote(["lrz", "rz"], ["-b"], in: dst, pty: pty)
        defer { remote.stop() }

        let finished = events.wait(timeout: 30) { $0.contains { if case .transferFinished = $0 { true } else { false } } }
        #expect(finished)
        for case let .transferFinished(success, message) in events.all { #expect(success, "\(message)") }
        remote.process.waitUntilExit()
        for f in files {
            #expect(try Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent)) == Data(contentsOf: f))
        }
    }
}
