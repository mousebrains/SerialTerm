// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import AppKit
import Combine
import SerialCore
import SwiftTerm

/// State and actions for one terminal window.
@MainActor
final class TerminalModel: ObservableObject {
    /// This window's port and line settings.
    @Published var connection: ConnectionSettings {
        didSet { connectionChanged(from: oldValue) }
    }

    @Published private(set) var isConnected = false
    @Published private(set) var statusMessage = "Not connected"
    @Published private(set) var transferStatus: String?
    /// Typed or pasted characters still waiting to go out under pacing.
    @Published private(set) var pacedRemaining = 0
    /// With wait-for-echo: the last paced character got no echo in time.
    @Published private(set) var pacedEchoMissing = false
    @Published private(set) var logURL: URL?
    /// Why this window has no log open although logging is on (couldn't open it, or it stopped).
    @Published private(set) var logProblem: String?
    @Published private(set) var lastTraceURL: URL?
    @Published private(set) var cols = 80
    @Published private(set) var rows = 24

    weak var terminalView: TerminalView? {
        didSet {
            terminalView?.optionAsMetaKey = prefs.optionAsMeta
            applyTerminalPrefs()
        }
    }

    let settings: AppSettings
    /// App-wide settings (shared by all windows; edited in the Settings window).
    var prefs: Preferences { settings.prefs }

    private var session: Session?
    /// Latest port list from the scanner.
    private var knownPorts: [SerialPortInfo] = []
    private let display = DisplayBuffer()
    private var appliedPrefs: Preferences
    private var settingsObserver: AnyCancellable?
    /// True when the user wants to be connected; drives auto-reconnect after an unplug.
    private var wantConnected = false
    /// Bumped when the user connects, disconnects or picks a port, so a pending reconnect retry stands down.
    private var reconnectGeneration = 0
    /// Reconnecting to the device the window was using: keep the terminal's modes.
    private var reconnecting = false
    /// A file panel for a transfer is open. A remote `rz` repeats its ready header while it
    /// waits, and an `sx` prompt can arrive meanwhile; show one panel at a time.
    private var transferPanelOpen = false
    /// Transfers this window started (menus, drops, file prompts) whose `transferStarted`
    /// hasn't arrived yet. Anything else was started automatically by the remote.
    private var userStartsPending = 0
    /// About the running transfer: started by the user, the trace it writes (built-in ZMODEM
    /// with tracing on), and whether the user cancelled it.
    private var transferByUser = false
    private var transferTrace: URL?
    private var transferCancelled = false
    /// Set while connection changes are applied without their usual effects.
    private var restoring = false
    private var revertingConfig = false
    private var restoreAllowed = true

    /// Open windows, for confirming before quitting during a transfer.
    private static let all = NSHashTable<TerminalModel>.weakObjects()
    /// Ports closing in the background, by path (see `disconnect`). A port is held exclusively
    /// until it has closed, so opening it again waits for that, and so does quitting.
    private static var closing: [String: DispatchGroup] = [:]

    init(settings: AppSettings? = nil) {
        let settings = settings ?? .shared
        self.settings = settings
        connection = settings.prefs.lastConnection
        appliedPrefs = settings.prefs
        display.flush = { [weak self] bytes in
            self?.terminalView?.feed(byteArray: bytes[...])
        }
        settingsObserver = settings.$prefs.sink { [weak self] new in
            // $prefs publishes before the value is stored; apply on the next turn.
            DispatchQueue.main.async { self?.prefsChanged(to: new) }
        }
        Self.all.add(self)
    }

    var isTransferring: Bool { transferStatus != nil }
    var canStartTransfer: Bool { isConnected && !isTransferring }

    /// Windows with a transfer running.
    static var transfersRunning: Int { all.allObjects.filter(\.isTransferring).count }

    /// At quit: close every port, so running transfers are cancelled and the devices told to stop.
    static func disconnectAll() {
        for model in all.allObjects { model.disconnect() }
        let deadline = DispatchTime.now() + 3
        for group in closing.values { _ = group.wait(timeout: deadline) }
        closing.removeAll()
    }

    // MARK: Connection

    func toggleConnection(ports: [SerialPortInfo]) {
        if isConnected {
            wantConnected = false
            reconnectGeneration += 1
            disconnect()
        } else {
            connect(ports: ports)
        }
    }

    /// The user picked a port in the toolbar.
    func choosePort(_ path: String?) {
        guard path != connection.portPath else { return }
        var c = connection
        c.setPort(path, info: knownPorts.first { $0.path == path })
        connection = c  // connects via connectionChanged
    }

    /// A window reopened at launch gets its own settings back (without connecting); new windows
    /// start from the most recently used ones instead.
    func restore(_ saved: ConnectionSettings) {
        guard restoreAllowed else { return }
        restoreAllowed = false
        restoring = true
        connection = saved
        restoring = false
        applyTerminalPrefs()
    }

    func connect(ports: [SerialPortInfo]) {
        guard let path = connection.portPath else {
            statusMessage = "Choose a port first"
            return
        }
        disconnect()
        restoreAllowed = false
        if let closing = Self.closing.removeValue(forKey: path) { _ = closing.wait(timeout: .now() + 3) }

        let port = SerialPort(path: path, config: connection.config)
        let session = Session(port: port, downloadDirectory: prefs.downloadDirectory)
        session.autoZmodem = prefs.autoZmodem
        session.useExternalZmodem = prefs.useLrzszForZmodem
        session.zmodemOptions = prefs.zmodem
        session.xmodem1K = prefs.xmodem1K
        session.traceDirectory = prefs.logDirectory
        session.pacing = connection.pacing
        session.zmodemReceiveCommand = connection.zmodemReceiveCommand
        session.onDisplay = { [display] data in display.append(data) }
        session.onEvent = { [weak self, weak session] event in
            Task { @MainActor in
                // Late events from a session this window has closed or replaced are stale: a
                // `disconnected` from the old port must not close the new one.
                guard let self, let session, self.session === session else { return }
                self.handle(event)
            }
        }

        do {
            try session.open()
        } catch {
            statusMessage = "\(error)"
            return
        }

        self.session = session
        isConnected = true
        wantConnected = true
        reconnectGeneration += 1
        statusMessage = "Connected"
        // Modes the previous device turned on would otherwise apply to this one.
        if !reconnecting { resetTerminalModes() }
        banner("Connected: \(path.replacingOccurrences(of: "/dev/", with: "")) \(connection.config.summary)")
        focusTerminal()
        if let info = ports.first(where: { $0.path == path }),
           info.usbSerialNumber != connection.portSerialNumber || info.usbInterface != connection.portInterface {
            // Remember which adapter this is, including that it has no serial number.
            var c = connection
            c.setPort(path, info: info)
            connection = c
        }
        if prefs.loggingEnabled { startLogging() }
    }

    func disconnect() {
        // The device's last output goes before the banner.
        display.flushNow()
        if session != nil { banner("Disconnected") }
        session?.stopLogging()
        // Cancels a running transfer and tells the remote to stop. That can take a moment, so
        // with a transfer running it happens in the background, without holding up the window.
        if let session, session.isTransferring {
            let closed = DispatchGroup()
            closed.enter()
            Self.closing[session.port.path] = closed
            session.closeInBackground { closed.leave() }
        } else {
            session?.close()
        }
        session = nil
        isConnected = false
        logURL = nil
        logProblem = nil
        transferStatus = nil
        transferByUser = false
        transferTrace = nil
        transferCancelled = false
        userStartsPending = 0
        pacedRemaining = 0
        pacedEchoMissing = false
        statusMessage = "Not connected"
    }

    /// Called with the initial port list and whenever it changes (hot-plug).
    func portsChanged(_ ports: [SerialPortInfo]) {
        knownPorts = ports
        reconnectGeneration += 1  // starts over: any pending retry stands down
        reconnectIfWanted(attempt: 0)
    }

    private func reconnectIfWanted(attempt: Int) {
        guard prefs.autoReconnect, wantConnected, !isConnected else { return }
        // The same physical device, which may come back under a different path.
        guard let match = SerialPortInfo.find(path: connection.portPath, serialNumber: connection.portSerialNumber,
                                              interface: connection.portInterface, in: knownPorts) else { return }
        reconnecting = true
        if connection.portPath != match.path {
            var c = connection
            c.setPort(match.path, info: match)
            connection = c  // connects via connectionChanged
        } else {
            connect(ports: knownPorts)
        }
        reconnecting = false
        if isConnected {
            statusMessage = "Reconnected"
            return
        }
        // Still wanted (connectionChanged clears it when the path changes). A device that has just
        // appeared may not be ready, and no further hot-plug event may come, so retry a few times.
        wantConnected = true
        guard attempt < 3 else { return }
        let generation = reconnectGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.reconnectGeneration == generation else { return }
            self.reconnectIfWanted(attempt: attempt + 1)
        }
    }

    // MARK: Terminal I/O

    /// Bytes from the terminal view. `fromUser` is false for replies the terminal makes by itself
    /// (focus and mouse reports, answers to queries): those go to a connected device, but must not
    /// reconnect a window the user disconnected.
    func sendFromTerminal(_ bytes: ArraySlice<UInt8>, fromUser: Bool) {
        if session == nil {
            guard fromUser else { return }
            // Typing at a disconnected terminal connects to the selected port, then sends the key.
            if connection.portPath != nil { connect(ports: knownPorts) }
            guard session != nil else {
                NSSound.beep()
                if connection.portPath == nil { statusMessage = "Not connected — choose a port in the toolbar" }
                return
            }
        }
        session?.sendFromUser(Data(bytes))
    }

    /// Name of the selected port for the connect bar, e.g. "P113 Board (usbmodemp113r03_0432)".
    var selectedPortName: String? {
        guard let path = connection.portPath else { return nil }
        return knownPorts.first { $0.path == path }?.displayName ?? path.replacingOccurrences(of: "/dev/", with: "")
    }

    /// Put keyboard focus back in the terminal (e.g. after using a toolbar control).
    func focusTerminal() {
        guard let tv = terminalView else { return }
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }

    /// A dim local status line in the terminal; never sent to the device.
    private func banner(_ text: String) {
        terminalView?.feed(text: "\r\n\u{1b}[2m[\(text)]\u{1b}[0m\r\n")
    }

    private func resetTerminalModes() {
        terminalView?.feed(text: TerminalModeReset.sequence)
    }

    func terminalResized(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// A serial line can't tell the remote the window size; this does it via stty.
    func sendWindowSize() {
        session?.sendFromUser(Data("stty rows \(rows) cols \(cols)\r".utf8))
    }

    func cancelPacedTyping() {
        session?.cancelPacedTyping()
    }

    func sendBreak() {
        guard !isTransferring else { return }
        session?.port.sendBreak()
    }

    func clearScreen() {
        terminalView?.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
    }

    // MARK: Logging

    /// What the Log button shows.
    enum LogState: Equatable {
        case off
        /// On; a log starts when the window connects.
        case waiting
        case recording(URL)
        /// On, connected, but no log is open.
        case failed(String)
    }

    var logState: LogState {
        guard prefs.loggingEnabled else { return .off }
        if let logURL { return .recording(logURL) }
        return isConnected ? .failed(logProblem ?? "No log is open") : .waiting
    }

    func toggleLogging() {
        settings.prefs.loggingEnabled.toggle()
    }

    private func startLogging() {
        guard let session else { return }
        let url = prefs.logDirectory.appendingPathComponent(SessionLogger.defaultFileName())
        do {
            logURL = try session.startLogging(to: url)
            logProblem = nil
        } catch {
            logProblem = "Cannot open a log in \(prefs.logDirectory.path): \(error.localizedDescription)"
            statusMessage = "Cannot open log: \(error.localizedDescription)"
        }
    }

    func revealLog() {
        if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
    }

    // MARK: Transfers

    func sendFiles(_ protocolName: BatchProtocol) {
        chooseFiles(multiple: true) { [weak self] urls in
            guard let urls else { return }
            // YMODEM's sender doesn't start the remote receiver; type "rb" for it.
            self?.startTransfer(protocolName == .zmodem ? .zmodemSend(urls) : .ymodemSend(urls),
                                startRemote: protocolName == .ymodem)
        }
    }

    func sendFiles(_ urls: [URL]) {
        guard canStartTransfer, !transferPanelOpen else {
            NSSound.beep()
            statusMessage = isConnected ? "A transfer is already running" : "Connect before dropping files to send"
            return
        }
        startTransfer(.zmodemSend(urls))
    }

    func receiveZmodem() { startTransfer(.zmodemReceive) }
    func receiveYmodem() { startTransfer(.ymodemReceive) }

    func sendXmodem() {
        chooseFiles(multiple: false) { [weak self] urls in
            guard let url = urls?.first else { return }
            self?.startTransfer(.xmodemSend(url), startRemote: true)  // types "rx name" first
        }
    }

    func receiveXmodem() {
        let panel = NSSavePanel()
        panel.directoryURL = prefs.downloadDirectory
        panel.message = "XMODEM does not send a file name. Save the incoming file as:"
        present(panel) { [weak self] ok in
            guard ok, let url = panel.url else { return }
            self?.startTransfer(.xmodemReceive(url))
        }
    }

    func cancelTransfer() {
        guard isTransferring else { return }
        transferCancelled = true
        session?.cancelTransfer()
    }

    /// Opens the most recent ZMODEM protocol trace (in Console, the default app for .log files).
    func openLastTrace() {
        if let lastTraceURL { NSWorkspace.shared.open(lastTraceURL) }
    }

    func revealDownloads() {
        NSWorkspace.shared.open(prefs.downloadDirectory)
    }

    private func startTransfer(_ kind: TransferKind, startRemote: Bool = false) {
        guard let session else {
            statusMessage = "Not connected"
            NSSound.beep()
            return
        }
        do {
            try session.startTransfer(kind, startRemote: startRemote)
            userStartsPending += 1
        } catch is Session.TransferStartFailed {
            userStartsPending += 1  // reported by its transferStarted and transferFinished
        } catch {
            // Refused (one is already running) or couldn't be set up; nothing else reports it.
            statusMessage = "\(error)"
            NSSound.beep()
        }
    }

    private func chooseFiles(multiple: Bool, then: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = prefs.uploadDirectory
        panel.message = multiple ? "Choose one or more files to send (⌘-click to select several)" : "Choose a file to send"
        present(panel) { [weak self] ok in
            if ok, let dir = panel.urls.first?.deletingLastPathComponent() {
                // Start the next upload where this one was chosen.
                self?.settings.prefs.uploadDirectory = dir
            }
            then(ok ? panel.urls : nil)
        }
    }

    /// Shows a transfer's file panel, one at a time (see `transferPanelOpen`).
    private func present(_ panel: NSSavePanel, then: @escaping (Bool) -> Void) {
        guard !transferPanelOpen else {
            NSSound.beep()
            return
        }
        transferPanelOpen = true
        let done: (Bool) -> Void = { [weak self] ok in
            self?.transferPanelOpen = false
            then(ok)
        }
        if let window = terminalView?.window {
            panel.beginSheetModal(for: window) { done($0 == .OK) }
        } else {
            done(panel.runModal() == .OK)
        }
    }

    // MARK: Events

    private func handle(_ event: SessionEvent) {
        switch event {
        case let .transferStarted(name):
            transferStatus = name
            transferByUser = userStartsPending > 0
            userStartsPending = max(0, userStartsPending - 1)
            transferCancelled = false
            // A new trace file means this is a built-in ZMODEM transfer that writes one.
            let trace = session?.lastTraceURL
            transferTrace = trace != nil && trace != lastTraceURL ? trace : nil
            if let trace { lastTraceURL = trace }
        case let .transferStatus(line):
            if transferStatus != nil { transferStatus = line }
        case let .transferFinished(success, message):
            // Without transferStarted first, an automatic start was refused or couldn't be set up.
            let started = transferStatus != nil
            let byUser = started && transferByUser, trace = started ? transferTrace : nil
            let cancelled = started && transferCancelled
            transferStatus = nil
            transferByUser = false
            transferTrace = nil
            transferCancelled = false
            if success {
                statusMessage = message
            } else if cancelled {
                statusMessage = "Transfer cancelled"
            } else {
                statusMessage = "Transfer failed: \(message)" + (trace != nil ? " — see Transfer ▸ Open Last ZMODEM Trace" : "")
                // An automatic transfer is the remote's doing; beep only for one the user asked for.
                if byUser { NSSound.beep() }
            }
        case .remoteWaitingForFiles:
            guard !transferPanelOpen, let asking = session else { return }
            chooseFiles(multiple: true) { [weak self, weak asking] urls in
                // Answer only the session that asked; after a reconnect it may be another device.
                guard let self, let session = self.session, session === asking else { return }
                if let urls, !urls.isEmpty {
                    self.startTransfer(.zmodemSend(urls))
                } else {
                    session.abortRemoteTransfer()
                }
            }
        case .remoteXmodemSending:
            guard !transferPanelOpen, let asking = session else { return }
            // XMODEM carries no file name, so ask where to save.
            let panel = NSSavePanel()
            panel.directoryURL = prefs.downloadDirectory
            panel.message = "The device is sending a file by XMODEM, which carries no name. Save it as:"
            present(panel) { [weak self, weak asking] ok in
                guard let self, let session = self.session, session === asking else { return }
                if ok, let url = panel.url {
                    self.startTransfer(.xmodemReceive(url))
                } else {
                    session.abortRemoteTransfer()
                }
            }
        case let .pacedTyping(remaining, echoMissing):
            pacedRemaining = remaining
            pacedEchoMissing = echoMissing
        case let .logFailed(message):
            logURL = nil
            logProblem = "The log stopped: \(message)"
            statusMessage = "Session log stopped: \(message)"
        case let .notice(message):
            statusMessage = message
        case let .disconnected(error):
            let stoppedTransfer = isTransferring
            disconnect()
            // The transfer's own finish comes later from a session that is no longer current, so
            // it is dropped and the reason for the disconnect stays visible.
            if let error {
                statusMessage = "Disconnected: \(error)" + (stoppedTransfer ? " — the transfer was stopped" : "")
            } else if stoppedTransfer {
                statusMessage = "Disconnected — the transfer was stopped"
            }
        }
    }

    // MARK: Settings

    private func connectionChanged(from old: ConnectionSettings) {
        guard !restoring, !revertingConfig else { return }
        if connection.backspaceSendsControlH != old.backspaceSendsControlH { applyTerminalPrefs() }
        if connection.portPath != old.portPath {
            settings.prefs.lastConnection = connection
            // Choosing a port connects to it; choosing another switches over.
            wantConnected = false
            reconnectGeneration += 1
            disconnect()
            if connection.portPath != nil { connect(ports: knownPorts) }
            return
        }
        if let session {
            session.pacing = connection.pacing
            session.zmodemReceiveCommand = connection.zmodemReceiveCommand
            if connection.config != old.config {
                if isTransferring {
                    revertConfig(to: old.config, because: "Line settings can't change during a transfer")
                } else {
                    do {
                        try session.port.reconfigure(connection.config)
                        banner(connection.config.summary)
                        focusTerminal()
                    } catch {
                        // The port kept its settings; show (and save) those, not the refused ones.
                        revertConfig(to: old.config, because: "\(error)")
                    }
                }
            }
        }
        settings.prefs.lastConnection = connection
    }

    private func revertConfig(to config: SerialConfig, because reason: String) {
        statusMessage = "\(reason); still \(config.summary)"
        NSSound.beep()
        revertingConfig = true
        connection.config = config
        revertingConfig = false
    }

    // MARK: Presets

    /// The saved preset this window's settings match, if any; one naming this port wins.
    var currentPreset: ConnectionPreset? {
        prefs.presets.first { $0.port != nil && $0.matches(connection, includingPort: true) }
            ?? prefs.presets.first { $0.matches(connection) }
    }

    func applyPreset(_ preset: ConnectionPreset) {
        var c = connection
        c.apply(preset)
        var missing: PresetPort?
        if let port = preset.port {
            // Prefer the same device or adapter, wherever it is now.
            if let found = port.find(in: knownPorts) {
                c.setPort(found.path, info: found)
            } else {
                missing = port
                c.portPath = port.path
                c.portSerialNumber = port.serialNumber
                c.portInterface = port.interface
            }
        }
        connection = c  // one change: a new port connects, the same port is reconfigured
        if let missing {
            statusMessage = "\(preset.name): \(missing.displayName) is not plugged in"
        } else if !isConnected, preset.port == nil {
            statusMessage = "Preset: \(preset.name)"
        }
    }

    /// The window's current port, in the form a preset stores it.
    var currentPresetPort: PresetPort? {
        guard let path = connection.portPath else { return nil }
        if let info = knownPorts.first(where: { $0.path == path }) { return PresetPort(info) }
        return PresetPort(path: path, serialNumber: connection.portSerialNumber, interface: connection.portInterface)
    }

    /// Save this window's settings under `name`, replacing a preset of that name.
    func saveCurrentAsPreset(named name: String, includePort: Bool) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        settings.prefs.savePreset(ConnectionPreset(name: name, from: connection, port: includePort ? currentPresetPort : nil))
    }

    func deletePreset(_ preset: ConnectionPreset) {
        settings.prefs.presets.removeAll { $0.id == preset.id }
    }

    private func prefsChanged(to new: Preferences) {
        let old = appliedPrefs
        appliedPrefs = new
        objectWillChange.send()
        if let session {
            session.autoZmodem = new.autoZmodem
            session.useExternalZmodem = new.useLrzszForZmodem
            session.zmodemOptions = new.zmodem
            session.xmodem1K = new.xmodem1K
            session.traceDirectory = new.logDirectory
            session.downloadDirectory = new.downloadDirectory
            if new.loggingEnabled != old.loggingEnabled || new.logDirectory != old.logDirectory {
                session.stopLogging()
                logURL = nil
                logProblem = nil
                if new.loggingEnabled { startLogging() }
            }
        }
        // Only on a change: ⌥⌘O toggles it for one window, and that should stick until then.
        if new.optionAsMeta != old.optionAsMeta { terminalView?.optionAsMetaKey = new.optionAsMeta }
        applyTerminalPrefs()
    }

    private func applyTerminalPrefs() {
        guard let tv = terminalView else { return }
        tv.backspaceSendsControlH = connection.backspaceSendsControlH
        if tv.font.pointSize != prefs.fontSize {
            tv.font = NSFont.monospacedSystemFont(ofSize: prefs.fontSize, weight: .regular)
        }
    }

    enum BatchProtocol { case zmodem, ymodem }
}

/// Turns off what a previous device may have left on: mouse and focus reports, bracketed paste,
/// the kitty keyboard protocol (in both screens), the alternate screen; then DECSTR. Fed to the
/// terminal locally, never sent. Leaving the alternate screen (1049) restores the cursor saved
/// in the normal screen; saving it first (ESC 7) keeps it in place when that screen is in use.
enum TerminalModeReset {
    static let sequence = "\u{1b}[<99u\u{1b}7\u{1b}[?1049l\u{1b}[<99u"
        + [1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004].map { "\u{1b}[?\($0)l" }.joined()
        + "\u{1b}[!p"
}

/// Collects bytes arriving on the serial read queue and hands them to the terminal on
/// the main thread in batches, so a 2–3 Mbaud stream doesn't flood the main queue.
private final class DisplayBuffer: @unchecked Sendable {
    var flush: (@MainActor ([UInt8]) -> Void)?
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var scheduled = false

    func append(_ data: Data) {
        let needsSchedule: Bool = lock.withLock {
            pending.append(contentsOf: data)
            defer { scheduled = true }
            return !scheduled
        }
        guard needsSchedule else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { flushNow() }
        }
    }

    /// Hands over what has arrived so far (the scheduled flush then finds nothing).
    @MainActor
    func flushNow() {
        let bytes: [UInt8] = lock.withLock {
            scheduled = false
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        if !bytes.isEmpty { flush?(bytes) }
    }
}
