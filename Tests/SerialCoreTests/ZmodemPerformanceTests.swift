import Foundation
import Testing
@testable import SerialCore

/// Throughput checks for the ZMODEM encoder and a full in-memory transfer. They print MB/s and fail only
/// if performance drops far below what a fast USB link (~10 MB/s) needs.
#if DEBUG
private let optimized = false
#else
private let optimized = true
#endif

/// Run with `swift test -c release --filter ZmodemPerformanceTests`; debug builds are far slower.
@Suite(.serialized, .enabled(if: optimized, "performance thresholds apply to release builds"))
struct ZmodemPerformanceTests {
    static let payload: Data = {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<16_000_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }()

    @Test func encoderThroughput() {
        var e = ZEncoder()
        let data = Self.payload
        let start = Date()
        var total = 0
        var pos = 0
        while pos < data.count {
            let n = min(1024, data.count - pos)
            total += e.subpacket(data[pos..<pos + n], end: Z.crcG, crc32: true).count
            pos += n
        }
        let rate = Double(data.count) / Date().timeIntervalSince(start) / 1e6
        print("ENCODER: \(String(format: "%.1f", rate)) MB/s (\(total) bytes out)")
        #expect(rate > 40)
    }

    @Test func endToEndThroughput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("big.bin")
        try Self.payload.write(to: src)
        let dst = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let sender = ZmodemTransfer(kind: .zmodemSend([src]), directory: dst)
        let receiver = ZmodemTransfer(kind: .zmodemReceive, directory: dst)
        sender.onOutput = { receiver.feed($0) }
        receiver.onOutput = { sender.feed($0) }
        let done = Inbox<Bool>()
        sender.onFinish = { ok, _ in done.add(ok) }
        receiver.onFinish = { ok, _ in done.add(ok) }
        let start = Date()
        try receiver.start()
        try sender.start()
        #expect(done.wait(timeout: 120) { $0.count == 2 })
        let rate = Double(Self.payload.count) / Date().timeIntervalSince(start) / 1e6
        print("END-TO-END: \(String(format: "%.1f", rate)) MB/s")
        #expect(try Data(contentsOf: dst.appendingPathComponent("big.bin")) == Self.payload)
        #expect(rate > 15)
    }
}
