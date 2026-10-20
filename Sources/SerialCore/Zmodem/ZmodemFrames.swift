// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Wire constants and headers for ZMODEM (Chuck Forsberg's 1988 specification, as
/// implemented by lrzsz and most terminal programs).
enum Z {
    static let pad: UInt8 = 0x2A      // '*'
    static let dle: UInt8 = 0x18      // ZDLE (same byte as CAN)
    static let can: UInt8 = 0x18
    static let bin16: UInt8 = 0x41    // 'A' binary header, CRC-16
    static let hex: UInt8 = 0x42      // 'B' hex header, CRC-16
    static let bin32: UInt8 = 0x43    // 'C' binary header, CRC-32
    static let xon: UInt8 = 0x11
    static let xoff: UInt8 = 0x13

    // Data subpacket terminators (sent as ZDLE + char).
    static let crcE: UInt8 = 0x68     // 'h' end of frame; header follows
    static let crcG: UInt8 = 0x69     // 'i' more data follows, no response
    static let crcQ: UInt8 = 0x6A     // 'j' more data follows, receiver sends ZACK
    static let crcW: UInt8 = 0x6B     // 'k' end of frame, receiver sends ZACK
    static let rub0: UInt8 = 0x6C     // 'l' → 0x7F
    static let rub1: UInt8 = 0x6D     // 'm' → 0xFF

    // ZRINIT capability flags (ZF0).
    static let canFDX: UInt8 = 0x01
    static let canOVIO: UInt8 = 0x02
    static let canFC32: UInt8 = 0x20
    static let escCtl: UInt8 = 0x40

    // ZFILE conversion option (ZF0).
    static let convBinary: UInt8 = 1

    /// The standard abort: CANs then backspaces to erase them from a remote shell line.
    static let abortSequence = [UInt8](repeating: can, count: 10) + [UInt8](repeating: 0x08, count: 10)
}

enum ZFrameType: UInt8, CustomStringConvertible {
    case rqinit = 0, rinit, sinit, ack, file, skip, nak, abort, fin, rpos, data, eof, ferr, crc,
         challenge, compl, can, freecnt, command, stderr

    private static let names = ["ZRQINIT", "ZRINIT", "ZSINIT", "ZACK", "ZFILE", "ZSKIP", "ZNAK", "ZABORT", "ZFIN",
                                "ZRPOS", "ZDATA", "ZEOF", "ZFERR", "ZCRC", "ZCHALLENGE", "ZCOMPL", "ZCAN",
                                "ZFREECNT", "ZCOMMAND", "ZSTDERR"]

    var description: String { Self.names[Int(rawValue)] }
}

struct ZHeader: Equatable {
    var type: UInt8
    /// ZP0...ZP3. Positions are little-endian (ZP0 lowest); flags are ZF0 = ZP3 ... ZF3 = ZP0.
    var p: [UInt8]
    /// Wire format it arrived in: Z.hex, Z.bin16 or Z.bin32.
    var format: UInt8 = Z.hex
    /// The header arrived as ZBIN32, so the data subpackets that follow use CRC-32.
    var crc32: Bool { format == Z.bin32 }

    var frame: ZFrameType? { ZFrameType(rawValue: type) }
    var position: Int { Int(p[0]) | Int(p[1]) << 8 | Int(p[2]) << 16 | Int(p[3]) << 24 }
    var zf0: UInt8 { p[3] }
    var zf1: UInt8 { p[2] }

    init(_ frame: ZFrameType, position: Int = 0) {
        type = frame.rawValue
        let v = UInt32(truncatingIfNeeded: position)
        p = [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
    }

    init(_ frame: ZFrameType, zf0: UInt8, zf1: UInt8 = 0, zf2: UInt8 = 0, zf3: UInt8 = 0) {
        type = frame.rawValue
        p = [zf3, zf2, zf1, zf0]
    }

    init(type: UInt8, p: [UInt8], format: UInt8) {
        self.type = type
        self.p = p
        self.format = format
    }

    var name: String { frame?.description ?? "frame \(type)" }
}

enum CRC {
    private static let table16: [UInt16] = (0..<256).map { i in
        var crc = UInt16(i) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        return crc
    }

    private static let table32: [UInt32] = (0..<256).map { i in
        var crc = UInt32(i)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    /// CRC-16/XMODEM (poly 0x1021, init 0).
    static func crc16<S: Sequence>(_ bytes: S, _ start: UInt16 = 0) -> UInt16 where S.Element == UInt8 {
        var crc = start
        for b in bytes { crc = (crc << 8) ^ table16[Int(UInt8(crc >> 8) ^ b)] }
        return crc
    }

    /// Running CRC-32 (IEEE). Start with 0xFFFFFFFF and invert at the end.
    static func crc32Update<S: Sequence>(_ bytes: S, _ start: UInt32) -> UInt32 where S.Element == UInt8 {
        var crc = start
        for b in bytes { crc = (crc >> 8) ^ table32[Int(UInt8(crc & 0xFF) ^ b)] }
        return crc
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        ~crc32Update(bytes, 0xFFFF_FFFF)
    }

    /// Fast paths for bulk data.
    static func crc32Update(_ buf: UnsafeRawBufferPointer, _ start: UInt32) -> UInt32 {
        table32.withUnsafeBufferPointer { t in
            var crc = start
            for b in buf { crc = (crc >> 8) ^ t[Int(UInt8(truncatingIfNeeded: crc) ^ b)] }
            return crc
        }
    }

    static func crc16(_ buf: UnsafeRawBufferPointer, _ start: UInt16) -> UInt16 {
        table16.withUnsafeBufferPointer { t in
            var crc = start
            for b in buf { crc = (crc << 8) ^ t[Int(UInt8(truncatingIfNeeded: crc >> 8) ^ b)] }
            return crc
        }
    }
}

/// Builds outgoing ZMODEM frames.
struct ZEncoder {
    /// Receiver asked for all control characters to be escaped (ZRINIT ESCCTL).
    var escapeControls = false
    private var last: UInt8 = 0

    mutating func hexHeader(_ h: ZHeader) -> [UInt8] {
        var raw = [h.type] + h.p
        let crc = CRC.crc16(raw)
        raw += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        var out: [UInt8] = [Z.pad, Z.pad, Z.dle, Z.hex]
        let digits = Array("0123456789abcdef".utf8)
        for b in raw { out += [digits[Int(b >> 4)], digits[Int(b & 0xF)]] }
        out += [0x0D, 0x8A]
        if h.frame != .ack && h.frame != .fin { out.append(Z.xon) }
        last = 0
        return out
    }

    mutating func binaryHeader(_ h: ZHeader, crc32: Bool) -> [UInt8] {
        let raw = [h.type] + h.p
        var out: [UInt8] = [Z.pad, Z.dle, crc32 ? Z.bin32 : Z.bin16]
        for b in raw { escape(b, into: &out) }
        appendCRC(for: raw, crc32: crc32, into: &out)
        return out
    }

    /// Bulk path for file data: one pass over contiguous bytes for escaping and CRC.
    mutating func subpacket(_ data: Data, end: UInt8, crc32: Bool) -> [UInt8] {
        data.withUnsafeBytes { subpacket($0, end: end, crc32: crc32) }
    }

    mutating func subpacket(_ buf: UnsafeRawBufferPointer, end: UInt8, crc32: Bool) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(buf.count + buf.count / 16 + 16)
        let table = escapeControls ? Self.escapeAllControls : Self.escapeMinimal
        table.withUnsafeBufferPointer { esc in
            var last = self.last
            for b in buf {
                if esc[Int(b)] || ((b == 0x0D || b == 0x8D) && last & 0x7F == 0x40) {
                    out.append(Z.dle)
                    out.append(b ^ 0x40)
                } else {
                    out.append(b)
                }
                last = b
            }
            self.last = last
        }
        out += [Z.dle, end]
        if crc32 {
            let crc = withUnsafeBytes(of: end) { ~CRC.crc32Update($0, CRC.crc32Update(buf, 0xFFFF_FFFF)) }
            for i in 0..<4 { escape(UInt8(crc >> (8 * UInt32(i)) & 0xFF), into: &out) }
        } else {
            let crc = withUnsafeBytes(of: end) { CRC.crc16($0, CRC.crc16(buf, 0)) }
            escape(UInt8(crc >> 8), into: &out)
            escape(UInt8(crc & 0xFF), into: &out)
        }
        if end == Z.crcW { out.append(Z.xon) }
        return out
    }

    /// Bytes that must always be ZDLE-escaped (CR after '@' is handled separately).
    private static let escapeMinimal: [Bool] = (0...255).map { b in
        [Z.dle, 0x10, 0x11, 0x13, 0x90, 0x91, 0x93].contains(UInt8(b))
    }
    /// ESCCTL: also every control character, in both halves.
    private static let escapeAllControls: [Bool] = (0...255).map { b in
        escapeMinimal[b] || UInt8(b) & 0x60 == 0
    }

    mutating func subpacket<C: Collection>(_ data: C, end: UInt8, crc32: Bool) -> [UInt8] where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 16 + 12)
        for b in data { escape(b, into: &out) }
        out += [Z.dle, end]
        if crc32 {
            let crc = ~CRC.crc32Update([end], CRC.crc32Update(data, 0xFFFF_FFFF))
            for i in 0..<4 { escape(UInt8(crc >> (8 * UInt32(i)) & 0xFF), into: &out) }
        } else {
            let crc = CRC.crc16([end], CRC.crc16(data))
            escape(UInt8(crc >> 8), into: &out)
            escape(UInt8(crc & 0xFF), into: &out)
        }
        if end == Z.crcW { out.append(Z.xon) }
        return out
    }

    private mutating func appendCRC(for raw: [UInt8], crc32: Bool, into out: inout [UInt8]) {
        if crc32 {
            let crc = CRC.crc32(raw)
            for i in 0..<4 { escape(UInt8(crc >> (8 * UInt32(i)) & 0xFF), into: &out) }
        } else {
            let crc = CRC.crc16(raw)
            escape(UInt8(crc >> 8), into: &out)
            escape(UInt8(crc & 0xFF), into: &out)
        }
    }

    mutating func escape(_ b: UInt8, into out: inout [UInt8]) {
        let mustEscape: Bool
        switch b {
        case Z.dle, 0x10, 0x11, 0x13, 0x90, 0x91, 0x93:
            mustEscape = true
        case 0x0D, 0x8D:
            // "@ CR" is a Telenet escape; always escape CR after '@'.
            mustEscape = escapeControls || last & 0x7F == 0x40
        default:
            mustEscape = escapeControls && b & 0x60 == 0
        }
        if mustEscape {
            out += [Z.dle, b ^ 0x40]
        } else {
            out.append(b)
        }
        last = b
    }
}
