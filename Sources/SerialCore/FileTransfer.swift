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

    var isYmodem: Bool {
        switch self {
        case .ymodemReceive, .ymodemSend: return true
        default: return false
        }
    }

    /// "zmodem", "ymodem" or "xmodem", for file names.
    public var protocolName: String {
        switch self {
        case .zmodemReceive, .zmodemSend: return "zmodem"
        case .ymodemReceive, .ymodemSend: return "ymodem"
        case .xmodemReceive, .xmodemSend: return "xmodem"
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
    /// The standard abort: CANs, then backspaces to erase them if a shell receives them.
    public static let abortSequence = Data(repeating: 0x18, count: 8) + Data(repeating: 0x08, count: 8)

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

    /// A name for the remote's command line: after "--" if it starts with "-", so it isn't read as options.
    static func endOfOptions(_ name: String) -> [String] {
        name.hasPrefix("-") ? ["--", name] : [name]
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    /// Types a command for the remote's shell (a sender starting the remote's receiver), at the
    /// session's typing pace, returning once it has gone out. Nil sends it at once.
    var typeReceiveCommand: ((String) -> Void)? { get set }
    /// Input that wasn't part of the transfer, for the terminal: what arrived after it ended (the
    /// remote's prompt), and everything received if it never became a transfer. Called on the
    /// protocol thread or the serial queue, in order.
    var onLeftover: ((Data) -> Void)? { get set }
    /// The protocol trace this transfer writes, if tracing is on.
    var traceURL: URL? { get }

    func start() throws
    func feed(_ data: Data)
    func cancel()
}
