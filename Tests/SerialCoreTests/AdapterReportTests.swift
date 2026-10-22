// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Darwin
import Foundation
import Testing
@testable import SerialCore

struct PortDescriptionTests {
    @Test func describesAUSBAdapterAndItsDriver() {
        let ftdi = PortDescription(usbVendor: "FTDI", usbProduct: "USB-RS232 Cable", usbSerialNumber: "AU05IUK5",
                                   vendorID: 0x0403, productID: 0x6001, deviceRelease: 0x0600, usbSpeed: 1,
                                   driverClass: "IOUserSerial", userClass: "AppleUSBFTDI",
                                   driverBundle: "com.apple.DriverKit-AppleUSBFTDI")
        #expect(ftdi.lines == [
            "adapter: USB-RS232 Cable, FTDI; USB 0403:6001 rev 0600, serial AU05IUK5, full speed",
            "driver: IOUserSerial (AppleUSBFTDI), com.apple.DriverKit-AppleUSBFTDI",
        ])
    }

    @Test func leavesOutWhatIOKitDidNotSay() {
        #expect(PortDescription(vendorID: 0x10c4, productID: 0xea60).lines
            == ["adapter: USB device; USB 10c4:ea60", "driver: unknown"])
        // A kext's class is its own; no IOUserClass to add.
        #expect(PortDescription(driverClass: "AppleUSBCHCOM", userClass: "AppleUSBCHCOM").lines
            == ["adapter: not a USB device", "driver: AppleUSBCHCOM"])
    }

    @Test func findsTheDevicesIOKitLists() throws {
        // Whatever serial devices this machine has (CI runners may have none).
        let names = try FileManager.default.contentsOfDirectory(atPath: "/dev").filter { $0.hasPrefix("cu.") }
        for name in names {
            let d = PortDescription.lookUp(path: "/dev/" + name)
            #expect(d != nil, "\(name)")
            #expect(d?.driverClass != nil, "\(name)")
        }
        #expect(PortDescription.lookUp(path: "/dev/cu.no-such-device") == nil)
    }
}

@Suite(.serialized)
struct AdapterReportTests {
    @Test func aPtyIsNotAnAdapterAndRefusesTheLatencyRequest() throws {
        let pty = try PtyPair()
        let port = SerialPort(path: pty.slavePath, config: SerialConfig(baudRate: 115_200))
        #expect(port.adapterReport.isEmpty)
        try port.open()
        defer { port.close() }
        #expect(port.adapterReport.first == "adapter: not listed by IOKit")
        let latency = try #require(port.adapterReport.last)
        #expect(latency.hasPrefix("receive latency: asked the driver for 1 ms (IOSSDATALAT): refused ("), "\(latency)")
    }

    @Test func everyTraceAndTheSessionLogStartWithTheLineAndAdapter() throws {
        let pty = try PtyPair()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SerialTermTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig(baudRate: 115_200)),
                              downloadDirectory: dir)
        session.traceDirectory = dir
        let log = try session.startLogging(to: dir.appendingPathComponent("session.log"))
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }

        for kind in [TransferKind.zmodemReceive, .xmodemReceive(dir.appendingPathComponent("x.bin"))] {
            let before = events.all.count
            try session.startTransfer(kind)
            session.cancelTransfer()
            #expect(events.wait(timeout: 10) { $0.dropFirst(before).contains { if case .transferFinished = $0 { true } else { false } } })
            let url = try #require(session.lastTraceURL)
            var trace = ""
            _ = events.wait(timeout: 5) { _ in
                trace = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return trace.contains("host: macOS")
            }
            let notes = trace.split(separator: "\n").prefix(4).map { $0.components(separatedBy: "  -- ").last ?? "" }
            #expect(notes.count == 4)
            #expect(notes.first == "port: \(pty.slavePath) 115200 8N1", "\(kind.displayName): \(notes)")
            #expect(notes.dropFirst().first == "adapter: not listed by IOKit")
            #expect(notes.dropFirst(2).first?.hasPrefix("receive latency: ") == true)
            #expect(notes.dropFirst(3).first?.hasPrefix("host: macOS ") == true)
        }

        session.stopLogging()
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("adapter: not listed by IOKit"))
        #expect(text.contains("receive latency: asked the driver for 1 ms"))
    }

    /// Recording turned on after connecting still gets the adapter; before connecting, only once.
    @Test func aLogStartedAfterConnectingGetsTheAdapterToo() throws {
        let pty = try PtyPair()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SerialTermTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig(baudRate: 115_200)),
                              downloadDirectory: dir)
        let before = try session.startLogging(to: dir.appendingPathComponent("before.log"))
        try session.open()
        defer { session.close() }
        session.stopLogging()
        let after = try session.startLogging(to: dir.appendingPathComponent("after.log"))
        session.stopLogging()

        for url in [before, after] {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.components(separatedBy: "adapter: not listed by IOKit").count == 2, "\(url.lastPathComponent)")
            #expect(text.components(separatedBy: "receive latency: ").count == 2, "\(url.lastPathComponent)")
        }
    }

    @Test func aLogStartedBeforeConnectingHasNoAdapterYet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SerialTermTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = Session(port: SerialPort(path: "/dev/cu.no-such-device", config: SerialConfig()),
                              downloadDirectory: dir)
        let log = try session.startLogging(to: dir.appendingPathComponent("early.log"))
        session.stopLogging()
        #expect(!(try String(contentsOf: log, encoding: .utf8)).contains("adapter:"))
    }
}
