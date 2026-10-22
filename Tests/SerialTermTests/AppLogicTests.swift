// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
import SerialCore
import SwiftTerm
import Testing
@testable import SerialTerm

private func usb(_ path: String, sn: String?, interface: Int? = 0) -> SerialPortInfo {
    SerialPortInfo(path: "/dev/\(path)", usbProduct: "Adapter", usbSerialNumber: sn, usbInterface: interface,
                   vendorID: 0x0403, productID: 0x6010)
}

struct PortMatchingTests {
    /// Both ports of a dual adapter share the device's serial number.
    let dual = [usb("cu.usbserial-FT1A", sn: "FT1", interface: 0), usb("cu.usbserial-FT1B", sn: "FT1", interface: 1)]

    @Test func samePathAndSerialNumberWins() {
        let p = SerialPortInfo.find(path: "/dev/cu.usbserial-FT1B", serialNumber: "FT1", interface: 1, in: dual)
        #expect(p?.path == "/dev/cu.usbserial-FT1B")
    }

    /// Matching by serial number alone used to take the first port of a multi-port adapter.
    @Test func secondChannelIsNotTakenForTheFirst() {
        // Channel B, remembered from before the interface was recorded: same path still matches.
        #expect(SerialPortInfo.find(path: "/dev/cu.usbserial-FT1B", serialNumber: "FT1", interface: nil, in: dual)?.path
            == "/dev/cu.usbserial-FT1B")
        // Moved to new names: the interface number picks the channel...
        let renamed = [usb("cu.usbserial-X0", sn: "FT1", interface: 0), usb("cu.usbserial-X1", sn: "FT1", interface: 1)]
        #expect(SerialPortInfo.find(path: "/dev/cu.usbserial-FT1B", serialNumber: "FT1", interface: 1, in: renamed)?.path
            == "/dev/cu.usbserial-X1")
        // ...and without it, the serial number alone is ambiguous, so nothing is guessed.
        #expect(SerialPortInfo.find(path: "/dev/cu.usbserial-FT1B", serialNumber: "FT1", interface: nil, in: renamed) == nil)
    }

    @Test func singleAdapterIsFollowedToANewName() {
        let ports = [usb("cu.usbmodem2101", sn: "A50285BI")]
        #expect(SerialPortInfo.find(path: "/dev/cu.usbmodem1101", serialNumber: "A50285BI", interface: 0, in: ports)?.path
            == "/dev/cu.usbmodem2101")
    }

    @Test func portWithoutSerialNumberMatchesByPathOnly() {
        let ports = [usb("cu.wchusbserial1410", sn: nil), usb("cu.usbserial-A50285BI", sn: "A50285BI")]
        #expect(SerialPortInfo.find(path: "/dev/cu.wchusbserial1410", serialNumber: nil, interface: nil, in: ports)?.path
            == "/dev/cu.wchusbserial1410")
        #expect(SerialPortInfo.find(path: "/dev/cu.wchusbserial1411", serialNumber: "", interface: nil, in: ports) == nil)
    }

    /// Choosing a port without a serial number used to keep the previous port's, so auto-reconnect
    /// looked for (and could switch to) the other adapter.
    @Test func choosingAPortReplacesTheRememberedSerialNumber() {
        var c = ConnectionSettings()
        c.setPort("/dev/cu.usbserial-A50285BI", info: usb("cu.usbserial-A50285BI", sn: "A50285BI"))
        let ch340 = usb("cu.wchusbserial1410", sn: nil, interface: nil)
        c.setPort(ch340.path, info: ch340)
        #expect(c.portSerialNumber == nil)
        #expect(c.portInterface == nil)
        let ports = [ch340, usb("cu.usbserial-A50285BI", sn: "A50285BI")]
        #expect(SerialPortInfo.find(path: c.portPath, serialNumber: c.portSerialNumber, interface: c.portInterface, in: ports)?.path
            == ch340.path)
    }

    @Test func presetPortMatchesTheRightChannel() {
        let presetB = PresetPort(dual[1])
        #expect(presetB.find(in: dual)?.path == "/dev/cu.usbserial-FT1B")
        #expect(presetB.matches(path: "/dev/cu.usbserial-FT1B", serialNumber: "FT1", interface: 1))
        #expect(!presetB.matches(path: "/dev/cu.usbserial-FT1A", serialNumber: "FT1", interface: 0))
        // The same channel under another name.
        #expect(presetB.matches(path: "/dev/cu.usbserial-X1", serialNumber: "FT1", interface: 1))
    }
}

struct PreferencesDecodingTests {
    private func decode(_ json: String) throws -> Preferences {
        try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
    }

    /// One preset that couldn't be read used to drop them all.
    @Test func unreadablePresetLosesOnlyItself() throws {
        let prefs = try decode("""
        {"presets": [
            {"name": "Glider", "config": {"baudRate": 9600, "dataBits": 8, "parity": "none", "stopBits": 1, "flowControl": "none"}},
            {"config": {"baudRate": 115200}},
            "nonsense",
            {"name": "MicroRider"}
        ]}
        """)
        #expect(prefs.presets.map(\.name) == ["Glider", "MicroRider"])
        #expect(prefs.presets[0].config.baudRate == 9600)
        #expect(prefs.presets[1].zmodemReceiveCommand == "rz")  // saved before the setting existed
    }

    @Test func emptyAndRepeatedNamesAreMadeDistinct() throws {
        let id = UUID().uuidString
        let prefs = try decode("""
        {"presets": [{"name": "Glider", "id": "\(id)"}, {"name": "Glider", "id": "\(id)"}, {"name": "  "}, {"name": ""}]}
        """)
        #expect(prefs.presets.map(\.name) == ["Glider", "Glider 2", "Preset", "Preset 2"])
        #expect(Set(prefs.presets.map(\.id)).count == 4)
    }

    /// A negative baud rate would trap converting to speed_t when connecting.
    @Test func outOfRangeLineSettingsAreClamped() throws {
        let prefs = try decode("""
        {"lastConnection": {"config": {"baudRate": -9600, "dataBits": 9, "parity": "none", "stopBits": 3, "flowControl": "none"},
                            "pacing": {"charactersPerSecond": -5, "lineDelay": -1, "waitForEcho": true, "echoTimeout": 0}},
         "presets": [{"name": "Zero", "config": {"baudRate": 0, "dataBits": 7, "parity": "even", "stopBits": 2, "flowControl": "none"}}],
         "fontSize": 400, "zmodem": {"timeout": 0, "blockSize": 1000000000}}
        """)
        let c = prefs.lastConnection
        #expect(c.config.baudRate == SerialConfig().baudRate)
        #expect(c.config.dataBits == 8)
        #expect(c.config.stopBits == 1)
        #expect(c.pacing.charactersPerSecond == 0)
        #expect(c.pacing.lineDelay == 0)
        #expect(c.pacing.echoTimeout == Pacing().echoTimeout)
        #expect(prefs.presets[0].config.baudRate == SerialConfig().baudRate)
        #expect(prefs.presets[0].config.dataBits == 7)
        #expect(prefs.fontSize == Preferences.fontSizes.upperBound)
        #expect(prefs.zmodem.timeout == 2)
        #expect(prefs.zmodem.blockSize == 8192)
    }

    @Test func olderSettingsStillLoad() throws {
        let prefs = try decode("""
        {"lastConnection": {"portPath": "/dev/cu.usbserial-A", "portSerialNumber": "A"}, "swapBackspaceDelete": true}
        """)
        #expect(prefs.lastConnection.portPath == "/dev/cu.usbserial-A")
        #expect(prefs.lastConnection.portInterface == nil)
        #expect(prefs.lastConnection.backspaceSendsControlH)
        #expect(prefs.optionAsMeta)
    }

    @Test func roundTrip() throws {
        var prefs = Preferences()
        var c = ConnectionSettings()
        c.setPort("/dev/cu.usbserial-FT1B", info: usb("cu.usbserial-FT1B", sn: "FT1", interface: 1))
        prefs.presets = [ConnectionPreset(name: "B", from: c, port: PresetPort(usb("cu.usbserial-FT1B", sn: "FT1", interface: 1)))]
        prefs.lastConnection = c
        prefs.optionAsMeta = false
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(back == prefs)
    }

    @Test func renamingRefusesEmptyAndTakenNames() {
        var prefs = Preferences()
        prefs.presets = [ConnectionPreset(name: "Glider", from: ConnectionSettings()),
                         ConnectionPreset(name: "MicroRider", from: ConnectionSettings())]
        let id = prefs.presets[1].id
        #expect(prefs.presetNameProblem("  ", for: id) != nil)
        #expect(prefs.presetNameProblem("Glider", for: id) != nil)
        #expect(prefs.presetNameProblem("MicroRider", for: id) == nil)
        prefs.renamePreset(id, to: "Glider")
        #expect(prefs.presets[1].name == "MicroRider")
        prefs.renamePreset(id, to: " VMP ")
        #expect(prefs.presets[1].name == "VMP")
    }
}

struct BaudParsingTests {
    @Test func digitsOnly() {
        #expect(SerialConfig.parseBaudRate("115200") == 115_200)
        #expect(SerialConfig.parseBaudRate("  250000\n") == 250_000)
        for bad in ["", " ", "0", "-9600", "1e6", "9600.5", "115,200", "١١٥٢٠٠", "１１５２００", "9600 baud",
                    "99999999999999999999999", "200000000"] {
            #expect(SerialConfig.parseBaudRate(bad) == nil, "\(bad)")
        }
    }
}

private final class Replies: TerminalDelegate {
    var sent: [[UInt8]] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
}

struct TerminalModeResetTests {
    /// Modes one device turned on used to carry over to the next device in the same window.
    @Test func clearsWhatAPreviousDeviceTurnedOn() {
        let replies = Replies()
        var options = TerminalOptions.default
        options.cols = 80
        options.rows = 24
        let t = Terminal(delegate: replies, options: options)
        t.feed(text: "hello\r\nworld")
        t.feed(text: "\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[>1u\u{1b}[?1049h\u{1b}[>1u\u{1b}[5;5Habc")
        #expect(t.bracketedPasteMode)
        #expect(t.isCurrentBufferAlternate)
        #expect(t.mouseMode != .off)

        t.feed(text: TerminalModeReset.sequence)
        #expect(!t.bracketedPasteMode)
        #expect(!t.isCurrentBufferAlternate)
        #expect(t.mouseMode == .off)
        #expect(t.keyboardEnhancementFlags.isEmpty)
        // Back where the normal screen left off, not at a saved cursor position.
        #expect(t.getCursorLocation().x == 5 && t.getCursorLocation().y == 1)
        replies.sent.removeAll()
        t.setTerminalFocus(false)
        #expect(replies.sent.isEmpty)  // no focus report
    }

    /// Without anything to undo, the reset leaves the screen and cursor alone.
    @Test func harmlessOnAFreshTerminal() {
        let t = Terminal(delegate: Replies())
        t.feed(text: "\u{1b}7\u{1b}[H\u{1b}[10;20H")  // a saved cursor at home must not be restored
        t.feed(text: TerminalModeReset.sequence)
        #expect(t.getCursorLocation().x == 19 && t.getCursorLocation().y == 9)
    }
}

/// Mach port names this task holds.
private func machPortNames() -> Int {
    var names: mach_port_name_array_t?
    var namesCount: mach_msg_type_number_t = 0
    var types: mach_port_type_array_t?
    var typesCount: mach_msg_type_number_t = 0
    guard mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount) == KERN_SUCCESS else { return -1 }
    if let names {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: names)),
                      vm_size_t(namesCount) * vm_size_t(MemoryLayout<mach_port_name_t>.size))
    }
    if let types {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: types)),
                      vm_size_t(typesCount) * vm_size_t(MemoryLayout<mach_port_type_t>.size))
    }
    return Int(namesCount)
}

@MainActor
struct PortScannerTests {
    /// A released scanner kept its IOKit notification port and iterators, and left its run loop
    /// source on the main run loop with a dangling pointer for the next hot-plug.
    @Test func releasingAScannerFreesItsPorts() {
        _ = PortScanner()  // first use of IOKit sets up ports of its own
        let before = machPortNames()
        for _ in 0..<50 { _ = PortScanner() }
        let after = machPortNames()
        #expect(before > 0)
        #expect(after - before < 30, "\(after - before) Mach ports more after 50 scanners came and went")
    }
}
