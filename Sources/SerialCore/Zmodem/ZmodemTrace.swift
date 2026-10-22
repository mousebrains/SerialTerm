// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Tuning and diagnostics for the built-in ZMODEM. The defaults suit lrzsz-like peers;
/// the knobs exist for implementations with quirks.
public struct ZmodemOptions: Codable, Equatable, Sendable {
    public enum TraceLevel: String, Codable, CaseIterable, Sendable {
        case off
        /// Every header, file offer, error, retry and decision; data subpackets summarised.
        case frames
        /// Also every data subpacket and a hex dump of all raw bytes in both directions.
        case verbose
    }

    public var traceLevel: TraceLevel = .frames
    /// Data bytes per subpacket when sending (lrzsz uses 1024).
    public var blockSize = 1024
    /// When sending, wait for an acknowledgement every this many bytes (ZCRCW) even if the
    /// receiver says it can stream. 0 = do what the receiver advertises.
    public var window = 0
    /// Never use CRC-32, in either direction.
    public var forceCRC16 = false
    /// Escape all control characters (sending), and ask the sender to do the same (receiving).
    public var escapeControls = false
    /// Seconds to wait for the remote before retrying.
    public var timeout: Double = 10

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ZmodemOptions()
        traceLevel = (try? c.decode(TraceLevel.self, forKey: .traceLevel)) ?? d.traceLevel
        blockSize = (try? c.decode(Int.self, forKey: .blockSize)) ?? d.blockSize
        window = (try? c.decode(Int.self, forKey: .window)) ?? d.window
        forceCRC16 = (try? c.decode(Bool.self, forKey: .forceCRC16)) ?? d.forceCRC16
        escapeControls = (try? c.decode(Bool.self, forKey: .escapeControls)) ?? d.escapeControls
        timeout = (try? c.decode(Double.self, forKey: .timeout)) ?? d.timeout
    }

    public var summary: String {
        "block \(blockSize), window \(window == 0 ? "auto" : "\(window)"), CRC \(forceCRC16 ? "16 forced" : "auto"), "
            + "escape controls \(escapeControls ? "on" : "off"), timeout \(timeout)s"
    }
}

/// Writes a human-readable protocol trace of one ZMODEM transfer.
///
///     10:32:01.123 +0.000  -- ZMODEM receive; block 1024, window auto, ...
///     10:32:01.130 +0.007  RX ZRQINIT hex  zf0=00 zf1=00 zf2=00 zf3=00
///     10:32:01.131 +0.008  TX ZRINIT hex  caps=CANFDX|CANOVIO|CANFC32 buffer=0 (stream)
///     10:32:01.140 +0.017  RX ZFILE bin32  conv=binary mgmt=0 transport=0
///     10:32:01.140 +0.017  RX   file "DAT_001.P" 120000 bytes, mtime 2026-10-20 10:00:00 +0000, mode 100644
///
/// Calls may come from the serial queue (raw input) and the protocol thread; writes are serialised.
public final class ZmodemTrace: @unchecked Sendable {
    public enum Direction: String {
        case rx = "RX"
        case tx = "TX"
        case note = "--"
    }

    /// The trace file. If the requested name was taken, this is the "-2", "-3"… variant used instead.
    public let url: URL
    public let level: ZmodemOptions.TraceLevel
    /// Called once, on the trace's queue, if a write fails (disk full, volume gone). The trace
    /// stops there.
    var onFailure: ((Error) -> Void)?
    let file: LogFile  // internal for tests
    private let queue = DispatchQueue(label: "ZmodemTrace")
    private let start = Date()
    private let formatter: DateFormatter

    // Counters for the closing summary (protocol thread only).
    var headersIn = 0, headersOut = 0
    var badHeaders = 0, badSubpackets = 0
    var garbageBytes = 0
    var timeouts = 0
    var rposIn = 0, rposOut = 0
    var naksIn = 0, naksOut = 0  // XMODEM/YMODEM
    var dataBytesIn = 0, dataBytesOut = 0
    var subpacketsIn = 0, subpacketsOut = 0
    // Raw byte counts: received bytes are counted on the serial queue, so these are locked.
    private let rawLock = NSLock()
    private var rawIn = 0, rawOut = 0
    var rawBytesIn: Int { rawLock.withLock { rawIn } }
    var rawBytesOut: Int { rawLock.withLock { rawOut } }

    /// Starts a new trace at `url`, or at a "-2", "-3"… variant if that name is taken.
    public init(url: URL, level: ZmodemOptions.TraceLevel) throws {
        file = try LogFile(creatingNewFileAt: url)
        self.url = file.url
        self.level = level
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    /// "SerialTerm-2026-10-20-103201-zmodem.log"; `protocolName` as in `TransferKind.protocolName`.
    public static func defaultFileName(for date: Date = Date(), protocolName: String = "zmodem") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SerialTerm-\(f.string(from: date))-\(protocolName).log"
    }

    var verbose: Bool { level == .verbose }

    func line(_ dir: Direction, _ text: String) {
        let now = Date()
        queue.async { [self] in
            let stamp = String(format: "%@ +%.3f", formatter.string(from: now), now.timeIntervalSince(start))
            if let error = file.write(Data("\(stamp)  \(dir.rawValue) \(text)\n".utf8)) { onFailure?(error) }
        }
    }

    func note(_ text: String) { line(.note, text) }

    func header(_ dir: Direction, _ h: ZHeader) {
        if dir == .rx { headersIn += 1 } else { headersOut += 1 }
        if h.frame == .rpos { if dir == .rx { rposIn += 1 } else { rposOut += 1 } }
        line(dir, h.traceDescription)
    }

    /// Raw bytes as hex + ASCII, 32 per line. Verbose level only.
    func raw(_ dir: Direction, _ data: Data) {
        rawLock.withLock { if dir == .rx { rawIn += data.count } else { rawOut += data.count } }
        guard verbose, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        var text = "raw \(bytes.count) bytes"
        for i in stride(from: 0, to: bytes.count, by: 32) {
            text += "\n        " + Self.hexLine(bytes[i..<min(i + 32, bytes.count)])
        }
        line(dir, text)
    }

    static func hexLine(_ bytes: ArraySlice<UInt8>) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = String(bytes.map { $0 >= 0x20 && $0 < 0x7F ? Character(Unicode.Scalar($0)) : "." })
        return hex.padding(toLength: 32 * 3, withPad: " ", startingAt: 0) + " |" + ascii + "|"
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }

    static func hex(_ bytes: [UInt8], limit: Int = 48) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return bytes.count > limit ? shown + " …" : shown
    }

    /// `blocks`: an XMODEM/YMODEM trace, which counts blocks and NAKs rather than headers,
    /// subpackets and ZRPOS.
    func summary(outcome: String, duration: TimeInterval, blocks: Bool = false) {
        let rate = duration > 0 ? Double(max(dataBytesIn, dataBytesOut)) / duration : 0
        let counts = blocks
            ? "blocks \(subpacketsIn) in / \(subpacketsOut) out"
            : "headers \(headersIn) in / \(headersOut) out; data subpackets \(subpacketsIn) in / \(subpacketsOut) out"
        let errors = blocks
            ? "\(badSubpackets) bad blocks, \(garbageBytes) garbage bytes skipped, \(timeouts) timeouts; "
                + "NAK \(naksIn) received / \(naksOut) sent"
            : "\(badHeaders) bad headers, \(badSubpackets) bad subpackets, \(garbageBytes) garbage bytes skipped, "
                + "\(timeouts) timeouts; ZRPOS \(rposIn) received / \(rposOut) sent"
        note("""
            summary: \(outcome)
                duration \(String(format: "%.2f", duration)) s, payload \(dataBytesIn) in / \(dataBytesOut) out \
            (\(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s)
                \(counts)
                raw line bytes \(rawBytesIn) in / \(rawBytesOut) out
                errors: \(errors)
            """)
        queue.sync { file.synchronize() }
    }
}

extension ZHeader {
    var formatName: String {
        switch format {
        case Z.hex: return "hex"
        case Z.bin32: return "bin32"
        default: return "bin16"
        }
    }

    /// e.g. "ZRPOS hex  pos=40960" or "ZRINIT hex  caps=CANFDX|CANFC32 buffer=1024".
    var traceDescription: String {
        let pad = "\(name) \(formatName)  "
        switch frame {
        case .rinit:
            let buffer = Int(p[0]) | Int(p[1]) << 8
            return pad + "caps=\(Self.capabilities(zf0)) buffer=\(buffer)\(buffer == 0 ? " (stream)" : "") zf1=\(Self.h2(zf1))"
        case .file:
            let conv: String
            switch zf0 {
            case 0: conv = "none"
            case 1: conv = "binary"
            case 2: conv = "text(CR/LF)"
            case 3: conv = "resume"
            default: conv = Self.h2(zf0)
            }
            return pad + "conv=\(conv) mgmt=\(Self.h2(zf1)) transport=\(Self.h2(p[1])) ext=\(Self.h2(p[0]))"
        case .rpos, .data, .eof, .ack, .crc, .freecnt, .compl, .skip, .nak, .fin:
            return pad + "pos=\(position)"
        default:
            return pad + "zf0=\(Self.h2(zf0)) zf1=\(Self.h2(zf1)) zf2=\(Self.h2(p[1])) zf3=\(Self.h2(p[0]))"
        }
    }

    private static func h2(_ b: UInt8) -> String { String(format: "%02x", b) }

    static func capabilities(_ f: UInt8) -> String {
        let names: [(UInt8, String)] = [(0x01, "CANFDX"), (0x02, "CANOVIO"), (0x04, "CANBRK"), (0x08, "CANCRY"),
                                        (0x10, "CANLZW"), (0x20, "CANFC32"), (0x40, "ESCCTL"), (0x80, "ESC8")]
        let set = names.filter { f & $0.0 != 0 }.map(\.1)
        return set.isEmpty ? "none" : set.joined(separator: "|")
    }
}
