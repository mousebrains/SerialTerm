// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

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
        #expect(TransferKind.ymodemSend([URL(fileURLWithPath: "/a")]).remoteReceiveCommand == "rb\r")
        #expect(TransferKind.xmodemSend(URL(fileURLWithPath: "/x/it's here.bin")).remoteReceiveCommand
            == "rx 'it'\\''s here.bin'\r")
        #expect(TransferKind.zmodemSend([URL(fileURLWithPath: "/a")]).remoteReceiveCommand == nil)
    }

    /// A newline in a file name used to end the typed `rx` command and run the rest at the
    /// remote's shell; other control characters act on its tty, and on a 7-bit line UTF-8 bytes
    /// such as 0x8A turn into them.
    @Test(arguments: [("fw.bin\nreboot\n", "fw.bin_reboot_"), ("a\rb", "a_b"), ("a\u{03}b", "a_b"),
                      ("a\u{7F}b", "a_b"), ("Ċ.bin", "__.bin"), ("-x\n", "-x_")])
    func typedNamesAreOneLineOfPrintableASCII(name: String, typed: String) {
        #expect(TransferKind.typeable(name) == typed)
        // A URL may hold the name decomposed ("C" and U+0307 for "Ċ"); it's made safe either way.
        let command = TransferKind.xmodemSend(URL(fileURLWithPath: "/x").appendingPathComponent(name)).remoteReceiveCommand
        #expect(command.map { $0.utf8.dropLast().allSatisfy { (0x20...0x7E).contains($0) } } == true, "\(command ?? "")")
        if name == "fw.bin\nreboot\n" { #expect(command == "rx 'fw.bin_reboot_'\r") }
    }

    @Test func fileInfoParsing() {
        let info = ZmodemReceiver.FileInfo(Array("hello.txt".utf8) + [0] + Array("1234 14706755200 100644 0 1 1234".utf8) + [0])
        #expect(info.name == "hello.txt")
        #expect(info.size == 1234)
        #expect(info.modified == Date(timeIntervalSince1970: TimeInterval(Int("14706755200", radix: 8)!)))
        #expect(info.filesLeft == 1)
        // The Slocum's first offer in a 10-file batch.
        let slocum = ZmodemReceiver.FileInfo(Array("02460481.dbd".utf8) + [0] + Array("12659 15244214362 0 0 10 2812909".utf8) + [0])
        #expect(slocum.filesLeft == 10)
        #expect(slocum.bytesLeft == 2_812_909)
        // Senders may stop after the size, or send 0 for "unknown".
        #expect(ZmodemReceiver.FileInfo(Array("a".utf8) + [0] + Array("5".utf8) + [0]).filesLeft == nil)
        #expect(ZmodemReceiver.FileInfo(Array("a".utf8) + [0] + Array("5 0 0 0 0 0".utf8) + [0]).filesLeft == nil)
    }
}

/// Something that alters the bytes going one way on a test line.
protocol LineFilter: AnyObject, Sendable {
    func apply(_ data: Data) -> Data
}

/// Applies filters in turn.
final class FilterChain: LineFilter, @unchecked Sendable {
    private let filters: [any LineFilter]
    init(_ filters: any LineFilter...) { self.filters = filters }
    func apply(_ data: Data) -> Data { filters.reduce(data) { $1.apply($0) } }
}

/// Drops or flips bytes at chosen offsets of a stream, to exercise error recovery.
final class Mangler: LineFilter, @unchecked Sendable {
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

/// Flips the byte `distance` bytes after the nth occurrence of a byte pattern, e.g. to damage
/// the first subpacket after a rewind's ZDATA header.
final class PatternMangler: LineFilter, @unchecked Sendable {
    private let lock = NSLock()
    private let pattern: [UInt8]
    private let occurrence: Int
    private let distance: Int
    private var recent: [UInt8] = []
    private var found = 0
    private var countdown: Int?

    init(after pattern: [UInt8], occurrence: Int, distance: Int) {
        self.pattern = pattern
        self.occurrence = occurrence
        self.distance = distance
    }

    func apply(_ data: Data) -> Data {
        lock.withLock {
            var out = Data(data)
            for i in out.indices {
                let b = out[i]
                if let c = countdown {
                    countdown = c - 1
                    if c == 1 { out[i] = b ^ 0x55; countdown = nil }
                }
                recent.append(b)
                if recent.count > pattern.count { recent.removeFirst() }
                if recent == pattern {
                    found += 1
                    if found == occurrence { countdown = distance }
                }
            }
            return out
        }
    }
}

/// Removes the nth occurrence of a header (its first bytes given by `pattern`) and the
/// `length - pattern.count` bytes after it, e.g. to lose one ZRPOS on the back channel.
final class HeaderDropper: LineFilter, @unchecked Sendable {
    private let lock = NSLock()
    private let pattern: [UInt8]
    private let occurrence: Int
    private let length: Int
    private var recent: [UInt8] = []
    private var found = 0
    private var dropping = 0

    init(_ pattern: [UInt8], occurrence: Int, length: Int) {
        self.pattern = pattern
        self.occurrence = occurrence
        self.length = length
    }

    func apply(_ data: Data) -> Data {
        lock.withLock {
            var out = Data()
            for b in data {
                if dropping > 0 { dropping -= 1; continue }
                out.append(b)
                recent.append(b)
                if recent.count > pattern.count { recent.removeFirst() }
                if recent == pattern {
                    found += 1
                    if found == occurrence {
                        out.removeLast(pattern.count)
                        dropping = length - pattern.count
                    }
                }
            }
            return out
        }
    }
}

/// Damages every subpacket longer than `limit` bytes on the line, as a receiver with a fixed
/// buffer does (a Slocum glider takes at most 1024 data bytes, about 1060 on the line).
final class OversizeSubpacketBreaker: LineFilter, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var run = 0
    private var afterZDLE = false

    init(limit: Int) { self.limit = limit }

    func apply(_ data: Data) -> Data {
        lock.withLock {
            var out = Data(data)
            for i in out.indices {
                let b = out[i]
                if afterZDLE && (0x68...0x6b).contains(b) {
                    run = 0  // ZDLE ZCRCE/G/Q/W ends a subpacket
                } else {
                    run += 1
                    if run == limit { out[i] = b ^ 0x55 }
                }
                afterZDLE = !afterZDLE && b == 0x18
            }
            return out
        }
    }
}

/// Loses the first hex ZRPOS for each position, and passes repeats: a receiver that reports an
/// error and is then silent until prodded, like a Slocum glider overrun at 921600 baud.
final class FirstZRPOSDropper: @unchecked Sendable {
    private let lock = NSLock()
    private static let start = Array("**\u{18}B09".utf8)
    private var pending: [UInt8] = []
    private var seen: Set<[UInt8]> = []

    func apply(_ data: Data) -> Data {
        lock.withLock {
            pending += data
            var out = Data()
            var i = 0
            while i < pending.count {
                let rest = pending[i...]
                if rest.starts(with: Self.start) {
                    guard rest.count >= 21 else { break }  // wait for the whole header
                    let header = Array(rest.prefix(21))
                    let position = Array(header[5..<13])
                    if position != Array("00000000".utf8), !seen.contains(position) {
                        seen.insert(position)
                    } else {
                        out.append(contentsOf: header)
                    }
                    i += 21
                } else if Self.start.starts(with: rest.prefix(Self.start.count)) && rest.count < Self.start.count {
                    break  // could be the start of a header
                } else {
                    out.append(pending[i])
                    i += 1
                }
            }
            pending.removeFirst(i)
            return out
        }
    }
}

func occurrences(of needle: Data, in haystack: Data) -> Int {
    var count = 0
    var from = haystack.startIndex
    while let r = haystack.range(of: needle, in: from..<haystack.endIndex) {
        count += 1
        from = r.upperBound
    }
    return count
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

    /// A ZRPOS for the position the sender just rewound to can be genuine: here the first
    /// subpacket after the rewind is damaged too. The sender takes it for a duplicate, and the
    /// receiver, like lrzsz, ignores the ZEOFs that follow because it still wants that data.
    /// The sender has to work out that the ZRPOS was real; the receiver's long timeout keeps it
    /// from rescuing the transfer by asking again.
    @Test func recoversWhenAGenuineZRPOSLooksLikeADuplicate() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [50_000])
        var senderOptions = ZmodemOptions(), receiverOptions = ZmodemOptions()
        senderOptions.timeout = 0.3
        receiverOptions.timeout = 30
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: senderOptions)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: receiverOptions)
        var e = ZEncoder()
        let zdata = Array(e.binaryHeader(ZHeader(.data, position: 0), crc32: true).prefix(4))
        let firstError = Mangler(flipAt: [5_000])
        let afterRewind = PatternMangler(after: zdata, occurrence: 2, distance: 40)
        sender.onOutput = { receiver.feed(afterRewind.apply(firstError.apply($0))) }
        receiver.onOutput = { sender.feed($0) }
        let logs = Inbox<String>()
        sender.onLog = { logs.add($0) }
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        receiver.onFinish = { results.add(($0, $1)) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 60) { $0.count == 2 })
        #expect(logs.all.contains { $0.contains("duplicate ZRPOS") }, "the scenario didn't happen: \(logs.all)")
        #expect(results.all.allSatisfy { $0.0 }, "\(results.all)")
        try expectSame(files, in: dst)
        #expect(logs.all.contains { $0.contains("no reply to ZEOF after an ignored ZRPOS") })
    }

    /// What a Slocum glider does at 921600 baud: it loses data, asks for a resend, loses data
    /// again, and then goes quiet (here its second ZRPOS is lost). Repeating ZEOF gets nowhere,
    /// since the receiver is waiting for data; resending from the last confirmed position does.
    @Test func recoversWhenTheReceiverGoesQuietAfterAnError() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [50_000])
        var senderOptions = ZmodemOptions(), receiverOptions = ZmodemOptions()
        senderOptions.timeout = 0.3
        receiverOptions.timeout = 60  // the receiver never asks again by itself within the test
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: senderOptions)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: receiverOptions)
        var e = ZEncoder()
        let zdata = Array(e.binaryHeader(ZHeader(.data, position: 0), crc32: true).prefix(4))
        let firstError = Mangler(flipAt: [5_000])
        let afterRewind = PatternMangler(after: zdata, occurrence: 2, distance: 3_000)
        // ZRPOS headers from the receiver: 1st accepts the file, 2nd reports the first error,
        // 3rd reports the damage after the rewind. Lose the 3rd. (Hex header: 21 bytes with XON.)
        let lostZRPOS = HeaderDropper(Array("**\u{18}B09".utf8), occurrence: 3, length: 21)
        sender.onOutput = { receiver.feed(afterRewind.apply(firstError.apply($0))) }
        receiver.onOutput = { sender.feed(lostZRPOS.apply($0)) }
        let logs = Inbox<String>()
        sender.onLog = { logs.add($0) }
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        receiver.onFinish = { results.add(($0, $1)) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 30) { $0.count == 2 })
        #expect(logs.all.contains { $0.contains("resending from the last confirmed position") }, "the scenario didn't happen: \(logs.all)")
        #expect(results.all.allSatisfy { $0.0 }, "\(results.all)")
        try expectSame(files, in: dst)
    }

    /// A receiver that can't take subpackets longer than 1024 bytes (a Slocum glider) only ever asks
    /// for the same position again. A sender set to bigger blocks has to fall back to 1024.
    @Test(arguments: [2048, 8192])
    func fallsBackToStandardBlocksWhenBigOnesAreRejected(blockSize: Int) throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [50_000, 20_000])
        var senderOptions = ZmodemOptions(), receiverOptions = ZmodemOptions()
        senderOptions.timeout = 0.3
        senderOptions.blockSize = blockSize
        receiverOptions.timeout = 30
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: senderOptions)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: receiverOptions)
        let smallBuffer = OversizeSubpacketBreaker(limit: 1_100)
        sender.onOutput = { receiver.feed(smallBuffer.apply($0)) }
        receiver.onOutput = { sender.feed($0) }
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
        #expect(logs.all.contains { $0.contains("1024-byte blocks") }, "\(logs.all.suffix(8))")
        // Only the first file needed the fall back; the second starts with 1024-byte blocks.
        #expect(logs.all.filter { $0.contains("1024-byte blocks") }.count == 1)
    }

    /// The glider at 921600 does that over and over: each burst overruns it and it goes quiet
    /// again, a little further on. Prodding must keep going while it makes progress.
    @Test func keepsProddingAReceiverThatKeepsGoingQuiet() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [60_000])
        var senderOptions = ZmodemOptions(), receiverOptions = ZmodemOptions()
        senderOptions.timeout = 0.3
        receiverOptions.timeout = 60
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, options: senderOptions)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: receiverOptions)
        var e = ZEncoder()
        let zdata = Array(e.binaryHeader(ZHeader(.data, position: 0), crc32: true).prefix(4))
        // ZDATA headers alternate: data (damaged here), then a prod the receiver answers with its
        // position, then the data from there (damaged again), and so on, five times.
        let manglers = [1, 3, 5, 7, 9].map { PatternMangler(after: zdata, occurrence: $0, distance: 2_500) }
        let silent = FirstZRPOSDropper()
        sender.onOutput = { d in receiver.feed(manglers.reduce(d) { $1.apply($0) }) }
        receiver.onOutput = { d in sender.feed(silent.apply(d)) }
        let logs = Inbox<String>()
        sender.onLog = { logs.add($0) }
        let results = Inbox<(Bool, String)>()
        sender.onFinish = { results.add(($0, $1)) }
        receiver.onFinish = { results.add(($0, $1)) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 60) { $0.count == 2 })
        let prods = logs.all.filter { $0.contains("resending from the last confirmed position") }.count
        #expect(prods > 3, "only \(prods) prods: \(logs.all)")
        #expect(results.all.allSatisfy { $0.0 }, "\(results.all)")
        try expectSame(files, in: dst)
    }

    /// A ZEOF for data the receiver doesn't have yet is ignored, but it mustn't restart the
    /// receiver's timeout: a sender repeating ZEOF faster than that would keep it from ever
    /// asking for the data again.
    @Test func staleZEOFsDontPostponeTheReceiversTimeout() throws {
        let dst = try tempDir()
        var options = ZmodemOptions()
        options.timeout = 0.5
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst, options: options)
        let out = Inbox<Data>()
        receiver.onOutput = { out.add($0) }
        let results = Inbox<(Bool, String)>()
        receiver.onFinish = { results.add(($0, $1)) }
        try receiver.start()
        #expect(out.wait(timeout: 5) { !$0.isEmpty })  // its ZRINIT

        var e = ZEncoder()
        let info = Array("stale.bin".utf8) + [0] + Array("1000 0 100644 0 1 1000".utf8) + [0]
        receiver.feed(Data(e.binaryHeader(ZHeader(.file, zf0: Z.convBinary), crc32: true)
            + e.subpacket(Data(info), end: Z.crcW, crc32: true)))
        for _ in 0..<8 {
            usleep(300_000)
            receiver.feed(Data(e.binaryHeader(ZHeader(.eof, position: 1000), crc32: true)))
        }
        let asks = occurrences(of: Data("**\u{18}B09".utf8), in: out.all.reduce(Data(), +))
        receiver.cancel()
        #expect(results.wait(timeout: 10) { $0.count == 1 })
        // One ZRPOS accepts the offer; over 2.4 s with a 0.5 s timeout it should ask again ~4 times.
        #expect(asks >= 3, "receiver sent ZRPOS \(asks) times")
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

    @Test func progressCountsFilesInTheBatch() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [3000, 10, 5000])
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst)
        sender.onOutput = { receiver.feed($0) }
        receiver.onOutput = { sender.feed($0) }
        let results = Inbox<Bool>()
        sender.onFinish = { ok, _ in results.add(ok) }
        receiver.onFinish = { ok, _ in results.add(ok) }
        let sent = Inbox<String>(), received = Inbox<String>()
        sender.onStatus = { sent.add($0) }
        receiver.onStatus = { received.add($0) }

        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 10) { $0.count == 2 })
        // 8010 bytes in all: file 1 ends at 37%, file 2 at 37% (10 bytes), file 3 at 100%.
        let total = ZLink.size(8010)
        for (lines, verb) in [(received.all, "Received"), (sent.all, "Sent")] {
            for (i, percent) in [(1, 37), (2, 37), (3, 100)] {
                let prefix = "\(i)/3, \(percent)% of \(total) · \(verb) file\(i - 1).bin"
                #expect(lines.contains { $0.hasPrefix(prefix) }, "\(prefix) in \(lines)")
            }
        }
    }

    @Test(arguments: ["rz", "zr", ""])
    func senderTypesTheReceiveCommand(command: String) throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [100])
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst, receiveCommand: command)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst)
        let sent = Inbox<Data>()
        sender.onOutput = { sent.add($0); receiver.feed($0) }
        receiver.onOutput = { sender.feed($0) }
        let results = Inbox<Bool>()
        sender.onFinish = { ok, _ in results.add(ok) }
        receiver.onFinish = { ok, _ in results.add(ok) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 10) { $0.count == 2 })
        #expect(results.all.allSatisfy { $0 })  // the receiver skips the command as noise
        let start = sent.all.reduce(Data(), +).prefix(5)
        let expected = command.isEmpty ? Data("**".utf8) : Data((command + "\r").utf8)
        #expect(start.starts(with: expected), "began \(Array(start))")
    }

    @Test func timeLeftAppearsOnASlowLink() throws {
        let src = try tempDir(), dst = try tempDir()
        let files = try makeFiles(in: src, sizes: [150_000, 150_000, 150_000])
        let sender = ZmodemTransfer(kind: .zmodemSend(files), directory: dst)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst)
        // About 150 KB/s, so the batch takes a few seconds.
        sender.onOutput = { usleep(UInt32($0.count) * 6); receiver.feed($0) }
        receiver.onOutput = { sender.feed($0) }
        let results = Inbox<Bool>()
        sender.onFinish = { ok, _ in results.add(ok) }
        receiver.onFinish = { ok, _ in results.add(ok) }
        let received = Inbox<String>()
        receiver.onStatus = { received.add($0) }
        try receiver.start()
        try sender.start()
        #expect(results.wait(timeout: 30) { $0.count == 2 })
        #expect(results.all.allSatisfy { $0 })
        let estimates = received.all.filter { $0.contains(" left · ") }
        #expect(!estimates.isEmpty, "no time-left estimate in \(received.all.suffix(5))")
        // Never shown once nothing is left.
        #expect(!received.all.contains { $0.hasPrefix("3/3, 100%") && $0.contains(" left") })
    }

    @Test func timeLeft() {
        // The 10-file Slocum batch after its first file: 2.8 MB to go at 40 KB/s, 9 files to
        // start, 0.9 s between files.
        let t = ZLink.estimate(bytesLeft: 2_800_250, rate: 40_000, filesAfter: 9, gap: 0.9)
        #expect(abs(t - 78.1) < 0.1)
        #expect(ZLink.duration(t) == "1 min 18 s")
        #expect(ZLink.duration(0.2) == "1 s")
        #expect(ZLink.duration(44.6) == "45 s")
        #expect(ZLink.duration(3725) == "1 h 02 min")
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

struct ZmodemTraceTests {
    /// The last reference to a trace is usually dropped by one of its own queued writes, so
    /// deinit runs on the trace queue. It used to `sync` onto that queue and crash the app.
    @Test func releasedWhileWritesAreQueued() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<20 {
            let url = dir.appendingPathComponent("trace\(i).log")
            var trace: ZmodemTrace? = try ZmodemTrace(url: url, level: .verbose)
            weak let released = trace
            for n in 0..<2000 { trace?.note("line \(n)") }
            trace = nil  // the queued writes now hold the only references
            let deadline = Date().addingTimeInterval(10)
            while released != nil, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            #expect(released == nil)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.split(separator: "\n").count == 2000)
        }
    }
}
