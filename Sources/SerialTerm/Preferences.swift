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
}

/// App-wide settings, saved to UserDefaults as JSON.
struct Preferences: Codable, Equatable {
    var lastConnection = ConnectionSettings()

    var swapBackspaceDelete = false
    var autoZmodem = true
    var useLrzszForZmodem = false
    var zmodem = ZmodemOptions()
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
        swapBackspaceDelete = (try? c.decode(Bool.self, forKey: .swapBackspaceDelete)) ?? d.swapBackspaceDelete
        autoZmodem = (try? c.decode(Bool.self, forKey: .autoZmodem)) ?? d.autoZmodem
        useLrzszForZmodem = (try? c.decode(Bool.self, forKey: .useLrzszForZmodem)) ?? d.useLrzszForZmodem
        zmodem = (try? c.decode(ZmodemOptions.self, forKey: .zmodem)) ?? d.zmodem
        autoReconnect = (try? c.decode(Bool.self, forKey: .autoReconnect)) ?? d.autoReconnect
        loggingEnabled = (try? c.decode(Bool.self, forKey: .loggingEnabled)) ?? d.loggingEnabled
        logDirectory = (try? c.decode(URL.self, forKey: .logDirectory)) ?? d.logDirectory
        downloadDirectory = (try? c.decode(URL.self, forKey: .downloadDirectory)) ?? d.downloadDirectory
        uploadDirectory = (try? c.decode(URL.self, forKey: .uploadDirectory)) ?? d.uploadDirectory
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize
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

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let prefs = try? JSONDecoder().decode(Preferences.self, from: data) {
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
