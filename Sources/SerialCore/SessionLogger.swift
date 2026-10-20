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

    public let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "SessionLogger")
    private let formatter: DateFormatter

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()

        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    deinit {
        queue.sync { try? handle.close() }
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

    public func note(_ text: String, at date: Date = Date()) {
        write(.note, text, at: date)
    }

    public func flush() {
        queue.sync { try? handle.synchronize() }
    }

    private func write(_ direction: Direction, _ text: String, at date: Date) {
        queue.async { [self] in
            let line = "\(formatter.string(from: date)) \(direction.rawValue) \(text)\n"
            handle.write(Data(line.utf8))
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
}
