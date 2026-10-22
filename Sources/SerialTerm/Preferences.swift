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
    /// nil when the port has none (or isn't USB).
    var portSerialNumber: String?
    /// USB interface number: tells apart the ports of a multi-port adapter, which share a serial number.
    var portInterface: Int?
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
        portInterface = try? c.decode(Int.self, forKey: .portInterface)
        config = ((try? c.decode(SerialConfig.self, forKey: .config)) ?? d.config).sanitized
        backspaceSendsControlH = (try? c.decode(Bool.self, forKey: .backspaceSendsControlH)) ?? d.backspaceSendsControlH
        pacing = ((try? c.decode(Pacing.self, forKey: .pacing)) ?? d.pacing).sanitized
        zmodemReceiveCommand = (try? c.decode(String.self, forKey: .zmodemReceiveCommand)) ?? d.zmodemReceiveCommand
    }

    /// Switch to `path`, remembering which device it is: `info` is the port as listed now, if it is.
    /// A port without a serial number clears the previous one, so it can't steer auto-reconnect.
    mutating func setPort(_ path: String?, info: SerialPortInfo?) {
        portPath = path
        portSerialNumber = info?.usbSerialNumber
        portInterface = info?.usbInterface
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
        config = ((try? c.decode(SerialConfig.self, forKey: .config)) ?? SerialConfig()).sanitized
        backspaceSendsControlH = (try? c.decode(Bool.self, forKey: .backspaceSendsControlH)) ?? false
        pacing = ((try? c.decode(Pacing.self, forKey: .pacing)) ?? Pacing()).sanitized
        zmodemReceiveCommand = (try? c.decode(String.self, forKey: .zmodemReceiveCommand)) ?? "rz"
        port = try? c.decode(PresetPort.self, forKey: .port)
    }

    /// True when the window is using this preset's line and keyboard settings. Choosing
    /// another port doesn't change the preset, so the port only counts when `includingPort`.
    func matches(_ connection: ConnectionSettings, includingPort: Bool = false) -> Bool {
        guard config == connection.config, backspaceSendsControlH == connection.backspaceSendsControlH,
              pacing == connection.pacing, zmodemReceiveCommand == connection.zmodemReceiveCommand else { return false }
        guard includingPort, let port else { return true }
        return port.matches(path: connection.portPath, serialNumber: connection.portSerialNumber,
                            interface: connection.portInterface)
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
    /// USB interface number, for multi-port adapters (see `ConnectionSettings.portInterface`).
    var interface: Int?
    /// For showing the port while it is unplugged.
    var displayName: String

    init(_ info: SerialPortInfo) {
        path = info.path
        serialNumber = info.usbSerialNumber
        interface = info.usbInterface
        displayName = info.displayName
    }

    init(path: String, serialNumber: String?, interface: Int? = nil) {
        self.path = path
        self.serialNumber = serialNumber
        self.interface = interface
        displayName = path.replacingOccurrences(of: "/dev/", with: "")
    }

    /// True when a window's port is this one: the same name (and device, where both are known),
    /// or the same device and interface under another name.
    func matches(path: String?, serialNumber: String?, interface: Int?) -> Bool {
        let mine = self.serialNumber.nonEmpty, theirs = serialNumber.nonEmpty
        if self.path == path { return mine == nil || theirs == nil || mine == theirs }
        guard let mine, mine == theirs, let iface = self.interface else { return false }
        return iface == interface
    }

    /// The plugged-in port that is this one, if any.
    func find(in ports: [SerialPortInfo]) -> SerialPortInfo? {
        SerialPortInfo.find(path: path, serialNumber: serialNumber, interface: interface, in: ports)
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
    /// Option key sends ESC + key (Meta) instead of typing the layout's Option characters.
    var optionAsMeta = true
    var loggingEnabled = false
    var logDirectory = Preferences.documentsSubfolder("SerialTerm Logs")
    var downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var uploadDirectory = FileManager.default.homeDirectoryForCurrentUser
    var fontSize: Double = 13

    static let fontSizes: ClosedRange<Double> = 8...36

    init() {}

    static func documentsSubfolder(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    // Decode field by field so settings saved by an older version keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        lastConnection = (try? c.decode(ConnectionSettings.self, forKey: .lastConnection)) ?? d.lastConnection
        // One by one, so a preset that can't be read doesn't lose the others.
        let list = (try? c.decode([Lenient<ConnectionPreset>].self, forKey: .presets)) ?? []
        presets = Self.distinct(list.compactMap(\.value))
        autoZmodem = (try? c.decode(Bool.self, forKey: .autoZmodem)) ?? d.autoZmodem
        useLrzszForZmodem = (try? c.decode(Bool.self, forKey: .useLrzszForZmodem)) ?? d.useLrzszForZmodem
        zmodem = ((try? c.decode(ZmodemOptions.self, forKey: .zmodem)) ?? d.zmodem).sanitized
        xmodem1K = (try? c.decode(Bool.self, forKey: .xmodem1K)) ?? d.xmodem1K
        autoReconnect = (try? c.decode(Bool.self, forKey: .autoReconnect)) ?? d.autoReconnect
        optionAsMeta = (try? c.decode(Bool.self, forKey: .optionAsMeta)) ?? d.optionAsMeta
        loggingEnabled = (try? c.decode(Bool.self, forKey: .loggingEnabled)) ?? d.loggingEnabled
        logDirectory = (try? c.decode(URL.self, forKey: .logDirectory)) ?? d.logDirectory
        downloadDirectory = (try? c.decode(URL.self, forKey: .downloadDirectory)) ?? d.downloadDirectory
        uploadDirectory = (try? c.decode(URL.self, forKey: .uploadDirectory)) ?? d.uploadDirectory
        let size = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize
        fontSize = min(max(size, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)

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

    /// Why preset `id` can't be called `name`, or nil if it can.
    func presetNameProblem(_ name: String, for id: UUID) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "A preset needs a name" }
        if presets.contains(where: { $0.name == name && $0.id != id }) { return "Another preset has that name" }
        return nil
    }

    /// Renames preset `id` if the name is allowed (see `presetNameProblem`).
    mutating func renamePreset(_ id: UUID, to name: String) {
        guard presetNameProblem(name, for: id) == nil, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Settings saved by an older version or edited by hand may have empty or repeated names
    /// (or repeated ids); give each preset its own: "Preset", "Glider 2", …
    static func distinct(_ presets: [ConnectionPreset]) -> [ConnectionPreset] {
        var names = Set<String>(), ids = Set<UUID>()
        return presets.map { preset in
            var p = preset
            let trimmed = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "Preset" : trimmed
            var name = base
            var n = 2
            while names.contains(name) {
                name = "\(base) \(n)"
                n += 1
            }
            p.name = name
            names.insert(name)
            if !ids.insert(p.id).inserted {
                p.id = UUID()
                ids.insert(p.id)
            }
            return p
        }
    }
}

/// Decodes to nil instead of failing, so one bad element doesn't fail a whole array.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

// Settings read from disk may be from an older version or edited by hand; keep the values in
// the ranges the rest of the app relies on (a negative baud rate would trap converting to speed_t).
extension SerialConfig {
    var sanitized: SerialConfig {
        var c = self
        if c.baudRate <= 0 || c.baudRate > Self.maxBaudRate { c.baudRate = SerialConfig().baudRate }
        if !(5...8).contains(c.dataBits) { c.dataBits = 8 }
        if c.stopBits != 2 { c.stopBits = 1 }
        return c
    }

    static let maxBaudRate = 100_000_000

    /// A typed baud rate: ASCII digits only, with spaces around them allowed. Rejects "1e6",
    /// "9600.5", "115,200" and non-ASCII digits rather than guess what they meant.
    static func parseBaudRate(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let rate = Int(digits), (1...maxBaudRate).contains(rate) else { return nil }
        return rate
    }
}

extension Pacing {
    var sanitized: Pacing {
        var p = self
        p.charactersPerSecond = max(0, p.charactersPerSecond)
        p.lineDelay = max(0, p.lineDelay)
        if p.echoTimeout <= 0 { p.echoTimeout = Pacing().echoTimeout }
        return p
    }
}

extension ZmodemOptions {
    var sanitized: ZmodemOptions {
        var z = self
        z.blockSize = min(max(z.blockSize, 32), 8192)
        z.window = max(0, z.window)
        z.timeout = min(max(z.timeout, 2), 120)
        return z
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
            if let data {
                // Unreadable (corrupt, or from a newer version): keep a copy before the first save
                // replaces it with defaults.
                UserDefaults.standard.set(data, forKey: Self.key + ".unreadable")
            }
            prefs = Preferences()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
