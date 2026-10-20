import Foundation

/// A file transfer request. ZMODEM and YMODEM are batch protocols: a send may carry any
/// number of files, and a receive accepts however many the remote sends.
public enum TransferKind: Sendable, Equatable {
    case zmodemReceive
    case zmodemSend([URL])
    case ymodemReceive
    case ymodemSend([URL])
    /// XMODEM carries no file name, so the receiver has to choose one.
    case xmodemReceive(URL)
    case xmodemSend(URL)

    public var displayName: String {
        switch self {
        case .zmodemReceive: return "ZMODEM receive"
        case let .zmodemSend(files): return "ZMODEM send (\(Self.count(files)))"
        case .ymodemReceive: return "YMODEM receive"
        case let .ymodemSend(files): return "YMODEM send (\(Self.count(files)))"
        case let .xmodemReceive(url): return "XMODEM receive → \(url.lastPathComponent)"
        case let .xmodemSend(url): return "XMODEM send \(url.lastPathComponent)"
        }
    }

    private static func count(_ files: [URL]) -> String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }
}

public enum TransferError: Error, CustomStringConvertible {
    case toolNotFound([String])
    case noFiles

    public var description: String {
        switch self {
        case let .toolNotFound(names):
            return "Could not find \(names.joined(separator: " or ")). Install lrzsz with: brew install lrzsz"
        case .noFiles:
            return "No files selected"
        }
    }
}

/// A running file transfer. The session feeds it bytes from the serial line and
/// sends whatever it emits through `onOutput`.
public protocol FileTransfer: AnyObject, Sendable {
    var kind: TransferKind { get }
    /// Bytes to send to the serial line.
    var onOutput: ((Data) -> Void)? { get set }
    /// Blocks until at most `maxPending` bytes of output are still queued (0 = all of it has
    /// reached the serial driver). Back-pressure for senders.
    var waitForOutput: ((_ maxPending: Int) -> Void)? { get set }
    /// Drops output queued but not yet sent (stale after a protocol rewind).
    var discardOutput: (() -> Void)? { get set }
    /// Latest progress line.
    var onStatus: ((String) -> Void)? { get set }
    /// Notable events worth a line in the session log.
    var onLog: ((String) -> Void)? { get set }
    /// Called once when the transfer ends.
    var onFinish: ((_ success: Bool, _ message: String) -> Void)? { get set }

    func start() throws
    func feed(_ data: Data)
    func cancel()
}

/// Runs a transfer by bridging an lrzsz program's stdin/stdout to the serial line,
/// the same approach minicom uses.
public final class ExternalTransfer: FileTransfer, @unchecked Sendable {
    public let kind: TransferKind

    public var onOutput: ((Data) -> Void)?
    public var waitForOutput: ((_ maxPending: Int) -> Void)?
    public var discardOutput: (() -> Void)?
    /// Progress lines from the program's stderr.
    public var onStatus: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onFinish: ((_ success: Bool, _ message: String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let feedQueue = DispatchQueue(label: "ExternalTransfer.feed")
    private var lastStatus = ""
    private var cancelled = false

    /// Directories searched for lrzsz before `PATH` (GUI apps get a minimal `PATH`).
    public static var toolSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public init(kind: TransferKind, workingDirectory: URL) throws {
        self.kind = kind

        let (names, args, directory) = try Self.command(for: kind)
        guard let tool = Self.findTool(names) else { throw TransferError.toolNotFound(names) }

        process.executableURL = tool
        process.arguments = args
        process.currentDirectoryURL = directory ?? workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    public func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if !data.isEmpty { self?.onOutput?(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            // lrzsz redraws progress with \r; report the latest non-empty line.
            let lines = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            if let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let line = String(last).trimmingCharacters(in: .whitespaces)
                self.lastStatus = line
                self.onStatus?(line)
            }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            let ok = p.terminationReason == .exit && p.terminationStatus == 0
            let message: String
            if self.cancelled {
                message = "Cancelled"
            } else if ok {
                message = "Complete"
            } else {
                message = self.lastStatus.isEmpty ? "Failed (exit \(p.terminationStatus))" : self.lastStatus
            }
            self.onFinish?(ok && !self.cancelled, message)
        }
        try process.run()
    }

    /// Bytes received from the serial line, forwarded to the program.
    public func feed(_ data: Data) {
        feedQueue.async { [weak self] in
            guard let self, self.process.isRunning else { return }
            // Fails harmlessly (EPIPE) if the program has just exited; SIGPIPE must be ignored by the app.
            try? self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    /// Abort: tell the remote to stop (8×CAN then backspaces, the standard ZMODEM abort) and end the program.
    /// Delays at which the abort is repeated after a cancel. XMODEM/YMODEM receivers only notice
    /// CAN at the start of a block, so a single abort sent mid-block is absorbed as bad data and
    /// the remote keeps waiting; later copies arrive while it's between blocks.
    public static var abortRepeats: [TimeInterval] = [1.5, 3.0]

    public func cancel() {
        cancelled = true
        let abort = Data(repeating: 0x18, count: 8) + Data(repeating: 0x08, count: 8)
        let output = onOutput
        output?(abort)
        if process.isRunning { process.terminate() }
        for delay in Self.abortRepeats {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { output?(abort) }
        }
    }

    // MARK: - Command lines

    /// Program names to try, arguments, and (if not the session's) the directory to run in.
    static func command(for kind: TransferKind) throws -> ([String], [String], URL?) {
        // -b binary, -vv progress on stderr. Receivers: -E rename instead of overwriting.
        switch kind {
        case .zmodemReceive:
            return (["lrz", "rz"], ["-b", "-E", "-vv"], nil)
        case let .zmodemSend(files):
            guard !files.isEmpty else { throw TransferError.noFiles }
            return (["lsz", "sz"], ["-b", "-vv"] + files.map(\.path), nil)
        case .ymodemReceive:
            return (["lrb", "rb"], ["-b", "-E", "-vv"], nil)
        case let .ymodemSend(files):
            guard !files.isEmpty else { throw TransferError.noFiles }
            return (["lsb", "sb"], ["-b", "-vv"] + files.map(\.path), nil)
        case let .xmodemReceive(url):
            // lrzsz refuses receive paths containing "/" ("Security Violation"), so run in the
            // file's folder with a bare name. -y: the save panel already confirmed any overwrite.
            return (["lrx", "rx"], ["-b", "-y", "-vv", url.lastPathComponent], url.deletingLastPathComponent())
        case let .xmodemSend(url):
            return (["lsx", "sx"], ["-b", "-vv", url.path], nil)
        }
    }

    /// The command to type at the remote's shell to start its receiver, for protocols whose
    /// sender doesn't do that itself (ZMODEM senders send "rz\r" on their own).
    public static func remoteReceiveCommand(for kind: TransferKind) -> String? {
        switch kind {
        case .ymodemSend: return "rb\r"
        case let .xmodemSend(url): return "rx \(shellQuoted(url.lastPathComponent))\r"
        default: return nil
        }
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func findTool(_ names: [String]) -> URL? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fm = FileManager.default
        for name in names {
            for dir in toolSearchPaths + pathDirs {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
