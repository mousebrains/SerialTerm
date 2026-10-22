// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Writes a human-readable session log with millisecond timestamps.
///
///     2026-10-20 10:32:01.123 RX login: \r\n
///     2026-10-20 10:32:02.456 TX root\r
///     2026-10-20 10:32:05.001 -- ZMODEM receive started
///
/// Each line is one chunk as delivered by the driver, so timestamps record when the
/// host received the bytes. USB-serial adapters batch input (FTDI: up to 16 ms by
/// default), which bounds how precise these can be.
public final class SessionLogger: @unchecked Sendable {
    public enum Direction: String, Sendable {
        case rx = "RX"
        case tx = "TX"
        case note = "--"
    }

    /// The log file. If the requested name was taken, this is the "-2", "-3"… variant used instead.
    public let url: URL
    /// Called once, on the logger's queue, if a write fails (disk full, volume gone). The log
    /// stops there; set this before logging anything.
    public var onFailure: ((Error) -> Void)?
    let file: LogFile  // internal for tests
    private let queue = DispatchQueue(label: "SessionLogger")
    private let formatter: DateFormatter

    /// Starts a new log at `url`, or at "name-2.log" (and so on) if that name is taken, so two
    /// sessions never write into one file.
    public init(url: URL) throws {
        file = try LogFile(creatingNewFileAt: url)
        self.url = file.url
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    /// A file name like `SerialTerm-2026-10-20-103201.log` for a new session.
    public static func defaultFileName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SerialTerm-\(f.string(from: date)).log"
    }

    public func log(_ direction: Direction, _ data: Data, at date: Date = Date()) {
        guard !data.isEmpty else { return }
        write(direction, Self.escape(data), at: date)
    }

    /// Notes may quote the remote (file names, lrzsz messages), so control and invisible
    /// formatting characters are escaped: a note can't start a fake log line.
    public func note(_ text: String, at date: Date = Date()) {
        write(.note, Self.escapeNote(text), at: date)
    }

    public func flush() {
        queue.sync { file.synchronize() }
    }

    private func write(_ direction: Direction, _ text: String, at date: Date) {
        queue.async { [self] in
            let line = "\(formatter.string(from: date)) \(direction.rawValue) \(text)\n"
            if let error = file.write(Data(line.utf8)) { onFailure?(error) }
        }
    }

    /// Printable ASCII is kept as-is; everything else is escaped so a log line is
    /// always one line and binary data is unambiguous.
    public static func escape(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity(data.count)
        for byte in data {
            switch byte {
            case 0x0D: out += "\\r"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x1B: out += "\\e"
            case 0x5C: out += "\\\\"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(byte))
            default: out += String(format: "\\x%02X", byte)
            }
        }
        return out
    }

    /// Text is kept, except line breaks, control characters and invisible formatting characters
    /// (bidirectional overrides, zero-width characters), which are escaped.
    public static func escapeNote(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for s in text.unicodeScalars {
            switch s.value {
            case 0x0D: out += "\\r"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x1B: out += "\\e"
            case 0x00..<0x20, 0x7F...0x9F: out += String(format: "\\x%02X", s.value)
            default:
                switch s.properties.generalCategory {
                case .format, .lineSeparator, .paragraphSeparator:
                    out += String(format: "\\u{%04X}", s.value)
                default:
                    out.unicodeScalars.append(s)
                }
            }
        }
        return out
    }
}
