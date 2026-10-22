// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

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

    /// XMODEM/YMODEM: block-at-a-time protocols whose receivers only notice CAN between blocks.
    public var isBlockProtocol: Bool {
        switch self {
        case .zmodemReceive, .zmodemSend: return false
        default: return true
        }
    }

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

extension TransferKind {
    /// The command to type at the remote's shell to start its receiver, for protocols whose
    /// sender doesn't do that itself (ZMODEM senders send "rz\r" on their own).
    public var remoteReceiveCommand: String? {
        switch self {
        case .ymodemSend: return "rb\r"
        case let .xmodemSend(url):
            return "rx " + Self.endOfOptions(Self.typeable(url.lastPathComponent)).map(Self.shellQuoted).joined(separator: " ") + "\r"
        default: return nil
        }
    }

    /// `name` as it can be typed at a remote shell: each byte outside printable ASCII becomes "_".
    /// The remote's tty acts on control characters before the shell sees them (CR ends the line,
    /// ^C interrupts it), and on a 7-bit line or with ISTRIP a UTF-8 "Ċ" (C4 8A) arrives as "D", LF.
    static func typeable(_ name: String) -> String {
        String(decoding: name.utf8.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: "_") }, as: UTF8.self)
    }

    /// A name for lrzsz's command line: after "--" if it starts with "-", so it isn't read as options.
    static func endOfOptions(_ name: String) -> [String] {
        name.hasPrefix("-") ? ["--", name] : [name]
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    private let lock = NSLock()
    private var lastStatus = ""
    private var cancelled = false
    /// Receives run in a private folder inside the download folder; on exit the files are moved
    /// out under the same safe names the built-in receiver uses (lrzsz keeps names like ".profile").
    private let incoming: URL?
    private let destination: URL

    /// Directories searched for lrzsz before `PATH` (GUI apps get a minimal `PATH`).
    public static var toolSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    /// How much of lrzsz's output may wait for the serial line. A tty would block the program
    /// when its buffer filled; through a pipe nothing does unless we wait.
    static let maxQueuedOutput = 64 * 1024

    /// - Parameter xmodem1K: send XMODEM with 1024-byte blocks (XMODEM-1K) instead of 128.
    public init(kind: TransferKind, workingDirectory: URL, xmodem1K: Bool = false) throws {
        self.kind = kind

        var (names, args, directory) = try Self.command(for: kind)
        if xmodem1K, case .xmodemSend = kind { args.insert("-k", at: 0) }
        guard let tool = Self.findTool(names) else { throw TransferError.toolNotFound(names) }

        destination = directory ?? workingDirectory
        switch kind {
        case .zmodemReceive, .ymodemReceive:
            let folder = workingDirectory.appendingPathComponent(".SerialTerm-incoming-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            incoming = folder
        default:
            incoming = nil
        }

        process.executableURL = tool
        process.arguments = args
        process.currentDirectoryURL = incoming ?? destination
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    deinit {
        // Never started: don't leave the empty folder behind. rmdir only removes an empty one.
        if let incoming { _ = rmdir(incoming.path) }
    }

    public func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.onOutput?(data)
            // Hold lrzsz back to what the line can take: otherwise a whole file queues up, its
            // ZEOF timer runs out while the data is still going out, and a cancel waits behind it.
            self.waitForOutput?(Self.maxQueuedOutput)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty, let text = String(data: data, encoding: .utf8),
                  let line = Self.latestStatusLine(text) else { return }
            self.lock.withLock { self.lastStatus = line }
            self.onStatus?(line)
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            let moved = self.moveReceivedFiles()
            let ok = p.terminationReason == .exit && p.terminationStatus == 0
            let (cancelled, lastStatus) = self.lock.withLock { (self.cancelled, self.lastStatus) }
            var message: String
            if cancelled {
                message = "Cancelled"
            } else if ok {
                message = "Complete"
            } else {
                message = lastStatus.isEmpty ? "Failed (exit \(p.terminationStatus))" : lastStatus
            }
            if !moved.isEmpty { message += "; saved " + moved.joined(separator: ", ") }
            self.onFinish?(ok && !cancelled, message)
        }
        try process.run()
    }

    /// Moves what lrzsz received into the download folder under safe, unused names.
    /// Returns the names used where they differ from what the sender sent.
    private func moveReceivedFiles() -> [String] {
        guard let incoming else { return [] }
        let fm = FileManager.default
        var renamed: [String] = []
        let names = (try? fm.contentsOfDirectory(atPath: incoming.path)) ?? []
        for name in names.sorted() {
            let source = incoming.appendingPathComponent(name)
            let target = ZmodemReceiver.uniqueURL(in: destination, for: name)
            do {
                try fm.moveItem(at: source, to: target)
                if target.lastPathComponent != name { renamed.append("\(name) as \(target.lastPathComponent)") }
            } catch {
                onLog?("Could not move \(name) into \(destination.path): \(error.localizedDescription); it is in \(incoming.path)")
            }
        }
        if (try? fm.contentsOfDirectory(atPath: incoming.path))?.isEmpty ?? false {
            try? fm.removeItem(at: incoming)
        }
        return renamed
    }

    /// The last non-blank line of lrzsz's stderr output; it redraws its progress with CR.
    static func latestStatusLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
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
    /// The standard abort: CANs, then backspaces to erase them if a shell receives them.
    public static let abortSequence = Data(repeating: 0x18, count: 8) + Data(repeating: 0x08, count: 8)

    public func cancel() {
        lock.withLock { cancelled = true }
        // Drop what's queued, so the abort goes out now rather than after the rest of the file.
        discardOutput?()
        onOutput?(Self.abortSequence)
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
            return (["lrx", "rx"], ["-b", "-y", "-vv"] + TransferKind.endOfOptions(url.lastPathComponent),
                    url.deletingLastPathComponent())
        case let .xmodemSend(url):
            return (["lsx", "sx"], ["-b", "-vv", url.path], nil)
        }
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
