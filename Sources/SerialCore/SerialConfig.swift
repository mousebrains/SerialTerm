import Foundation

/// Line settings for a serial port.
public struct SerialConfig: Equatable, Codable, Sendable {
    public enum Parity: String, CaseIterable, Codable, Sendable {
        case none, odd, even
    }

    public enum FlowControl: String, CaseIterable, Codable, Sendable {
        case none
        case rtsCts
        case xonXoff
    }

    public var baudRate: Int
    /// 5...8
    public var dataBits: Int
    public var parity: Parity
    /// 1 or 2
    public var stopBits: Int
    public var flowControl: FlowControl

    public init(
        baudRate: Int = 115_200,
        dataBits: Int = 8,
        parity: Parity = .none,
        stopBits: Int = 1,
        flowControl: FlowControl = .none
    ) {
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
    }

    /// Rates offered in the UI. Anything above 230400 goes through IOSSIOSPEED on macOS,
    /// so arbitrary custom rates work the same way as these.
    public static let commonBaudRates = [
        300, 1200, 2400, 4800, 9600, 19_200, 38_400, 57_600, 115_200,
        230_400, 460_800, 921_600, 1_000_000, 1_500_000, 2_000_000, 3_000_000,
    ]

    /// Short form such as "115200 8N1 RTS/CTS".
    public var summary: String {
        let p: String
        switch parity {
        case .none: p = "N"
        case .odd: p = "O"
        case .even: p = "E"
        }
        var s = "\(baudRate) \(dataBits)\(p)\(stopBits)"
        switch flowControl {
        case .none: break
        case .rtsCts: s += " RTS/CTS"
        case .xonXoff: s += " XON/XOFF"
        }
        return s
    }
}
