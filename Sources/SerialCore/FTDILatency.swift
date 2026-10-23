// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.usb
#endif

/// Reads an FTDI chip's latency timer: how long it holds received bytes that don't fill a USB packet
/// before sending them anyway (FTDI's default is 16 ms). Apple's FTDI driver sets the timer from
/// `IOSSDATALAT`, writing the value's low byte as milliseconds although the request is defined in
/// microseconds: 1000 µs became 232 ms, which held every reply a transfer waited for. Reading the
/// chip shows what a request really did. Read only: FTDI's vendor request on the control pipe, which
/// works alongside the driver.
public enum FTDILatency {
    /// The line for traces and logs.
    static func report(_ milliseconds: Int?) -> String {
        milliseconds.map { "FTDI latency timer: \($0) ms" } ?? "FTDI latency timer: couldn't read it"
    }

    /// The latency timer of the FTDI port at `path`, in ms, or nil if it can't be read. Only that
    /// port's channel is asked (a multi-port chip has a timer per channel).
    static func read(path: String, interface: Int?) -> Int? {
        #if canImport(IOKit)
        // FTDI numbers channels from 1 (interface 0 is channel A).
        let channel = UInt16((interface ?? 0) + 1)
        return PortDescription.withSerialService(path: path) { service -> Int? in
            guard let device = usbDevice(above: service) else { return nil }
            defer { IOObjectRelease(device) }
            return getLatency(device, channel: channel)
        } ?? nil
        #else
        return nil
        #endif
    }

    #if canImport(IOKit)
    // From <IOKit/IOCFPlugIn.h> and <IOKit/usb/IOUSBLib.h>; Swift doesn't import these macros.
    private static let deviceUserClientType = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    private static let plugInInterface = CFUUIDGetConstantUUIDWithBytes(
        nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let deviceInterface650 = CFUUIDGetConstantUUIDWithBytes(
        nil, 0x4A, 0xAC, 0x1B, 0x2E, 0x24, 0xC2, 0x47, 0x6A, 0x96, 0x4D, 0x91, 0x33, 0x35, 0x34, 0xF2, 0xCC)

    /// The USB device a serial client belongs to (retained), found up the service plane.
    private static func usbDevice(above service: io_object_t) -> io_object_t? {
        var entry = service
        IOObjectRetain(entry)
        while true {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 { return entry }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS else { return nil }
            entry = parent
        }
    }

    /// FTDI's GET_LATENCY_TIMER vendor request (0x0A, as in FTDI's notes and libftdi) on the device's
    /// control pipe. The device isn't opened: the driver owns its interface, and control requests
    /// don't need it.
    private static func getLatency(_ device: io_object_t, channel: UInt16) -> Int? {
        guard let userClientType = deviceUserClientType, let plugInType = plugInInterface,
              let interfaceType = deviceInterface650 else { return nil }
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(device, userClientType, plugInType, &plugIn, &score) == KERN_SUCCESS,
              let plugIn else { return nil }
        defer { _ = plugIn.pointee?.pointee.Release(plugIn) }
        var dev: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface650>?>?
        let found = withUnsafeMutablePointer(to: &dev) {
            $0.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) {
                plugIn.pointee?.pointee.QueryInterface(plugIn, CFUUIDGetUUIDBytes(interfaceType), $0)
            }
        }
        guard found == S_OK, let dev, let functions = dev.pointee?.pointee else { return nil }
        defer { _ = functions.Release(dev) }
        var value: UInt8 = 0
        let kr = withUnsafeMutablePointer(to: &value) { data in
            // bmRequestType 0xC0: vendor request to the device, device to host.
            var req = IOUSBDevRequest(bmRequestType: 0xC0, bRequest: 0x0A, wValue: 0, wIndex: channel,
                                      wLength: 1, pData: UnsafeMutableRawPointer(data), wLenDone: 0)
            return functions.DeviceRequest(dev, &req)
        }
        return kr == kIOReturnSuccess ? Int(value) : nil
    }
    #endif
}
