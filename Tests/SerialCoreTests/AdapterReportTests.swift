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
        #expect(latency.hasPrefix("receive latency: asked the driver for 16 (IOSSDATALAT): refused ("), "\(latency)")
        #expect(port.receiveLatency == SerialPort.idleReceiveLatency)
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
            let notes = trace.split(separator: "\n").prefix(5).map { $0.components(separatedBy: "  -- ").last ?? "" }
            #expect(notes.count == 5)
            #expect(notes.first == "port: \(pty.slavePath) 115200 8N1", "\(kind.displayName): \(notes)")
            #expect(notes.dropFirst().first == "adapter: not listed by IOKit")
            #expect(notes.dropFirst(2).first?.hasPrefix("receive latency: asked the driver for 16 ") == true)
            #expect(notes.dropFirst(3).first?.hasPrefix("for the transfer, receive latency: asked the driver for 1 ") == true,
                    "\(notes)")
            #expect(notes.dropFirst(4).first?.hasPrefix("host: macOS ") == true)
            // Back to the idle latency once the transfer is over.
            #expect(session.port.receiveLatency == SerialPort.idleReceiveLatency)
        }

        session.stopLogging()
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("adapter: not listed by IOKit"))
        #expect(text.contains("receive latency: asked the driver for 16 (IOSSDATALAT)"))
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

struct FTDILatencyTests {
    @Test func reportsWhatTheTimerReads() {
        #expect(FTDILatency.report(16) == "FTDI latency timer: 16 ms")
        #expect(FTDILatency.report(nil) == "FTDI latency timer: couldn't read it")
    }

    /// Low latency while a transfer runs, where every reply waited for counts; FTDI's default otherwise.
    @Test func aTransferRunsAtTheLowLatency() throws {
        let pty = try PtyPair()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SerialTermTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = Session(port: SerialPort(path: pty.slavePath, config: SerialConfig(baudRate: 115_200)),
                              downloadDirectory: dir)
        let events = Inbox<SessionEvent>()
        session.onEvent = { events.add($0) }
        try session.open()
        defer { session.close() }
        #expect(session.port.receiveLatency == 16)
        try session.startTransfer(.zmodemReceive)
        #expect(session.port.receiveLatency == 1)
        session.cancelTransfer()
        #expect(events.wait(timeout: 10) { $0.contains { if case .transferFinished = $0 { true } else { false } } })
        #expect(session.port.receiveLatency == 16)
    }

    @Test func knowsAnFTDIChipByItsVendorOrItsDriver() {
        #expect(PortDescription(vendorID: 0x0403, productID: 0x6001).isFTDI)
        // A product with its own IDs on an FTDI chip still gets Apple's FTDI driver.
        #expect(PortDescription(vendorID: 0x1234, productID: 0x0001, driverClass: "IOUserSerial", userClass: "AppleUSBFTDI").isFTDI)
        #expect(!PortDescription(vendorID: 0x10c4, productID: 0xea60, driverClass: "AppleUSBSLCOM").isFTDI)
        #expect(!PortDescription().isFTDI)
    }

    @Test func leavesPortsIOKitDoesNotListAlone() throws {
        #expect(FTDILatency.read(path: "/dev/cu.no-such-device", interface: 0) == nil)
        // A pty isn't an adapter, so opening one adds no FTDI line.
        let pty = try PtyPair()
        let port = SerialPort(path: pty.slavePath, config: SerialConfig(baudRate: 115_200))
        try port.open()
        defer { port.close() }
        #expect(!port.adapterReport.contains { $0.hasPrefix("FTDI latency timer") })
    }
}

/// An FTDI adapter on Apple's driver: the latency requests set the chip's timer, and it stays set.
/// Runs only when SERIALTERM_PROBE_PORT is an FTDI adapter and SERIALTERM_PROBE_FTDI is set.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SERIALTERM_PROBE_FTDI"] != nil))
struct HardwareFTDILatencyTests {
    @Test func theTimerFollowsTheLatencyRequests() throws {
        let path = ProcessInfo.processInfo.environment["SERIALTERM_PROBE_PORT"]!
        let port = SerialPort(path: path, config: SerialConfig(baudRate: 115_200))
        try port.open()
        defer { port.close() }
        print("PROBE ADAPTER:", port.adapterReport)
        #expect(port.adapterReport.last == "FTDI latency timer: 16 ms")
        let during = port.setReceiveLatency(SerialPort.transferReceiveLatency)
        print("PROBE TRANSFER:", during)
        #expect(during.last == "FTDI latency timer: 1 ms")
        // It stays set through a pause and a rate change.
        Thread.sleep(forTimeInterval: 5)
        try port.reconfigure(SerialConfig(baudRate: 9600))
        Thread.sleep(forTimeInterval: 1)
        let interface = PortDescription.lookUp(path: path)?.usbInterfaceNumber
        #expect(FTDILatency.read(path: path, interface: interface) == 1, "after 6 s and a rate change")
        #expect(port.setReceiveLatency(SerialPort.idleReceiveLatency).last == "FTDI latency timer: 16 ms")
    }
}
