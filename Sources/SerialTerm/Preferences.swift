// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Combine
import Foundation
import SerialCore

/// Which device a window talks to and how. Each window has its own; the most recent
/// one is remembered as the default for new windows.
struct ConnectionSettings: Codable, Equatable {
    var portPath: String?
    /// USB serial number of the adapter, so the same dongle is found again after a replug.
    var portSerialNumber: String?
    var config = SerialConfig()
    /// The Backspace key sends Ctrl-H (0x08) instead of DEL (0x7F).
    var backspaceSendsControlH = false
    /// Rate limit for typed and pasted text.
    var pacing = Pacing()
    /// Typed before a ZMODEM send to start the device's receiver: "rz", "zr" (Slocum), or "" for none.
    var zmodemReceiveCommand = "rz"

    init() {}

    // Decode field by field so settings saved by an older version keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConnectionSettings()
        portPath = try? c.decode(String.self, forKey: .portPath)
        portSerialNumber = try? c.decode(String.self, forKey: .portSerialNumber)
        config = (try? c.decode(SerialConfig.self, forKey: .config)) ?? d.config
        backspaceSendsControlH = (try? c.decode(Bool.self, forKey: .backspaceSendsControlH)) ?? d.backspaceSendsControlH
        pacing = (try? c.decode(Pacing.self, forKey: .pacing)) ?? d.pacing
        zmodemReceiveCommand = (try? c.decode(String.self, forKey: .zmodemReceiveCommand)) ?? d.zmodemReceiveCommand
    }

    /// Apply a preset's line and keyboard settings, keeping the port.
    mutating func apply(_ preset: ConnectionPreset) {
        config = preset.config
        backspaceSendsControlH = preset.backspaceSendsControlH
        pacing = preset.pacing
        zmodemReceiveCommand = preset.zmodemReceiveCommand
    }
}

/// A named set of line and keyboard settings, applied to a window from the Presets menu.
/// It may also name a port, so choosing it switches the window to that device.
struct ConnectionPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var config: SerialConfig
    var backspaceSendsControlH: Bool
    var pacing: Pacing
    var zmodemReceiveCommand: String
    /// nil: applying the preset keeps the window's port.
    var port: PresetPort?

    init(name: String, from connection: ConnectionSettings, port: PresetPort? = nil) {
        self.name = name
        config = connection.config
        backspaceSendsControlH = connection.backspaceSendsControlH
        pacing = connection.pacing
        zmodemReceiveCommand = connection.zmodemReceiveCommand
        self.port = port
    }

    // Decode field by field so presets saved by an older version keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        config = (try? c.decode(SerialConfig.self, forKey: .config)) ?? SerialConfig()
        backspaceSendsControlH = (try? c.decode(Bool.self, forKey: .backspaceSendsControlH)) ?? false
        pacing = (try? c.decode(Pacing.self, forKey: .pacing)) ?? Pacing()
        zmodemReceiveCommand = (try? c.decode(String.self, forKey: .zmodemReceiveCommand)) ?? "rz"
        port = try? c.decode(PresetPort.self, forKey: .port)
    }

    /// True when the window is using this preset's line and keyboard settings. Choosing
    /// another port doesn't change the preset, so the port only counts when `includingPort`.
    func matches(_ connection: ConnectionSettings, includingPort: Bool = false) -> Bool {
        guard config == connection.config, backspaceSendsControlH == connection.backspaceSendsControlH,
              pacing == connection.pacing, zmodemReceiveCommand == connection.zmodemReceiveCommand else { return false }
        guard includingPort, let port else { return true }
        return port.matches(path: connection.portPath, serialNumber: connection.portSerialNumber)
    }

    /// Short form such as "9600 7E1, ⌫ = ^H, 30 char/s, zr".
    var summary: String {
        var s = config.summary + (backspaceSendsControlH ? ", ⌫ = ^H" : "") + (pacing.isOn ? ", \(pacing.summary)" : "")
        if zmodemReceiveCommand != "rz" { s += zmodemReceiveCommand.isEmpty ? ", no rz" : ", \(zmodemReceiveCommand)" }
        return s
    }
}

/// The port a preset connects to. Found again by USB serial number, so the same device or
/// adapter is used even if macOS gives it a different /dev name.
struct PresetPort: Codable, Hashable {
    var path: String
    var serialNumber: String?
    /// For showing the port while it is unplugged.
    var displayName: String

    init(_ info: SerialPortInfo) {
        path = info.path
        serialNumber = info.usbSerialNumber
        displayName = info.displayName
    }

    init(path: String, serialNumber: String?) {
        self.path = path
        self.serialNumber = serialNumber
        displayName = path.replacingOccurrences(of: "/dev/", with: "")
    }

    func matches(path: String?, serialNumber: String?) -> Bool {
        if let sn = self.serialNumber, !sn.isEmpty, let other = serialNumber, !other.isEmpty { return sn == other }
        return self.path == path
    }

    /// The plugged-in port that is this one, if any.
    func find(in ports: [SerialPortInfo]) -> SerialPortInfo? {
        if let sn = serialNumber, !sn.isEmpty, let p = ports.first(where: { $0.usbSerialNumber == sn }) { return p }
        return ports.first { $0.path == path }
    }
}

/// App-wide settings, saved to UserDefaults as JSON.
struct Preferences: Codable, Equatable {
    var lastConnection = ConnectionSettings()
    var presets: [ConnectionPreset] = []

    var autoZmodem = true
    var useLrzszForZmodem = false
    var zmodem = ZmodemOptions()
    var xmodem1K = false
    var autoReconnect = true
    var loggingEnabled = false
    var logDirectory = Preferences.documentsSubfolder("SerialTerm Logs")
    var downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var uploadDirectory = FileManager.default.homeDirectoryForCurrentUser
    var fontSize: Double = 13

    init() {}

    static func documentsSubfolder(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    // Decode field by field so settings saved by an older version keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        lastConnection = (try? c.decode(ConnectionSettings.self, forKey: .lastConnection)) ?? d.lastConnection
        presets = (try? c.decode([ConnectionPreset].self, forKey: .presets)) ?? d.presets
        autoZmodem = (try? c.decode(Bool.self, forKey: .autoZmodem)) ?? d.autoZmodem
        useLrzszForZmodem = (try? c.decode(Bool.self, forKey: .useLrzszForZmodem)) ?? d.useLrzszForZmodem
        zmodem = (try? c.decode(ZmodemOptions.self, forKey: .zmodem)) ?? d.zmodem
        xmodem1K = (try? c.decode(Bool.self, forKey: .xmodem1K)) ?? d.xmodem1K
        autoReconnect = (try? c.decode(Bool.self, forKey: .autoReconnect)) ?? d.autoReconnect
        loggingEnabled = (try? c.decode(Bool.self, forKey: .loggingEnabled)) ?? d.loggingEnabled
        logDirectory = (try? c.decode(URL.self, forKey: .logDirectory)) ?? d.logDirectory
        downloadDirectory = (try? c.decode(URL.self, forKey: .downloadDirectory)) ?? d.downloadDirectory
        uploadDirectory = (try? c.decode(URL.self, forKey: .uploadDirectory)) ?? d.uploadDirectory
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize

        // Backspace used to be app-wide; it is now per window, like the line settings.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let swap = try? legacy.decode(Bool.self, forKey: .swapBackspaceDelete) {
            lastConnection.backspaceSendsControlH = swap
        }
    }

    private enum LegacyKeys: String, CodingKey {
        case swapBackspaceDelete
    }

    /// Add a preset, replacing any with the same name.
    mutating func savePreset(_ preset: ConnectionPreset) {
        if let i = presets.firstIndex(where: { $0.name == preset.name }) {
            presets[i].config = preset.config
            presets[i].backspaceSendsControlH = preset.backspaceSendsControlH
            presets[i].pacing = preset.pacing
            presets[i].zmodemReceiveCommand = preset.zmodemReceiveCommand
            presets[i].port = preset.port
        } else {
            presets.append(preset)
        }
    }
}

/// The shared, persisted `Preferences`, observed by every window and the Settings window.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var prefs: Preferences {
        didSet { save() }
    }

    private static let key = "preferences.v2"

    /// Settings saved before the bundle identifier changed.
    private static let previousDomains = ["com.example.SerialTerm"]

    private init() {
        var data = UserDefaults.standard.data(forKey: Self.key)
        if data == nil {
            data = Self.previousDomains.lazy.compactMap { UserDefaults(suiteName: $0)?.data(forKey: Self.key) }.first
        }
        if let data, let prefs = try? JSONDecoder().decode(Preferences.self, from: data) {
            self.prefs = prefs
        } else {
            prefs = Preferences()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
