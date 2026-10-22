// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

public enum SessionEvent: Sendable {
    case transferStarted(String)
    case transferStatus(String)
    /// Always follows `transferStarted`, including when the transfer then fails to start.
    case transferFinished(success: Bool, message: String)
    /// The remote ran `rz` and is waiting; the UI should ask which files to send
    /// (then call `startTransfer(.zmodemSend(...))`, or `abortRemoteTransfer()` if the user declines).
    case remoteWaitingForFiles
    /// The remote ran lrzsz `sx` ("Give your local XMODEM receive command now."); the UI should ask
    /// where to save (then call `startTransfer(.xmodemReceive(url))`, or `abortRemoteTransfer()`).
    case remoteXmodemSending
    /// Typed or pasted characters still waiting to go out under `pacing` (0 when done), and
    /// whether the last character got no echo in time (with `pacing.waitForEcho`).
    case pacedTyping(remaining: Int, echoMissing: Bool)
    /// The session log couldn't be written (disk full, volume gone) and has stopped.
    case logFailed(String)
    /// Something worth telling the user that isn't a transfer's outcome.
    case notice(String)
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

    // Settings are set on the main thread and read on the serial queue (automatic starts), so
    // they live under `lock`.
    private struct Settings {
        var autoZmodem = true
        var zmodemOptions = ZmodemOptions()
        var xmodem1K = false
        var traceDirectory: URL?
        var downloadDirectory: URL
        var zmodemReceiveCommand = "rz"
    }
    private var settings: Settings

    public var autoZmodem: Bool {
        get { lock.withLock { settings.autoZmodem } }
        set { lock.withLock { settings.autoZmodem = newValue } }
    }
    public var zmodemOptions: ZmodemOptions {
        get { lock.withLock { settings.zmodemOptions } }
        set { lock.withLock { settings.zmodemOptions = newValue } }
    }
    /// Send XMODEM with 1024-byte blocks. Far fewer round trips; most receivers (lrzsz's included)
    /// accept it, but some older ones only take 128-byte blocks.
    public var xmodem1K: Bool {
        get { lock.withLock { settings.xmodem1K } }
        set { lock.withLock { settings.xmodem1K = newValue } }
    }
    /// Where protocol traces go (one file per transfer).
    public var traceDirectory: URL? {
        get { lock.withLock { settings.traceDirectory } }
        set { lock.withLock { settings.traceDirectory = newValue } }
    }
    /// Where received files are saved.
    public var downloadDirectory: URL {
        get { lock.withLock { settings.downloadDirectory } }
        set { lock.withLock { settings.downloadDirectory = newValue } }
    }
    /// Typed before a built-in ZMODEM send to start the remote's receiver: "rz", "zr" (Slocum), or "".
    public var zmodemReceiveCommand: String {
        get { lock.withLock { settings.zmodemReceiveCommand } }
        set { lock.withLock { settings.zmodemReceiveCommand = newValue } }
    }
    /// The most recent protocol trace file.
    public var lastTraceURL: URL? { lock.withLock { lastTrace } }
    /// Rate limit for typed and pasted text, and for the receive commands the session types
    /// (`rb`, `rx name`, `rz`). File transfers are never paced.
    public var pacing: Pacing {
        get { pacer.pacing }
        set {
            pacer.pacing = newValue
            commandPacer.pacing = newValue
        }
    }

    private let lock = NSLock()
    private var lastTrace: URL?
    private var logger: SessionLogger?
    private var detector = ZmodemDetector()
    /// Recent displayed text, to spot lrzsz's "Give your local XMODEM/YMODEM receive command now."
    private var promptTail: [UInt8] = []
    private static let xmodemPrompt = Array("Give your local XMODEM receive command now.".utf8)
    private static let ymodemPrompt = Array("Give your local YMODEM receive command now.".utf8)
    private var transfer: FileTransfer?
    /// A transfer is being set up: `transfer` is about to be set.
    private var starting = false
    /// The running transfer was cancelled; waits for the line to drain give up.
    private var cancelRequested = false
    /// After cancelling an XMODEM/YMODEM transfer: until when to watch for a remote receiver that
    /// missed the abort, and how many more aborts may be sent.
    private var cancelWatchUntil: TimeInterval?
    private var cancelRetries = 0
    /// Recent failed automatic starts, and until when automatic starts are paused after too many
    /// (`Uptime` times, like the other deadlines here: they don't move with the clock).
    private var automaticFailures: [TimeInterval] = []
    private var automaticPausedUntil: TimeInterval?
    private static let nak: UInt8 = 0x15
    private let pacer = PacedSender()
    /// Types the receive commands the session sends for a transfer. Unlike `pacer`, its output
    /// isn't dropped once the transfer owns the line.
    private let commandPacer = PacedSender()
    private let commandDone = NSCondition()
    private var commandPending = 0

    public init(port: SerialPort, downloadDirectory: URL) {
        self.port = port
        settings = Settings(downloadDirectory: downloadDirectory)
        pacer.output = { [weak self] data in
            guard let self else { return }
            // A transfer that started meanwhile owns the line; the rest of the typing is dropped.
            if self.isTransferring { self.pacer.cancel() } else { self.port.write(data) }
        }
        pacer.onPending = { [weak self] n, missing in self?.onEvent?(.pacedTyping(remaining: n, echoMissing: missing)) }
        commandPacer.output = { [weak self] data in self?.port.write(data) }
        commandPacer.onPending = { [weak self] n, _ in
            guard let self else { return }
            self.commandDone.withLock {
                self.commandPending = n
                self.commandDone.broadcast()
            }
        }
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
        let logger = lock.withLock { self.logger }
        logger?.note("Connected \(port.path) \(port.config.summary)")
        for line in port.adapterReport { logger?.note(line) }
    }

    /// The first lines of every transfer trace: the line, the adapter and driver behind it, and
    /// the host, since all of them show in a transfer's timing.
    private func traceHeader() -> [String] {
        ["port: \(port.path) \(port.config.summary)"] + port.adapterReport
            + ["host: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
    }

    /// Closes the port. A running transfer is cancelled first and the remote told to stop, so
    /// neither side carries on alone (once the port is closed, nothing more can reach it).
    public func close() {
        pacer.cancel()
        commandPacer.cancel()
        let active: FileTransfer? = lock.withLock {
            if transfer != nil { cancelRequested = true }
            return transfer
        }
        if let active {
            lock.withLock { logger }?.note("Closing during \(active.kind.displayName); cancelling it")
            active.cancel()
            // The transfer sends the abort as it stops; give it a moment, and send one ourselves
            // if it doesn't finish in time.
            let deadline = Uptime.now + 1
            while lock.withLock({ transfer === active }) && Uptime.now < deadline { usleep(10_000) }
            if lock.withLock({ transfer === active }) {
                port.discardPendingWrites()
                port.write(TransferKind.abortSequence)
            }
            port.waitForPendingWrites(maxPending: 0, timeout: 1)
        }
        port.close()
    }

    /// `close` on a background queue, so the caller isn't held up while a running transfer stops
    /// and the abort goes out (normally milliseconds; up to about 2 s with a stuck line). `done` is
    /// called on that queue once the port is closed. The session stays alive until then.
    public func closeInBackground(then done: (@Sendable () -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            close()
            done?()
        }
    }

    deinit {
        // Released without close() (or before the port's close handler ran): don't leave a
        // transfer running with nobody to finish it.
        transfer?.cancel()
    }

    public var isTransferring: Bool {
        lock.withLock { transfer != nil }
    }

    // MARK: Logging

    /// Starts a new log at `url`, or at "name-2.log" (and so on) if another session already has
    /// that name. Returns the file actually used.
    @discardableResult
    public func startLogging(to url: URL) throws -> URL {
        let newLogger = try SessionLogger(url: url)
        newLogger.onFailure = { [weak self, weak newLogger] error in
            guard let self else { return }
            let stopped: Bool = self.lock.withLock {
                guard let newLogger, self.logger === newLogger else { return false }
                self.logger = nil
                return true
            }
            if stopped { self.onEvent?(.logFailed(error.localizedDescription)) }
        }
        newLogger.note("Log opened; \(port.path) \(port.config.summary); time zone \(TimeZone.current.identifier)")
        // Started after connecting: `open` wrote the adapter to no log, so write it here.
        if port.isOpen {
            for line in port.adapterReport { newLogger.note(line) }
        }
        lock.withLock { logger = newLogger }
        return newLogger.url
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
    /// stray keystrokes would corrupt it. Sent at the rate `pacing` allows; the log records
    /// them when typed.
    public func sendFromUser(_ data: Data) {
        let (busy, logger) = lock.withLock { (transfer != nil, self.logger) }
        guard !busy else { return }
        logger?.log(.tx, data)
        if pacer.pacing.isOn || pacer.isBusy {
            pacer.send(data)  // also when pacing was just turned off, to keep the order
        } else {
            port.write(data)
        }
    }

    /// Drop typed or pasted text that pacing hasn't sent yet.
    public func cancelPacedTyping() {
        pacer.cancel()
    }

    // MARK: Transfers

    /// - Parameter primed: bytes already received that belong to the transfer (auto-start).
    /// - Parameter startRemote: have the sender type the remote's receive command (`rb`,
    ///   `rx name`) first, for protocols whose sender doesn't start the receiver itself.
    ///
    /// Throws `TransferInProgress` (nothing else happens), or `TransferStartFailed` for a transfer
    /// that couldn't start, which has also been reported with `transferStarted` and
    /// `transferFinished`. Problems once it runs (a file that can't be read or saved) end it with
    /// `transferFinished`.
    public func startTransfer(_ kind: TransferKind, primed: Data? = nil, startRemote: Bool = false) throws {
        try startTransfer(kind, primed: primed, startRemote: startRemote, automatic: false)
    }

    private func startTransfer(_ kind: TransferKind, primed: Data?, startRemote: Bool, automatic: Bool) throws {
        // Claim the slot before creating anything, so a refused start leaves no trace file.
        let s: Settings = try lock.withLock {
            guard transfer == nil, !starting else { throw TransferInProgress() }
            starting = true
            return settings
        }
        let t = makeTransfer(kind, primed: primed, startRemote: startRemote, settings: s)
        pacer.cancel()

        t.onOutput = { [weak self] data in self?.port.write(data) }
        t.typeReceiveCommand = { [weak self] command in
            guard let self else { return }
            self.lock.withLock { self.logger }?.log(.tx, Data(command.utf8))
            self.typeCommand(command, wait: true)
        }
        t.onLeftover = { [weak self] data in self?.showAfterTransfer(data) }
        t.waitForOutput = { [weak self, weak t] maxPending in
            self?.port.waitForPendingWrites(maxPending: maxPending, until: { [weak self, weak t] in
                guard let self, let t else { return true }
                return self.lock.withLock { self.transfer !== t || self.cancelRequested }
            })
        }
        t.discardOutput = { [weak self] in self?.port.discardPendingWrites() }
        t.onStatus = { [weak self] line in self?.onEvent?(.transferStatus(line)) }
        t.onLog = { [weak self] line in
            guard let self else { return }
            self.lock.withLock { self.logger }?.note(line)
        }
        t.onFinish = { [weak self, weak t] success, message in
            guard let self else { return }
            let (logger, cancelled): (SessionLogger?, Bool) = self.lock.withLock {
                if self.transfer === t { self.transfer = nil }
                self.detector.reset()
                return (self.logger, self.cancelRequested)
            }
            logger?.note("\(kind.displayName): \(message)")
            // A cancel isn't the remote's doing, so it doesn't count either way.
            if automatic && !cancelled { self.automaticResult(success: success) }
            self.onEvent?(.transferFinished(success: success, message: message))
        }
        // Only now, with its callbacks set: a cancel or close can reach it from another thread.
        let logger: SessionLogger? = lock.withLock {
            starting = false
            transfer = t
            cancelRequested = false
            if let url = t.traceURL { lastTrace = url }
            return self.logger
        }

        logger?.note("\(kind.displayName) started (transfer data not logged)")
        if startRemote, case let .xmodemSend(url) = kind, case let typed = TransferKind.typeable(url.lastPathComponent),
           typed != url.lastPathComponent {
            logger?.note("\(url.lastPathComponent) typed as \(typed): a terminal line can't carry all its characters")
        }
        onEvent?(.transferStarted(kind.displayName))
        do {
            try t.start()
        } catch {
            lock.withLock {
                if transfer === t { transfer = nil }
                detector.reset()
            }
            logger?.note("\(kind.displayName) could not start: \(error)")
            if automatic { automaticResult(success: false) }
            onEvent?(.transferFinished(success: false, message: "\(error)"))
            throw TransferStartFailed(underlying: error)
        }
    }

    private func makeTransfer(_ kind: TransferKind, primed: Data?, startRemote: Bool, settings s: Settings) -> FileTransfer {
        let traceURL = s.traceDirectory?.appendingPathComponent(ZmodemTrace.defaultFileName(protocolName: kind.protocolName))
        switch kind {
        case .zmodemReceive, .zmodemSend:
            let z = ZmodemTransfer(kind: kind, directory: s.downloadDirectory, options: s.zmodemOptions, traceURL: traceURL,
                                   receiveCommand: s.zmodemReceiveCommand)
            traceHeader().forEach { z.trace?.note($0) }
            if let primed { z.prime(primed) }
            return z
        default:
            let x = XmodemTransfer(kind: kind, directory: s.downloadDirectory, xmodem1K: s.xmodem1K,
                                   receiveCommand: startRemote ? kind.remoteReceiveCommand : nil,
                                   traceLevel: s.zmodemOptions.traceLevel, traceURL: traceURL)
            traceHeader().forEach { x.trace?.note($0) }
            return x
        }
    }

    /// Types a command for the remote at the pace typing uses, since a device that drops fast
    /// typing drops these too. With `wait`, blocks until it has gone out (or the transfer is
    /// cancelled, or 30 s pass).
    func typeCommand(_ command: String, wait: Bool) {
        let data = Data(command.utf8)
        guard commandPacer.pacing.isOn else {
            port.write(data)
            if wait { port.waitForPendingWrites(maxPending: 0, timeout: 5) }
            return
        }
        commandDone.withLock { commandPending = data.count }
        commandPacer.send(data)
        guard wait else { return }
        let deadline = Uptime.now + 30
        commandDone.lock()
        while commandPending > 0 && Uptime.now < deadline && !lock.withLock({ cancelRequested }) {
            _ = commandDone.wait(until: Date(timeIntervalSinceNow: min(0.1, max(0, deadline - Uptime.now))))
        }
        commandDone.unlock()
        port.waitForPendingWrites(maxPending: 0, timeout: 5)
    }

    /// Input a transfer didn't use (the remote's prompt after it, or text that only looked like a
    /// transfer starting): log and display it. Not scanned for transfers, so it can't restart one.
    private func showAfterTransfer(_ data: Data) {
        lock.withLock { logger }?.log(.rx, data)
        onDisplay?(data)
    }

    public func cancelTransfer() {
        let active: FileTransfer? = lock.withLock {
            if let t = transfer, t.kind.isBlockProtocol {
                // X/YMODEM receivers only see CAN at a block boundary; one that got the abort
                // mid-block treats it as a bad block and NAKs. Watch for that and abort again.
                cancelWatchUntil = Uptime.now + 15
                cancelRetries = 4
            }
            if transfer != nil { cancelRequested = true }
            return transfer
        }
        commandPacer.cancel()
        active?.cancel()
    }

    /// Three failed automatic starts within 30 s pause automatic starts for 30 s, so a remote
    /// stuck starting and aborting transfers can't restart one many times a second.
    private func automaticResult(success: Bool) {
        let paused: Bool = lock.withLock {
            let now = Uptime.now
            guard !success else {
                automaticFailures.removeAll()
                return false
            }
            automaticFailures = automaticFailures.filter { now - $0 < 30 } + [now]
            guard automaticFailures.count >= 3 else { return false }
            automaticFailures.removeAll()
            automaticPausedUntil = now + 30
            return true
        }
        guard paused else { return }
        let text = "Automatic transfers paused for 30 s after repeated failures"
        lock.withLock { logger }?.note(text)
        onEvent?(.notice(text))
    }

    /// Tell a waiting remote `rz` to give up.
    public func abortRemoteTransfer() {
        port.write(TransferKind.abortSequence)
    }

    public struct TransferInProgress: Error, CustomStringConvertible {
        public var description: String { "A transfer is already in progress" }
    }

    /// A transfer that failed to start after `transferStarted`; already reported with
    /// `transferFinished`.
    public struct TransferStartFailed: Error, CustomStringConvertible {
        public let underlying: Error
        public var description: String { "\(underlying)" }
    }

    // MARK: Receiving

    private func handleIncoming(_ data: Data) {
        let (active, logger, auto) = lock.withLock {
            (transfer, self.logger, settings.autoZmodem && automaticPausedUntil.map { Uptime.now >= $0 } ?? true)
        }

        if let active {
            commandPacer.received(data)  // the echo of a receive command being typed
            active.feed(data)
            return
        }

        logger?.log(.rx, data)
        pacer.received(data)
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
                // Hand over the opening frame so the trace shows it. When it began in an earlier
                // read, those bytes were shown already; rebuild them, as they can only be the prefix.
                let opening = match.carried > 0
                    ? Data(ZmodemDetector.prefix.prefix(match.carried)) + data
                    : data.suffix(from: data.startIndex + match.headerStart)
                try startTransfer(.zmodemReceive, primed: opening, startRemote: false, automatic: true)
            } catch {
                logger?.note("Auto ZMODEM receive failed: \(error)")
                abortRemoteTransfer()
                if !(error is TransferStartFailed) {
                    automaticResult(success: false)
                    onEvent?(.transferFinished(success: false, message: "\(error)"))
                }
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
            guard Uptime.now < until, cancelRetries > 0 else {
                cancelWatchUntil = nil
                return false
            }
            guard data.contains(Self.nak) else { return false }
            cancelRetries -= 1
            return true
        }
        if again {
            lock.withLock { logger }?.note("Remote still receiving after cancel (NAK); aborting again")
            port.write(TransferKind.abortSequence)
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
                try startTransfer(.ymodemReceive, primed: nil, startRemote: false, automatic: true)
            } catch {
                abortRemoteTransfer()
                if !(error is TransferStartFailed) {
                    automaticResult(success: false)
                    onEvent?(.transferFinished(success: false, message: "\(error)"))
                }
            }
        case Self.xmodemPrompt?:
            onEvent?(.remoteXmodemSending)
        default:
            break
        }
    }
}
