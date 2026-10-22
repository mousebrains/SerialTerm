// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import SerialCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var scanner: PortScanner
    @StateObject private var model = TerminalModel()
    // Not SwiftUI's `State`: in the macOS 27 SDK it is a macro whose compiler plugin ships only
    // with Xcode, and SerialTerm builds with the Command Line Tools alone. CI rejects it.
    @StateObject private var popovers = PopoverState()
    /// This window's port and line settings, so a window reopened at launch gets its own back.
    @SceneStorage("connection") private var savedConnection = Data()

    var body: some View {
        VStack(spacing: 0) {
            if !model.isConnected {
                connectBar
                Divider()
            }
            TerminalContainer(model: model)
                .frame(minWidth: 400, minHeight: 200)
            Divider()
            statusBar
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 360, idealHeight: 560)
        .toolbar { toolbar }
        .onAppear {
            if let saved = try? JSONDecoder().decode(ConnectionSettings.self, from: savedConnection) {
                model.restore(saved)
            }
            saveConnection(model.connection)
            model.portsChanged(scanner.ports)
        }
        .onChange(of: scanner.ports) { _, ports in model.portsChanged(ports) }
        .onChange(of: model.connection) { _, connection in saveConnection(connection) }
        // Closing the window would cut the transfer off; cancel it first (quitting asks).
        .windowDismissBehavior(model.isTransferring ? .disabled : .automatic)
        .navigationTitle(windowTitle)
    }

    private func saveConnection(_ connection: ConnectionSettings) {
        savedConnection = (try? JSONEncoder().encode(connection)) ?? Data()
    }

    private var windowTitle: String {
        guard let path = model.connection.portPath else { return "SerialTerm" }
        return path.replacingOccurrences(of: "/dev/", with: "")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("Port", selection: Binding(get: { model.connection.portPath }, set: { model.choosePort($0) })) {
                Text("Choose port…").tag(String?.none)
                ForEach(scanner.ports) { port in
                    Text(port.displayName).tag(String?.some(port.path))
                }
                // Keep a remembered port visible while it's unplugged.
                if let path = model.connection.portPath, !scanner.ports.contains(where: { $0.path == path }) {
                    Text("\(path) (not present)").tag(String?.some(path))
                }
            }
            .frame(maxWidth: 260)
            .help("Serial port")
            .disabled(model.isTransferring)

            baudPicker
                .disabled(model.isTransferring)
            presetMenu
                .disabled(model.isTransferring)

            Button {
                model.toggleConnection(ports: scanner.ports)
            } label: {
                Label(model.isConnected ? "Disconnect" : "Connect",
                      systemImage: model.isConnected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
            }
            .help(model.isConnected ? "Disconnect (⇧⌘K)" : "Connect (⇧⌘K)")
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }

        ToolbarItemGroup(placement: .primaryAction) {
            transferMenu
            logButton

            lineMenu
            Button {
                popovers.showLineSettings.toggle()
            } label: {
                Label("Line Settings", systemImage: "slider.horizontal.3")
            }
            .help("Data bits, parity, stop bits, flow control, Backspace key, typing pace")
            .disabled(model.isTransferring)
            .popover(isPresented: $popovers.showLineSettings, arrowEdge: .bottom) {
                LineSettingsView(config: $model.connection.config,
                                 backspaceSendsControlH: $model.connection.backspaceSendsControlH,
                                 pacing: $model.connection.pacing,
                                 zmodemReceiveCommand: $model.connection.zmodemReceiveCommand)
            }
        }
    }

    private var logButton: some View {
        let state = model.logState
        let icon: String, color: Color, help: String
        switch state {
        case .off:
            (icon, color, help) = ("record.circle", .primary, "Start logging (folder is set in Settings)")
        case .waiting:
            (icon, color, help) = ("record.circle.fill", .secondary, "Logging is on: a log starts when you connect. Click to turn it off.")
        case .recording:
            (icon, color, help) = ("record.circle.fill", .red, "Stop logging")
        case let .failed(problem):
            (icon, color, help) = ("exclamationmark.triangle", .orange, "Logging is on, but this window has no log: \(problem). Click to turn logging off.")
        }
        return Button {
            model.toggleLogging()
        } label: {
            Label("Log", systemImage: icon)
        }
        .foregroundStyle(color)
        .help(help)
    }

    private var baudPicker: some View {
        let rates = SerialConfig.commonBaudRates
        let current = model.connection.config.baudRate
        return Menu {
            ForEach(rates, id: \.self) { rate in
                Button {
                    model.connection.config.baudRate = rate
                } label: {
                    if rate == current { Label("\(rate)", systemImage: "checkmark") } else { Text("\(rate)") }
                }
            }
            Divider()
            Button("Custom…") {
                popovers.customBaud = "\(current)"
                popovers.customBaudInvalid = false
                popovers.showCustomBaud = true
            }
        } label: {
            Text("\(current) baud").monospacedDigit()
        }
        .frame(minWidth: 120)
        .help("Baud rate")
        .popover(isPresented: $popovers.showCustomBaud, arrowEdge: .bottom) {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Baud rate", text: $popovers.customBaud)
                        .frame(width: 120)
                        .onSubmit(applyCustomBaud)
                    Button("Set", action: applyCustomBaud)
                        .keyboardShortcut(.defaultAction)
                }
                if popovers.customBaudInvalid {
                    Text("Type a whole number of baud, digits only, e.g. 250000")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .onChange(of: popovers.customBaud) { popovers.customBaudInvalid = false }
        }
    }

    private func applyCustomBaud() {
        guard let rate = SerialConfig.parseBaudRate(popovers.customBaud) else {
            popovers.customBaudInvalid = true
            return
        }
        model.connection.config.baudRate = rate
        popovers.showCustomBaud = false
    }

    private var presetMenu: some View {
        let current = model.currentPreset
        return Menu {
            ForEach(model.prefs.presets) { preset in
                Button {
                    model.applyPreset(preset)
                } label: {
                    let title = "\(preset.name) — \(preset.summary)" + (preset.port.map { " · \($0.displayName)" } ?? "")
                    if preset.id == current?.id { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            if !model.prefs.presets.isEmpty { Divider() }
            Button("Save Current Settings as Preset…") {
                popovers.presetName = current?.name ?? ""
                popovers.presetIncludesPort = current.map { $0.port != nil } ?? (model.connection.portPath != nil)
                popovers.showSavePreset = true
            }
            if !model.prefs.presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(model.prefs.presets) { preset in
                        Button(preset.name) { model.deletePreset(preset) }
                    }
                }
            }
        } label: {
            Text(current?.name ?? "Presets").lineLimit(1)
        }
        .frame(minWidth: 100, maxWidth: 180)
        .help("Saved line and keyboard settings")
        .popover(isPresented: $popovers.showSavePreset, arrowEdge: .bottom) {
            VStack(alignment: .leading) {
                Text("Save \(ConnectionPreset(name: "", from: model.connection).summary) as:")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Preset name", text: $popovers.presetName)
                        .frame(width: 200)
                        .onSubmit(savePreset)
                    Button("Save", action: savePreset)
                        .keyboardShortcut(.defaultAction)
                        .disabled(popovers.presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let port = model.currentPresetPort {
                    Toggle("Include port: \(port.displayName)", isOn: $popovers.presetIncludesPort)
                        .help("Choosing the preset will also switch to this device or adapter")
                }
                if model.prefs.presets.contains(where: { $0.name == popovers.presetName.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                    Text("Replaces the preset of that name.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private func savePreset() {
        model.saveCurrentAsPreset(named: popovers.presetName, includePort: popovers.presetIncludesPort)
        popovers.showSavePreset = false
        model.focusTerminal()
    }

    private var transferMenu: some View {
        Menu {
            Group {
                Section("ZMODEM") {
                    Button("Send Files…") { model.sendFiles(.zmodem) }
                    Button("Receive") { model.receiveZmodem() }
                }
                Section("YMODEM") {
                    Button("Send Files…") { model.sendFiles(.ymodem) }
                    Button("Receive") { model.receiveYmodem() }
                }
                Section("XMODEM") {
                    Button("Send File…") { model.sendXmodem() }
                    Button("Receive As…") { model.receiveXmodem() }
                }
            }
            .disabled(!model.canStartTransfer)
            Divider()
            Button("Cancel Transfer") { model.cancelTransfer() }
                .disabled(!model.isTransferring)
            Button("Open Last Transfer Trace") { model.openLastTrace() }
                .disabled(model.lastTraceURL == nil)
            Button("Show Download Folder") { model.revealDownloads() }
        } label: {
            Label("Transfer", systemImage: "arrow.up.arrow.down.circle")
        }
        .help("File transfer")
    }

    private var lineMenu: some View {
        Menu {
            Button("Send Break") { model.sendBreak() }
                .disabled(!model.isConnected || model.isTransferring)
            Button("Send Window Size (stty)") { model.sendWindowSize() }
            Divider()
            Button("Clear Screen") { model.clearScreen() }
        } label: {
            Label("Line", systemImage: "cable.connector")
        }
        .help("Line control")
    }

    /// Shown while disconnected, so connecting never depends on finding a toolbar button.
    private var connectBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
            if let name = model.selectedPortName {
                Text("Not connected to \(name)").lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Type to connect, or").foregroundStyle(.secondary)
                // No Return shortcut: Return typed in the terminal should connect and reach the device.
                Button("Connect") { model.toggleConnection(ports: scanner.ports) }
                    .controlSize(.large)
            } else {
                Text(scanner.ports.isEmpty ? "No serial ports found — plug in an adapter" : "Choose a port in the toolbar to connect")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(model.isConnected ? model.connection.config.summary : model.statusMessage)
                .lineLimit(1)

            if let transfer = model.transferStatus {
                Divider().frame(height: 12)
                ProgressView().controlSize(.mini)
                Text(transfer).lineLimit(1).truncationMode(.middle)
                Button("Cancel") { model.cancelTransfer() }
                    .controlSize(.small)
            } else if model.pacedRemaining > 0 {
                Divider().frame(height: 12)
                Text("Typing \(model.pacedRemaining) more characters at \(model.connection.pacing.summary)…")
                    .lineLimit(1)
                if model.pacedEchoMissing {
                    Label("No echo", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("The device didn't echo the last character within \(String(format: "%g", model.connection.pacing.echoTimeout)) s, so it was sent on anyway. Turn off Wait for echo if the device doesn't echo.")
                }
                Button("Cancel") { model.cancelPacedTyping() }
                    .controlSize(.small)
            } else if model.isConnected, model.statusMessage != "Connected" {
                Divider().frame(height: 12)
                Text(model.statusMessage).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if case let .failed(problem) = model.logState {
                Label("Not logging", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(problem + ". Turn logging off and on to try again.")
            }
            if let log = model.logURL {
                Button {
                    model.revealLog()
                } label: {
                    Label(log.lastPathComponent, systemImage: "record.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Logging — click to show in Finder")
            }
            if model.connection.pacing.isOn {
                Label(model.connection.pacing.summary, systemImage: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.secondary)
                    .help("Typed and pasted text is paced (change under the slider button)")
            }
            if model.connection.backspaceSendsControlH {
                Text("⌫ = ^H").foregroundStyle(.secondary).help("Backspace sends Ctrl-H (change under the slider button)")
            }
            Text("\(model.cols)×\(model.rows)").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// ContentView's popover state (see the note at `ContentView.popovers`).
@MainActor
private final class PopoverState: ObservableObject {
    @Published var showLineSettings = false
    @Published var showCustomBaud = false
    /// The custom-baud field's text, and whether "Set" found it unusable.
    @Published var customBaud = ""
    @Published var customBaudInvalid = false
    @Published var showSavePreset = false
    /// The save-preset field's text.
    @Published var presetName = ""
    @Published var presetIncludesPort = true
}

/// Per-window line settings, shown from the toolbar.
struct LineSettingsView: View {
    @Binding var config: SerialConfig
    @Binding var backspaceSendsControlH: Bool
    @Binding var pacing: Pacing
    @Binding var zmodemReceiveCommand: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Picker("Data bits", selection: $config.dataBits) {
                    ForEach([8, 7, 6, 5], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Parity", selection: $config.parity) {
                    Text("None").tag(SerialConfig.Parity.none)
                    Text("Even").tag(SerialConfig.Parity.even)
                    Text("Odd").tag(SerialConfig.Parity.odd)
                }
                Picker("Stop bits", selection: $config.stopBits) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                Picker("Flow control", selection: $config.flowControl) {
                    Text("None").tag(SerialConfig.FlowControl.none)
                    Text("RTS/CTS (hardware)").tag(SerialConfig.FlowControl.rtsCts)
                    Text("XON/XOFF (software)").tag(SerialConfig.FlowControl.xonXoff)
                }
                Picker("Backspace sends", selection: $backspaceSendsControlH) {
                    Text("DEL (0x7F)").tag(false)
                    Text("Ctrl-H (0x08)").tag(true)
                }
                Section {
                    Picker("Typing speed", selection: $pacing.charactersPerSecond) {
                        Text("Unlimited").tag(0)
                        ForEach(Self.rates(including: pacing.charactersPerSecond), id: \.self) {
                            Text("\($0) characters/s").tag($0)
                        }
                    }
                    Picker("Pause after each line", selection: $pacing.lineDelay) {
                        Text("None").tag(0.0)
                        ForEach(Self.delays(including: pacing.lineDelay), id: \.self) {
                            Text("\(String(format: "%g", $0)) s").tag($0)
                        }
                    }
                    Toggle("Wait for each character's echo", isOn: $pacing.waitForEcho)
                    if pacing.waitForEcho {
                        Picker("Give up waiting after", selection: $pacing.echoTimeout) {
                            ForEach(Self.echoTimeouts(including: pacing.echoTimeout), id: \.self) {
                                Text("\(String(format: "%g", $0)) s").tag($0)
                            }
                        }
                    }
                } footer: {
                    Text("For devices whose command line drops characters sent too fast. Applies to typed and pasted text; file transfers always run at full speed. Waiting for the echo goes as fast as the device keeps up; the speed limit and line pause still apply after each echo.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("ZMODEM send starts receiver with", selection: $zmodemReceiveCommand) {
                        Text("rz (Linux, lrzsz)").tag("rz")
                        Text("zr (Slocum glider)").tag("zr")
                        if !["rz", "zr", ""].contains(zmodemReceiveCommand) {
                            Text(zmodemReceiveCommand).tag(zmodemReceiveCommand)
                        }
                        Text("Nothing (start it yourself)").tag("")
                    }
                } footer: {
                    Text("Typed at the device's prompt when you send files by ZMODEM. Harmless if the receiver is already running.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            SettingsLink {
                Text("More Settings…")
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func rates(including current: Int) -> [Int] {
        Array(Set([5, 10, 20, 30, 50, 100, 200, 500] + (current > 0 ? [current] : []))).sorted()
    }

    private static func echoTimeouts(including current: Double) -> [Double] {
        Array(Set([0.1, 0.25, 0.5, 1, 2, 5, current])).sorted()
    }

    private static func delays(including current: Double) -> [Double] {
        Array(Set([0.05, 0.1, 0.25, 0.5, 1, 2] + (current > 0 ? [current] : []))).sorted()
    }
}

/// The app's Settings window (SerialTerm ▸ Settings…, ⌘,).
struct SettingsWindow: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var scanner: PortScanner

    var body: some View {
        TabView {
            Form {
                Section("Display") {
                    Stepper("Font size: \(Int(settings.prefs.fontSize)) pt", value: $settings.prefs.fontSize, in: Preferences.fontSizes)
                }
                Section("Connection") {
                    Toggle("Reconnect when the adapter is plugged back in", isOn: $settings.prefs.autoReconnect)
                }
                Section {
                    Toggle("Use Option as Meta key", isOn: $settings.prefs.optionAsMeta)
                } footer: {
                    Text("On: Option-key combinations send Esc and the key, as shells and editors expect. Off: Option types the characters on your keyboard layout, such as @ or | on many European layouts. ⌥⌘O switches it for one window until the setting changes.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Folders") {
                    FolderRow(title: "Save received files to", url: $settings.prefs.downloadDirectory)
                    FolderRow(title: "Choose files to send from", url: $settings.prefs.uploadDirectory)
                }
                Section("Automatic transfers") {
                    Toggle("Start transfers automatically (remote sz/rz, and lrzsz sx/sb)", isOn: $settings.prefs.autoZmodem)
                }
                Section {
                    Picker("Protocol trace", selection: $settings.prefs.zmodem.traceLevel) {
                        Text("Off").tag(ZmodemOptions.TraceLevel.off)
                        Text("Frames").tag(ZmodemOptions.TraceLevel.frames)
                        Text("Frames + raw bytes").tag(ZmodemOptions.TraceLevel.verbose)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("One trace file per transfer (ZMODEM, YMODEM or XMODEM), in the log folder. \"Frames\" decodes every header, file offer, error and retry; \"raw bytes\" adds a hex dump of everything on the line.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Block size when sending", selection: $settings.prefs.zmodem.blockSize) {
                        ForEach([128, 256, 512, 1024, 2048, 4096, 8192], id: \.self) { Text("\($0) bytes").tag($0) }
                    }
                    Picker("Wait for ACK every", selection: $settings.prefs.zmodem.window) {
                        Text("As receiver requests").tag(0)
                        ForEach([1024, 2048, 4096, 8192, 16384, 32768], id: \.self) { Text("\($0 / 1024) KB").tag($0) }
                    }
                    Toggle("Force CRC-16", isOn: $settings.prefs.zmodem.forceCRC16)
                    Toggle("Escape all control characters", isOn: $settings.prefs.zmodem.escapeControls)
                    Stepper("Timeout: \(Int(settings.prefs.zmodem.timeout)) s", value: $settings.prefs.zmodem.timeout, in: 2...120, step: 1)
                    Button("Restore Defaults") {
                        let level = settings.prefs.zmodem.traceLevel
                        settings.prefs.zmodem = ZmodemOptions()
                        settings.prefs.zmodem.traceLevel = level
                    }
                } header: {
                    Text("ZMODEM workarounds")
                } footer: {
                    Text("For devices with unusual ZMODEM implementations. The defaults suit lrzsz and most others.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("XMODEM: send 1K blocks (XMODEM-1K)", isOn: $settings.prefs.xmodem1K)
                } header: {
                    Text("XMODEM / YMODEM")
                } footer: {
                    Text("1K blocks are much faster on links with delay; turn this off if a device only accepts classic 128-byte XMODEM. YMODEM always sends 1K blocks.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }

            Form {
                Section {
                    if settings.prefs.presets.isEmpty {
                        Text("No presets yet.").foregroundStyle(.secondary)
                    }
                    // By id, not bindings into the array: a row's text field may still be editing
                    // when another row is deleted.
                    ForEach(settings.prefs.presets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                PresetNameField(settings: settings, id: preset.id, name: preset.name)
                                Text(preset.summary).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            }
                            PresetPortPicker(port: presetPortBinding(preset.id), ports: scanner.ports)
                                .frame(width: 200)
                            Button {
                                settings.prefs.presets.removeAll { $0.id == preset.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete preset")
                        }
                    }
                    .onMove { settings.prefs.presets.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("A preset holds the baud rate, data bits, parity, stop bits, flow control and Backspace key, and optionally a port. Save one from a window's Presets menu; choosing it there applies it to that window, immediately if connected. A preset with a port also switches the window to that device, found by its USB serial number; with \"Keep window's port\" it leaves the port alone.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Presets", systemImage: "list.bullet.rectangle") }

            Form {
                Section {
                    Toggle("Log sessions", isOn: $settings.prefs.loggingEnabled)
                    FolderRow(title: "Log folder", url: $settings.prefs.logDirectory)
                }
                Section {
                    Text("Each connection writes a new file with millisecond timestamps, e.g.\n2026-10-20 10:32:01.123 RX login: \\r\\n")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Logging", systemImage: "doc.text") }
        }
        .frame(width: 560, height: 520)
    }

    private func presetPortBinding(_ id: UUID) -> Binding<PresetPort?> {
        Binding(
            get: { settings.prefs.presets.first { $0.id == id }?.port },
            set: { port in
                if let i = settings.prefs.presets.firstIndex(where: { $0.id == id }) { settings.prefs.presets[i].port = port }
            }
        )
    }
}

/// A preset's name in Settings. Takes a name only when it's allowed (not empty, not another
/// preset's) and says why otherwise; the saved name stays as it was.
private struct PresetNameField: View {
    @ObservedObject var settings: AppSettings
    let id: UUID
    let name: String
    @StateObject private var draft = TextDraft()

    var body: some View {
        let text = draft.text ?? name
        let problem = draft.text.flatMap { settings.prefs.presetNameProblem($0, for: id) }
        VStack(alignment: .leading, spacing: 2) {
            TextField("Name", text: Binding(get: { text }, set: { new in
                draft.text = new
                settings.prefs.renamePreset(id, to: new)
            }))
            .labelsHidden()
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

/// Text being edited, before it's accepted (see `PresetNameField`).
@MainActor
private final class TextDraft: ObservableObject {
    @Published var text: String?
}

/// Chooses a preset's port: none (keep the window's), a plugged-in port, or the saved one while unplugged.
private struct PresetPortPicker: View {
    @Binding var port: PresetPort?
    let ports: [SerialPortInfo]

    var body: some View {
        let selected = port.flatMap { $0.find(in: ports)?.path } ?? port?.path
        Picker("Port", selection: Binding<String?>(
            get: { selected },
            set: { path in
                guard let path else { port = nil; return }
                if let info = ports.first(where: { $0.path == path }) { port = PresetPort(info) }
            }
        )) {
            Text("Keep window's port").tag(String?.none)
            Divider()
            ForEach(ports) { info in
                Text(info.displayName).tag(String?.some(info.path))
            }
            if let port, port.find(in: ports) == nil {
                Text("\(port.displayName) (not present)").tag(String?.some(port.path))
            }
        }
        .labelsHidden()
        .help("Port the preset switches to")
    }
}

private struct FolderRow: View {
    let title: String
    @Binding var url: URL

    var body: some View {
        LabeledContent(title) {
            HStack {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(url.lastPathComponent, systemImage: "folder")
                }
                .buttonStyle(.link)
                .help(url.path)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = url
                    if panel.runModal() == .OK, let chosen = panel.url { url = chosen }
                }
            }
        }
    }
}
