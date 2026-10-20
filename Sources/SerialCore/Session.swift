// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

public enum SessionEvent: Sendable {
    case transferStarted(String)
    case transferStatus(String)
    case transferFinished(success: Bool, message: String)
    /// The remote ran `rz` and is waiting; the UI should ask which files to send
    /// (then call `startTransfer(.zmodemSend(...))`, or `abortRemoteTransfer()` if the user declines).
    case remoteWaitingForFiles
    /// The remote ran lrzsz `sx` ("Give your local XMODEM receive command now."); the UI should ask
    /// where to save (then call `startTransfer(.xmodemReceive(url))`, or `abortRemoteTransfer()`).
    case remoteXmodemSending
    case disconnected(Error?)
}

/// One open serial connection: routes received bytes to the terminal, the log, or an
/// active file transfer, and starts ZMODEM transfers automatically when the remote begins one.
public final class Session: @unchecked Sendable {
    public let port: SerialPort

    /// Received bytes for the terminal display. Called on the port's read queue.
    public var onDisplay: ((Data) -> Void)?
    /// Called on arbitrary queues.
    public var onEvent: ((SessionEvent) -> Void)?

    public var autoZmodem = true
    /// Run ZMODEM through lrzsz instead of the built-in implementation.
    public var useExternalZmodem = false
    public var zmodemOptions = ZmodemOptions()
    /// Send XMODEM with 1024-byte blocks. Far fewer round trips; most receivers (lrzsz's included)
    /// accept it, but some older ones only take 128-byte blocks.
    public var xmodem1K = false
    /// Where ZMODEM protocol traces go (one file per transfer).
    public var traceDirectory: URL?
    /// The most recent ZMODEM trace file.
    public private(set) var lastTraceURL: URL?
    /// Where received files are saved.
    public var downloadDirectory: URL

    private let lock = NSLock()
    private var logger: SessionLogger?
    private var detector = ZmodemDetector()
    /// Recent displayed text, to spot lrzsz's "Give your local XMODEM/YMODEM receive command now."
    private var promptTail: [UInt8] = []
    private static let xmodemPrompt = Array("Give your local XMODEM receive command now.".utf8)
    private static let ymodemPrompt = Array("Give your local YMODEM receive command now.".utf8)
    private var transfer: FileTransfer?
    /// After cancelling an XMODEM/YMODEM transfer: until when to watch for a remote receiver that
    /// missed the abort, and how many more aborts may be sent.
    private var cancelWatchUntil: Date?
    private var cancelRetries = 0
    private static let nak: UInt8 = 0x15

    public init(port: SerialPort, downloadDirectory: URL) {
        self.port = port
        self.downloadDirectory = downloadDirectory
        port.onData = { [weak self] data in self?.handleIncoming(data) }
        port.onClose = { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.logger }?.note("Disconnected\(error.map { ": \($0)" } ?? "")")
            self.cancelTransfer()
            self.onEvent?(.disconnected(error))
        }
    }

    public func open() throws {
        try port.open()
        lock.withLock { logger }?.note("Connected \(port.path) \(port.config.summary)")
    }

    public func close() {
        port.close()
    }

    public var isTransferring: Bool {
        lock.withLock { transfer != nil }
    }

    // MARK: Logging

    public func startLogging(to url: URL) throws {
        let newLogger = try SessionLogger(url: url)
        newLogger.note("Log opened; \(port.path) \(port.config.summary); time zone \(TimeZone.current.identifier)")
        lock.withLock { logger = newLogger }
    }

    public func stopLogging() {
        let old: SessionLogger? = lock.withLock {
            let l = logger
            logger = nil
            return l
        }
        old?.note("Log closed")
        old?.flush()
    }

    public var logURL: URL? {
        lock.withLock { logger?.url }
    }

    // MARK: Sending

    /// Bytes typed or pasted by the user. Ignored while a transfer is running, since
    /// stray keystrokes would corrupt it.
    public func sendFromUser(_ data: Data) {
        let (busy, logger) = lock.withLock { (transfer != nil, self.logger) }
        guard !busy else { return }
        logger?.log(.tx, data)
        port.write(data)
    }

    // MARK: Transfers

    /// - Parameter primed: bytes already received that belong to the transfer (auto-start).
    /// - Parameter startRemote: first type the remote's receive command (`rb`, `rx name`) for
    ///   protocols whose sender doesn't start the receiver itself.
    public func startTransfer(_ kind: TransferKind, primed: Data? = nil, startRemote: Bool = false) throws {
        let t: FileTransfer
        switch kind {
        case .zmodemReceive, .zmodemSend:
            if useExternalZmodem {
                t = try ExternalTransfer(kind: kind, workingDirectory: downloadDirectory)
            } else {
                let traceURL = traceDirectory?.appendingPathComponent(ZmodemTrace.defaultFileName())
                let z = ZmodemTransfer(kind: kind, directory: downloadDirectory, options: zmodemOptions, traceURL: traceURL)
                if let primed { z.prime(primed) }
                lastTraceURL = z.trace?.url ?? lastTraceURL
                t = z
            }
        default:
            t = try ExternalTransfer(kind: kind, workingDirectory: downloadDirectory, xmodem1K: xmodem1K)
        }
        let logger: SessionLogger? = try lock.withLock {
            guard transfer == nil else { throw TransferInProgress() }
            transfer = t
            return self.logger
        }

        t.onOutput = { [weak self] data in self?.port.write(data) }
        t.waitForOutput = { [weak self] in self?.port.waitForPendingWrites(maxPending: $0) }
        t.discardOutput = { [weak self] in self?.port.discardPendingWrites() }
        t.onStatus = { [weak self] line in self?.onEvent?(.transferStatus(line)) }
        t.onLog = { [weak self] line in
            guard let self else { return }
            self.lock.withLock { self.logger }?.note(line)
        }
        t.onFinish = { [weak self, weak t] success, message in
            guard let self else { return }
            let logger: SessionLogger? = self.lock.withLock {
                if self.transfer === t { self.transfer = nil }
                self.detector.reset()
                return self.logger
            }
            logger?.note("\(kind.displayName): \(message)")
            self.onEvent?(.transferFinished(success: success, message: message))
        }

        // Only once the transfer is certain to start: type the remote's receive command if asked.
        if startRemote, let command = ExternalTransfer.remoteReceiveCommand(for: kind) {
            logger?.log(.tx, Data(command.utf8))
            port.write(Data(command.utf8))
        }
        logger?.note("\(kind.displayName) started (transfer data not logged)")
        onEvent?(.transferStarted(kind.displayName))
        do {
            try t.start()
        } catch {
            lock.withLock { if transfer === t { transfer = nil } }
            throw error
        }
    }

    public func cancelTransfer() {
        let active: FileTransfer? = lock.withLock {
            if let t = transfer as? ExternalTransfer, t.kind.isBlockProtocol {
                // X/YMODEM receivers only see CAN at a block boundary; one that got the abort
                // mid-block treats it as a bad block and NAKs. Watch for that and abort again.
                cancelWatchUntil = Date().addingTimeInterval(15)
                cancelRetries = 4
            }
            return transfer
        }
        active?.cancel()
    }

    /// Tell a waiting remote `rz` to give up.
    public func abortRemoteTransfer() {
        port.write(Data(repeating: 0x18, count: 8) + Data(repeating: 0x08, count: 8))
    }

    struct TransferInProgress: Error, CustomStringConvertible {
        var description: String { "A transfer is already in progress" }
    }

    // MARK: Receiving

    private func handleIncoming(_ data: Data) {
        let (active, logger, auto) = lock.withLock { (transfer, self.logger, autoZmodem) }

        if let active {
            active.feed(data)
            return
        }

        logger?.log(.rx, data)
        abortAgainIfRemoteStillReceiving(data)

        guard auto, let match = lock.withLock({ detector.scan(data) }) else {
            onDisplay?(data)
            if auto { checkForLrzszPrompt(data) }
            return
        }

        // Show what came before the header; the header itself is protocol noise.
        if match.headerStart > 0 {
            onDisplay?(data.prefix(match.headerStart))
        }

        switch match.trigger {
        case .remoteSending:
            do {
                // Hand over the opening frame (when it all arrived in this read) so the trace shows it.
                let opening = data.count > match.headerStart && data[data.startIndex + match.headerStart] == Z.pad
                    ? data.suffix(from: data.startIndex + match.headerStart) : nil
                try startTransfer(.zmodemReceive, primed: opening)
            } catch {
                logger?.note("Auto ZMODEM receive failed: \(error)")
                abortRemoteTransfer()
                onEvent?(.transferFinished(success: false, message: "\(error)"))
            }
        case .remoteReceiving:
            onEvent?(.remoteWaitingForFiles)
        }
    }

    /// A NAK after a cancel means the remote's XMODEM/YMODEM receiver missed the abort (it arrived
    /// mid-block) and is waiting for a resend; this time the abort lands at a block boundary.
    /// Blind repeats are worse: if the first abort worked, CANs reaching the shell disturb it.
    private func abortAgainIfRemoteStillReceiving(_ data: Data) {
        let again: Bool = lock.withLock {
            guard let until = cancelWatchUntil else { return false }
            guard Date() < until, cancelRetries > 0 else {
                cancelWatchUntil = nil
                return false
            }
            guard data.contains(Self.nak) else { return false }
            cancelRetries -= 1
            return true
        }
        if again {
            lock.withLock { logger }?.note("Remote still receiving after cancel (NAK); aborting again")
            port.write(ExternalTransfer.abortSequence)
        }
    }

    /// lrzsz's `sx`/`sb` announce themselves in plain text; start the matching receive.
    private func checkForLrzszPrompt(_ data: Data) {
        let found: [UInt8]? = lock.withLock {
            promptTail.append(contentsOf: data)
            if promptTail.count > 256 { promptTail.removeFirst(promptTail.count - 256) }
            for prompt in [Self.xmodemPrompt, Self.ymodemPrompt] where promptTail.contains(prompt) {
                promptTail.removeAll()
                return prompt
            }
            return nil
        }
        switch found {
        case Self.ymodemPrompt?:
            do {
                try startTransfer(.ymodemReceive)
            } catch {
                abortRemoteTransfer()
                onEvent?(.transferFinished(success: false, message: "\(error)"))
            }
        case Self.xmodemPrompt?:
            onEvent?(.remoteXmodemSending)
        default:
            break
        }
    }
}
