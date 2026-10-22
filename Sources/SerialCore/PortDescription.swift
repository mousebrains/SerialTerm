// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.serial
#endif

/// What serves a serial device: the USB adapter and the driver, as IOKit reports them. Written at
/// the top of each transfer trace, because an adapter shows in the timing: an FTDI FT232R on macOS
/// was seen holding the last partial USB packet of a burst for about 230 ms.
public struct PortDescription: Equatable, Sendable {
    public var usbVendor: String?
    public var usbProduct: String?
    public var usbSerialNumber: String?
    public var vendorID: Int?
    public var productID: Int?
    /// bcdDevice: the chip's revision, e.g. 0x0600 for an FT232R.
    public var deviceRelease: Int?
    /// IOUSBLib's numbering: 0 low, 1 full, 2 high, 3 super, 4 super+.
    public var usbSpeed: Int?
    /// The IOKit class serving the port (the serial client's provider), e.g. AppleUSBFTDI. A
    /// DriverKit driver shows as IOUserSerial, with its own class name in `userClass`.
    public var driverClass: String?
    public var userClass: String?
    /// The driver's bundle (a kext's CFBundleIdentifier, or a DriverKit driver's server name).
    public var driverBundle: String?

    public init(usbVendor: String? = nil, usbProduct: String? = nil, usbSerialNumber: String? = nil,
                vendorID: Int? = nil, productID: Int? = nil, deviceRelease: Int? = nil, usbSpeed: Int? = nil,
                driverClass: String? = nil, userClass: String? = nil, driverBundle: String? = nil) {
        self.usbVendor = usbVendor
        self.usbProduct = usbProduct
        self.usbSerialNumber = usbSerialNumber
        self.vendorID = vendorID
        self.productID = productID
        self.deviceRelease = deviceRelease
        self.usbSpeed = usbSpeed
        self.driverClass = driverClass
        self.userClass = userClass
        self.driverBundle = driverBundle
    }

    /// "adapter: …" and "driver: …" lines for a trace or log.
    public var lines: [String] {
        var adapter: String
        if let vendorID, let productID {
            adapter = [usbProduct, usbVendor].compactMap { $0 }.joined(separator: ", ")
            if adapter.isEmpty { adapter = "USB device" }
            adapter += String(format: "; USB %04x:%04x", vendorID, productID)
            if let deviceRelease { adapter += String(format: " rev %04x", deviceRelease) }
            if let sn = usbSerialNumber, !sn.isEmpty { adapter += ", serial \(sn)" }
            if let usbSpeed { adapter += ", " + Self.speedName(usbSpeed) }
        } else {
            adapter = "not a USB device"
        }
        var driver = driverClass ?? "unknown"
        if let userClass, userClass != driverClass { driver += " (\(userClass))" }
        if let driverBundle { driver += ", \(driverBundle)" }
        return ["adapter: \(adapter)", "driver: \(driver)"]
    }

    static func speedName(_ speed: Int) -> String {
        switch speed {
        case 0: return "low speed"
        case 1: return "full speed"
        case 2: return "high speed"
        case 3: return "SuperSpeed"
        case 4: return "SuperSpeed+"
        default: return "speed \(speed)"
        }
    }

    /// The device at `path` (a /dev/cu.* or /dev/tty.* name), or nil if IOKit doesn't list it
    /// (a pseudo-terminal, for one).
    public static func lookUp(path: String) -> PortDescription? {
        #if canImport(IOKit)
        let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFMutableDictionary, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let names = [kIOCalloutDeviceKey, kIODialinDeviceKey].compactMap { property(service, $0) as? String }
            if names.contains(path) { return describe(service) }
        }
        #endif
        return nil
    }

    #if canImport(IOKit)
    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func describe(_ service: io_object_t) -> PortDescription {
        // USB details live on an ancestor (the USB device), so search up the tree.
        func ancestor(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        var d = PortDescription(
            usbVendor: ancestor("USB Vendor Name") as? String,
            usbProduct: ancestor("USB Product Name") as? String,
            usbSerialNumber: ancestor("USB Serial Number") as? String,
            vendorID: (ancestor("idVendor") as? NSNumber)?.intValue,
            productID: (ancestor("idProduct") as? NSNumber)?.intValue,
            deviceRelease: (ancestor("bcdDevice") as? NSNumber)?.intValue,
            usbSpeed: (ancestor("Device Speed") as? NSNumber)?.intValue
        )
        var driver: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &driver) == KERN_SUCCESS {
            defer { IOObjectRelease(driver) }
            d.driverClass = IOObjectCopyClass(driver)?.takeRetainedValue() as String?
            d.userClass = property(driver, "IOUserClass") as? String
            d.driverBundle = (property(driver, "IOUserServerName") ?? property(driver, kCFBundleIdentifierKey as String)) as? String
        }
        return d
    }
    #endif
}
