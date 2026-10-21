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
    @Published private(set) var lastTraceURL: URL?
    @Published private(set) var cols = 80
    @Published private(set) var rows = 24

    weak var terminalView: TerminalView? {
        didSet { applyTerminalPrefs() }
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
    /// A remote `rz` repeats its ready header while we wait; show only one file picker.
    private var choosingFilesForRemote = false

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
    }

    var isTransferring: Bool { transferStatus != nil }

    // MARK: Connection

    func toggleConnection(ports: [SerialPortInfo]) {
        if isConnected {
            wantConnected = false
            disconnect()
        } else {
            connect(ports: ports)
        }
    }

    func connect(ports: [SerialPortInfo]) {
        guard let path = connection.portPath else {
            statusMessage = "Choose a port first"
            return
        }
        disconnect()

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
        session.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
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
        statusMessage = "Connected"
        banner("Connected: \(path.replacingOccurrences(of: "/dev/", with: "")) \(connection.config.summary)")
        focusTerminal()
        if let sn = ports.first(where: { $0.path == path })?.usbSerialNumber {
            connection.portSerialNumber = sn
        }
        if prefs.loggingEnabled { startLogging() }
    }

    func disconnect() {
        if session != nil { banner("Disconnected") }
        session?.stopLogging()
        session?.close()
        session = nil
        isConnected = false
        logURL = nil
        transferStatus = nil
        pacedRemaining = 0
        pacedEchoMissing = false
        statusMessage = "Not connected"
    }

    /// Called with the initial port list and whenever it changes (hot-plug).
    func portsChanged(_ ports: [SerialPortInfo]) {
        knownPorts = ports
        guard prefs.autoReconnect, wantConnected, !isConnected else { return }
        // Prefer the same physical dongle, which may come back under a different path.
        let match = ports.first { p in
            if let sn = connection.portSerialNumber, !sn.isEmpty { return p.usbSerialNumber == sn }
            return p.path == connection.portPath
        }
        guard let match else { return }
        if connection.portPath != match.path {
            connection.portPath = match.path  // connects via connectionChanged
        } else {
            connect(ports: ports)
        }
        if isConnected { statusMessage = "Reconnected" }
    }

    // MARK: Terminal I/O

    func sendFromTerminal(_ bytes: ArraySlice<UInt8>) {
        if session == nil {
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
        session?.port.sendBreak()
    }

    func clearScreen() {
        terminalView?.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
    }

    // MARK: Logging

    func toggleLogging() {
        settings.prefs.loggingEnabled.toggle()
    }

    private func startLogging() {
        guard let session else { return }
        let url = prefs.logDirectory.appendingPathComponent(SessionLogger.defaultFileName())
        do {
            try session.startLogging(to: url)
            logURL = url
        } catch {
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
        guard isConnected, !isTransferring else { return }
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
        guard let session else { return }
        do {
            try session.startTransfer(kind, startRemote: startRemote)
        } catch {
            statusMessage = "\(error)"
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

    private func present(_ panel: NSSavePanel, then: @escaping (Bool) -> Void) {
        if let window = terminalView?.window {
            panel.beginSheetModal(for: window) { then($0 == .OK) }
        } else {
            then(panel.runModal() == .OK)
        }
    }

    // MARK: Events

    private func handle(_ event: SessionEvent) {
        switch event {
        case let .transferStarted(name):
            transferStatus = name
            if let url = session?.lastTraceURL { lastTraceURL = url }
        case let .transferStatus(line):
            if transferStatus != nil { transferStatus = line }
        case let .transferFinished(success, message):
            transferStatus = nil
            let traced = lastTraceURL != nil && !prefs.useLrzszForZmodem && prefs.zmodem.traceLevel != .off
            statusMessage = success ? message : "Transfer failed: \(message)" + (traced ? " — see Transfer ▸ Open Last ZMODEM Trace" : "")
            if !success { NSSound.beep() }
        case .remoteWaitingForFiles:
            guard !choosingFilesForRemote else { return }
            choosingFilesForRemote = true
            chooseFiles(multiple: true) { [weak self] urls in
                guard let self else { return }
                self.choosingFilesForRemote = false
                guard let session = self.session else { return }
                if let urls, !urls.isEmpty {
                    self.startTransfer(.zmodemSend(urls))
                } else {
                    session.abortRemoteTransfer()
                }
            }
        case .remoteXmodemSending:
            // XMODEM carries no file name, so ask where to save.
            let panel = NSSavePanel()
            panel.directoryURL = prefs.downloadDirectory
            panel.message = "The device is sending a file by XMODEM, which carries no name. Save it as:"
            present(panel) { [weak self] ok in
                guard let self, let session = self.session else { return }
                if ok, let url = panel.url {
                    self.startTransfer(.xmodemReceive(url))
                } else {
                    session.abortRemoteTransfer()
                }
            }
        case let .pacedTyping(remaining, echoMissing):
            pacedRemaining = remaining
            pacedEchoMissing = echoMissing
        case let .disconnected(error):
            guard session != nil else { return }
            disconnect()
            if let error { statusMessage = "Disconnected: \(error)" }
        }
    }

    // MARK: Settings

    private func connectionChanged(from old: ConnectionSettings) {
        settings.prefs.lastConnection = connection
        if connection.backspaceSendsControlH != old.backspaceSendsControlH { applyTerminalPrefs() }
        if connection.portPath != old.portPath {
            // Choosing a port connects to it; choosing another switches over.
            wantConnected = false
            disconnect()
            if connection.portPath != nil { connect(ports: knownPorts) }
            return
        }
        guard let session else { return }
        session.pacing = connection.pacing
        session.zmodemReceiveCommand = connection.zmodemReceiveCommand
        if connection.config != old.config {
            do {
                try session.port.reconfigure(connection.config)
                banner(connection.config.summary)
                focusTerminal()
            } catch {
                statusMessage = "\(error)"
            }
        }
    }

    // MARK: Presets

    /// The saved preset this window's settings match, if any; one naming this port wins.
    var currentPreset: ConnectionPreset? {
        prefs.presets.first { $0.matches(connection, includingPort: true) } ?? prefs.presets.first { $0.matches(connection) }
    }

    func applyPreset(_ preset: ConnectionPreset) {
        var c = connection
        c.apply(preset)
        var missing: PresetPort?
        if let port = preset.port {
            // Prefer the same device or adapter, wherever it is now.
            let found = port.find(in: knownPorts)
            if found == nil { missing = port }
            c.portPath = found?.path ?? port.path
            c.portSerialNumber = found?.usbSerialNumber ?? port.serialNumber
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
        return PresetPort(path: path, serialNumber: connection.portSerialNumber)
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
                if new.loggingEnabled { startLogging() }
            }
        }
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
            let bytes: [UInt8] = lock.withLock {
                scheduled = false
                defer { pending.removeAll(keepingCapacity: true) }
                return pending
            }
            MainActor.assumeIsolated { flush?(bytes) }
        }
    }
}
