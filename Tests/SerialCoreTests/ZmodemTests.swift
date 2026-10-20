import Foundation
import Testing
@testable import SerialCore

struct ZmodemCodecTests {
    @Test func crcCheckValues() {
        let check = Array("123456789".utf8)
        #expect(CRC.crc16(check) == 0x31C3)       // CRC-16/XMODEM
        #expect(CRC.crc32(check) == 0xCBF4_3926)  // CRC-32/IEEE
    }

    @Test func hexHeaderMatchesLrzsz() {
        // What `sz` sends to start a session.
        var e = ZEncoder()
        let bytes = e.hexHeader(ZHeader(.rqinit))
        #expect(bytes == Array("**\u{18}B00000000000000\r".utf8) + [0x8A, 0x11])
    }

    func roundTrip(_ bytes: [UInt8]) -> ZReader {
        let ch = ByteChannel()
        ch.append(Data(bytes))
        return ZReader(ch)
    }

    @Test(arguments: [false, true])
    func binaryHeaderRoundTrip(crc32: Bool) throws {
        var e = ZEncoder()
        let h = ZHeader(.data, position: 0x1318_1100)  // bytes that all need escaping
        let r = roundTrip(Array("noise*".utf8) + e.binaryHeader(h, crc32: crc32))
        let got = try #require(try r.readHeader(timeout: 1))
        #expect(got.type == h.type && got.p == h.p && got.crc32 == crc32)
        #expect(got.position == 0x1318_1100)
    }

    @Test func hexHeaderRoundTrip() throws {
        var e = ZEncoder()
        let h = ZHeader(.rinit, zf0: Z.canFDX | Z.canOVIO | Z.canFC32)
        let got = try #require(try roundTrip(e.hexHeader(h)).readHeader(timeout: 1))
        #expect(got.frame == .rinit && got.zf0 == h.zf0)
    }

    @Test(arguments: [false, true])
    func subpacketRoundTripAllBytes(crc32: Bool) throws {
        var e = ZEncoder()
        let data = (0...255).map(UInt8.init) + Array("@\r@\u{8D}".utf8)
        let r = roundTrip(e.subpacket(data, end: Z.crcG, crc32: crc32))
        guard case let .data(got, end) = try r.readSubpacket(crc32: crc32, timeout: 1) else {
            Issue.record("bad subpacket")
            return
        }
        #expect(got == data)
        #expect(end == Z.crcG)
    }

    @Test func encodedDataHasNoBareControlBytes() {
        var e = ZEncoder()
        let out = e.subpacket((0...255).map(UInt8.init), end: Z.crcE, crc32: true)
        for b in [0x10, 0x11, 0x13, 0x90, 0x91, 0x93] as [UInt8] { #expect(!out.contains(b)) }
    }

    @Test func detectsCorruptSubpacket() throws {
        var e = ZEncoder()
        var bytes = e.subpacket(Array(repeating: 0x41, count: 100), end: Z.crcE, crc32: true)
        bytes[50] ^= 0x01
        guard case .bad = try roundTrip(bytes).readSubpacket(crc32: true, timeout: 1) else {
            Issue.record("corruption not detected")
            return
        }
    }

    @Test func fiveCANsAbort() {
        let r = roundTrip([0x41] + Array(repeating: Z.can, count: 5))
        #expect(throws: ZmodemError.remoteCancelled) { _ = try r.readHeader(timeout: 1) }
    }

    @Test func safeFileNames() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(ZmodemReceiver.uniqueURL(in: dir, for: "../../etc/passwd").lastPathComponent == "passwd")
        #expect(ZmodemReceiver.uniqueURL(in: dir, for: ".bashrc").lastPathComponent == "bashrc")
        #expect(ZmodemReceiver.uniqueURL(in: dir, for: "C:\\temp\\a.txt").lastPathComponent == "a.txt")
        #expect(ZmodemReceiver.uniqueURL(in: dir, for: "").lastPathComponent == "received")
    }

    @Test func frameNames() {
        #expect(ZFrameType.rqinit.description == "ZRQINIT")
        #expect(ZFrameType.stderr.description == "ZSTDERR")
        #expect(ZHeader(.rpos, position: 4096).traceDescription == "ZRPOS hex  pos=4096")
    }

    @Test func remoteReceiveCommands() {
        #expect(ExternalTransfer.remoteReceiveCommand(for: .ymodemSend([URL(fileURLWithPath: "/a")])) == "rb\r")
        #expect(ExternalTransfer.remoteReceiveCommand(for: .xmodemSend(URL(fileURLWithPath: "/x/it's here.bin")))
            == "rx 'it'\\''s here.bin'\r")
        #expect(ExternalTransfer.remoteReceiveCommand(for: .zmodemSend([URL(fileURLWithPath: "/a")])) == nil)
    }

    @Test func fileInfoParsing() {
        let info = ZmodemReceiver.FileInfo(Array("hello.txt".utf8) + [0] + Array("1234 14706755200 100644 0 1 1234".utf8) + [0])
        #expect(info.name == "hello.txt")
        #expect(info.size == 1234)
        #expect(info.modified == Date(timeIntervalSince1970: TimeInterval(Int("14706755200", radix: 8)!)))
    }
}

/// Drops or flips bytes at chosen offsets of a stream, to exercise error recovery.
final class Mangler: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    private var flips: Set<Int>
    private var drops: [Int: Int]  // offset → count

    init(flipAt: [Int] = [], dropAt: [Int: Int] = [:]) {
        flips = Set(flipAt)
        drops = dropAt
    }

    func apply(_ data: Data) -> Data {
        lock.withLock {
            var out = Data()
            out.reserveCapacity(data.count)
            var skip = 0
            for b in data {
                defer { seen += 1 }
                if skip > 0 { skip -= 1; continue }
                if let n = drops[seen] { skip = n - 1; continue }
                out.append(flips.contains(seen) ? b ^ 0x55 : b)
            }
            return out
        }
    }
}

@Suite(.serialized)
struct ZmodemNativeTransferTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZmodemTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeFiles(in dir: URL, sizes: [Int]) throws -> [URL] {
        var rng = SystemRandomNumberGenerator()
        return try sizes.enumerated().map { i, size in
            let url = dir.appendingPathComponent("file\(i).bin")
            try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: url)
            return url
        }
    }

    /// Connects a native sender and receiver back to back, optionally through manglers.
    func transfer(_ files: [URL], into dst: URL, forward: Mangler? = nil, back: Mangler? = nil,
                  timeout: TimeInterval = 1, logs: Inbox<String>? = nil) throws -> (send: (Bool, String), receive: (Bool, String)) {
        var options = ZmodemOptions()
        options.timeout = timeout
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: options)
        sender.onOutput = { receiver.feed(forward?.apply($0) ?? $0) }
        receiver.onOutput = { sender.feed(back?.apply($0) ?? $0) }
        let results = Inbox<(String, Bool, String)>()
        sender.onFinish = { results.add(("send", $0, $1)) }
        receiver.onFinish = { results.add(("receive", $0, $1)) }
        sender.onLog = { logs?.add("send: " + $0) }
        receiver.onLog = { logs?.add("recv: " + $0) }

        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 60) { $0.count == 2 })
        let s = results.all.first { $0.0 == "send" }.map { ($0.1, $0.2) } ?? (false, "no result")
        let r = results.all.first { $0.0 == "receive" }.map { ($0.1, $0.2) } ?? (false, "no result")
        return (s, r)
    }

    func expectSame(_ files: [URL], in dst: URL) throws {
        for f in files {
            let got = try Data(contentsOf: dst.appendingPathComponent(f.lastPathComponent))
            #expect(got == (try Data(contentsOf: f)), "\(f.lastPathComponent) differs")
        }
    }

    @Test func cleanMultiFileTransfer() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [0, 1, 1023, 1024, 1025, 70_000, 1_500_000])
        let (s, r) = try transfer(files, into: dst)
        #expect(s.0, "\(s.1)")
        #expect(r.0, "\(r.1)")
        #expect(r.1.hasPrefix("Received 7 files"))
        try expectSame(files, in: dst)
    }

    @Test func recoversFromCorruptedAndDroppedData() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [300_000, 200_000])
        let forward = Mangler(flipAt: [5_000, 120_000, 120_500, 410_000], dropAt: [250_000: 37, 480_000: 2000])
        let logs = Inbox<String>()
        let (s, r) = try transfer(files, into: dst, forward: forward, logs: logs)
        #expect(s.0, "\(s.1)")
        #expect(r.0, "\(r.1)")
        try expectSame(files, in: dst)
        // Every injected fault should have caused a resend request that the sender honoured.
        let resends = logs.all.filter { $0.hasPrefix("send: Resending ") }
        #expect(resends.count >= 5, "\(logs.all.joined(separator: "\n"))")
    }

    @Test func recoversFromCorruptedBackChannel() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [100_000, 50_000])
        // Damage data and the receiver's ZRPOS replies.
        let forward = Mangler(flipAt: [20_000, 90_000])
        let back = Mangler(flipAt: [40, 60, 100])
        let logs = Inbox<String>()
        let (s, r) = try transfer(files, into: dst, forward: forward, back: back, logs: logs)
        #expect(logs.all.contains { $0.hasPrefix("recv:") && $0.contains("asking for data") })
        #expect(s.0, "\(s.1)")
        #expect(r.0, "\(r.1)")
        try expectSame(files, in: dst)
    }

    /// lrzsz's receiver repeats ZRPOS while it skips in-flight garbage. Each repeat must not
    /// trigger another rewind, or the extra ZDATA headers break the resumed stream and errors
    /// snowball (seen on CI as "Too many errors").
    @Test func toleratesDuplicateZRPOS() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [400_000])
        var options = ZmodemOptions()
        options.timeout = 1
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: options)
        let forward = Mangler(flipAt: [60_000, 150_000, 260_000])
        sender.onOutput = { receiver.feed(forward.apply($0)) }
        // Deliver every ZRPOS the receiver sends three times, like lrzsz does.
        let zrposHex = Data("**\u{18}B09".utf8)
        receiver.onOutput = { data in
            sender.feed(data)
            if data.range(of: zrposHex) != nil {
                sender.feed(data)
                sender.feed(data)
            }
        }
        let logs = Inbox<String>()
        sender.onLog = { logs.add($0) }
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        receiver.onFinish = { results.add(($0, $1)) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 60) { $0.count == 2 })
        #expect(results.all.allSatisfy { $0.0 }, "\(results.all)")
        try expectSame(files, in: dst)
        let rewinds = logs.all.filter { $0.hasPrefix("Resending ") }.count
        #expect(rewinds <= 6, "3 faults should need about 3 rewinds, got \(rewinds)")
        #expect(logs.all.contains { $0.contains("duplicate ZRPOS") })
    }

    @Test func doesNotOverwriteExistingFiles() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [500])
        try Data("keep me".utf8).write(to: dst.appendingPathComponent("file0.bin"))
        let (_, r) = try transfer(files, into: dst)
        #expect(r.0)
        #expect(try Data(contentsOf: dst.appendingPathComponent("file0.bin")) == Data("keep me".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("file0 (1).bin")) == Data(contentsOf: files[0]))
    }

    @Test func localCancelStopsBothSidesAndRemovesPartialFile() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [4_000_000])
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst)
        // A slow link, so there's time to cancel mid-file.
        sender.onOutput = { usleep(2000); receiver.feed($0) }
        receiver.onOutput = { sender.feed($0) }
        let results = Inbox<(String, Bool, String)>()
        sender.onFinish = { results.add(("send", $0, $1)) }
        receiver.onFinish = { results.add(("receive", $0, $1)) }
        let progress = Inbox<String>()
        receiver.onStatus = { progress.add($0) }

        try receiver.start()
        try sender.start()
        #expect(progress.wait(timeout: 10) { $0.count > 3 })
        receiver.cancel()
        #expect(results.wait(timeout: 10) { $0.count == 2 })
        #expect(results.all.allSatisfy { !$0.1 })
        #expect(results.all.contains { $0.0 == "receive" && $0.2 == "Cancelled" })
        #expect(results.all.contains { $0.0 == "send" && $0.2 == "Cancelled by the remote" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).isEmpty)
    }

    @Test func senderGivesUpWithoutReceiver() throws {
        let src = try tempDir()
        let files = try makeFiles(in: src, sizes: [10])
        var options = ZmodemOptions()
        options.timeout = 0.1
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: src, options: options)
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        try sender.start()
        #expect(results.wait(timeout: 5) { !$0.isEmpty })
        #expect(results.all.first?.0 == false)
    }
}

@Suite(.serialized)
struct ZmodemDiagnosticsTests {
    let helper = ZmodemNativeTransferTests()

    /// Runs native sender → native receiver with tracing; returns both traces.
    /// `fill`: use this byte for file contents instead of random data, so stream offsets are predictable.
    func traced(_ sizes: [Int], options: ZmodemOptions, forward: Mangler? = nil, fill: UInt8? = nil) throws -> (send: String, receive: String) {
        let src = try helper.tempDir(), dst = try helper.tempDir()
        var files = try helper.makeFiles(in: src, sizes: sizes)
        if let fill {
            for (f, n) in zip(files, sizes) { try Data(repeating: fill, count: n).write(to: f) }
            files = files.map { $0 }
        }
        let sendTrace = src.appendingPathComponent("send.trace"), recvTrace = src.appendingPathComponent("recv.trace")
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: options, traceURL: sendTrace)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: options, traceURL: recvTrace)
        sender.onOutput = { receiver.feed(forward?.apply($0) ?? $0) }
        receiver.onOutput = { sender.feed($0) }
        let done = Inbox<Bool>()
        sender.onFinish = { ok, _ in done.add(ok) }
        receiver.onFinish = { ok, _ in done.add(ok) }
        try receiver.start()
        try sender.start()
        #expect(done.wait(timeout: 60) { $0.count == 2 })
        #expect(done.all.allSatisfy { $0 })
        try helper.expectSame(files, in: dst)
        return (try String(contentsOf: sendTrace, encoding: .utf8), try String(contentsOf: recvTrace, encoding: .utf8))
    }

    @Test func frameTraceShowsHandshakeFilesAndSummary() throws {
        var options = ZmodemOptions()
        options.timeout = 1
        let (send, recv) = try traced([5000, 0], options: options)
        #expect(recv.contains("TX ZRINIT hex  caps=CANFDX|CANOVIO|CANFC32 buffer=0 (stream)"))
        #expect(send.contains("RX ZRINIT hex"))
        #expect(send.contains("TX ZFILE bin32  conv=binary"))
        #expect(recv.contains("RX ZFILE bin32  conv=binary"))
        #expect(recv.contains("file \"file0.bin\" fields \"5000 "))
        #expect(recv.contains("RX ZDATA bin32  pos=0"))
        #expect(recv.contains("data 0..<5000 (5000 bytes)"))
        #expect(send.contains("RX ZFIN"))
        #expect(send.contains("summary: OK: Sent 2 files"))
        #expect(recv.contains("summary: OK: Received 2 files"))
        #expect(!recv.contains("RX raw ") && !recv.contains("TX raw "))  // raw dumps only at verbose level
        // Every line starts with a timestamp and elapsed time.
        let stamped = #/^\d{2}:\d{2}:\d{2}\.\d{3} \+\d+\.\d{3}  (RX|TX|--) /#
        for line in recv.split(separator: "\n") where !line.hasPrefix(" ") {
            #expect(String(line).firstMatch(of: stamped) != nil, "\(line)")
        }
    }

    @Test func traceRecordsErrorsAndRecovery() throws {
        var options = ZmodemOptions()
        options.timeout = 1
        // 'A' fill keeps offsets predictable, so the flip always lands in plain payload.
        let (send, recv) = try traced([200_000], options: options, forward: Mangler(flipAt: [50_000]), fill: 0x41)
        #expect(recv.contains("bad subpacket: CRC-32 mismatch"))
        #expect(recv.contains("TX ZRPOS hex  pos="))
        #expect(send.contains("RX ZRPOS hex  pos="))
        #expect(send.contains("Resending file0.bin from"))
        #expect(recv.contains("1 bad subpackets"))
        // The failure comes with a snapshot of the raw bytes and the reads they arrived in.
        #expect(recv.contains("error snapshot: subpacket started at stream offset"))
        #expect(recv.contains("serial reads (offset, bytes, arrival, gap since previous read):"))
        #expect(recv.contains("← in failed subpacket"))
    }

    @Test func snapshotShowsDroppedBytes() throws {
        var options = ZmodemOptions()
        options.timeout = 1
        // Drop 512 bytes, like a lost USB packet. With 'A' fill every subpacket is 1030 raw bytes, so
        // offsets are predictable: 40_300 is ~30 bytes into a subpacket, 41_070 is ~800 bytes in.
        // Inside one subpacket the failed one is short; across a frame end two merge into a long one.
        // Either way the length is wrong, unlike a damaged byte (~1030–1100).
        let inside = try droppedSubpacketLength(at: 40_300, options: options)
        #expect(inside < 700, "drop inside a subpacket: \(inside)")
        let across = try droppedSubpacketLength(at: 41_070, options: options)
        #expect(across > 1300, "drop across a frame end: \(across)")
    }

    func droppedSubpacketLength(at: Int, options: ZmodemOptions) throws -> Int {
        let (_, recv) = try traced([100_000], options: options, forward: Mangler(dropAt: [at: 512]), fill: 0x41)
        let snapshot = try #require(recv.components(separatedBy: "error snapshot: ").dropFirst().first)
        return try #require(Int(snapshot.firstMatch(of: #/\((\d+) raw bytes/#)?.1 ?? ""))
    }

    @Test func verboseTraceDumpsRawBytes() throws {
        var options = ZmodemOptions()
        options.timeout = 1
        options.traceLevel = .verbose
        let (send, recv) = try traced([3000], options: options)
        #expect(recv.contains("RX raw "))
        #expect(send.contains("TX raw "))
        #expect(recv.contains("subpacket 1024 bytes, ZCRCG, CRC-32 ok"))
        #expect(send.contains("|**.B00000000000000.|") || send.contains("2a 2a 18 42 30 30"))
    }

    @Test func workaroundOptionsChangeTheWireFormat() throws {
        var options = ZmodemOptions()
        options.timeout = 1
        options.forceCRC16 = true
        options.window = 2048
        options.blockSize = 256
        options.escapeControls = true
        options.traceLevel = .verbose
        let (send, recv) = try traced([10_000], options: options)
        #expect(recv.contains("TX ZRINIT hex  caps=CANFDX|CANOVIO|ESCCTL buffer=0"))
        #expect(send.contains("using CRC-16, ACK every 2048 bytes, block 256, escaping control characters"))
        #expect(send.contains("TX ZFILE bin16"))
        #expect(send.contains("subpacket 256 bytes, ZCRCW, CRC-16"))
        #expect(recv.contains("TX ZACK hex  pos=2048"))
    }
}
