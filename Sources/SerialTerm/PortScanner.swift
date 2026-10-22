// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
import IOKit
import IOKit.serial

/// A serial device as seen by IOKit, with USB details when the device is a USB adapter.
struct SerialPortInfo: Identifiable, Hashable {
    /// Callout device, e.g. /dev/cu.usbserial-A50285BI. Always use cu.*, not tty.*:
    /// tty.* blocks on open until carrier detect is asserted.
    var path: String
    var usbVendor: String?
    var usbProduct: String?
    var usbSerialNumber: String?
    /// The USB interface the port belongs to. The ports of a multi-port adapter share the
    /// device's serial number; this tells them apart.
    var usbInterface: Int?
    var vendorID: Int?
    var productID: Int?

    var id: String { path }
    var isUSB: Bool { vendorID != nil }

    var shortPath: String { path.replacingOccurrences(of: "/dev/", with: "") }

    var displayName: String {
        guard isUSB else { return shortPath }
        var name = usbProduct ?? usbVendor ?? "USB serial"
        if let sn = usbSerialNumber, !sn.isEmpty { name += " – \(sn)" }
        return "\(name)  (\(shortPath))"
    }

    /// The port in `ports` that is the one remembered as `path`, `serialNumber` and `interface`.
    /// The same name with the same serial number, or none on both, comes first: the device hasn't
    /// moved. (A device with a serial number at the name of one without is another device: names
    /// can follow the USB socket.) Otherwise the serial number is followed to a new name, but only
    /// when that is unambiguous, since every port of a multi-port adapter has the same one.
    static func find(path: String?, serialNumber: String?, interface: Int?, in ports: [SerialPortInfo]) -> SerialPortInfo? {
        let serialNumber = serialNumber.nonEmpty
        if let path, let p = ports.first(where: { $0.path == path }), p.usbSerialNumber.nonEmpty == serialNumber {
            return p
        }
        guard let serialNumber else { return nil }
        let candidates = ports.filter { p in
            p.usbSerialNumber == serialNumber && (interface == nil || p.usbInterface == nil || p.usbInterface == interface)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

extension Optional where Wrapped == String {
    /// nil for an empty string too (some devices report an empty serial number).
    var nonEmpty: String? {
        guard let s = self, !s.isEmpty else { return nil }
        return s
    }
}

/// Lists serial ports and keeps the list current as devices are plugged in and removed.
@MainActor
final class PortScanner: ObservableObject {
    @Published private(set) var ports: [SerialPortInfo] = []

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init() {
        refresh()
        watch()
    }

    deinit {
        // The callbacks hold an unretained pointer to the scanner: stop them before it goes.
        if let notifyPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                                  .defaultMode)
            IONotificationPortDestroy(notifyPort)
        }
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
    }

    func refresh() {
        ports = Self.scan()
    }

    static func scan() -> [SerialPortInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary(), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [SerialPortInfo] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let info = info(for: service) { result.append(info) }
        }
        // USB adapters first, then by name.
        return result.sorted { a, b in
            if a.isUSB != b.isUSB { return a.isUSB }
            return a.path < b.path
        }
    }

    private static func matchingDictionary() -> CFMutableDictionary {
        let dict = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        dict[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        return dict as CFMutableDictionary
    }

    private static func info(for service: io_object_t) -> SerialPortInfo? {
        guard let path = IORegistryEntryCreateCFProperty(
            service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }

        // USB details live on an ancestor (the USB device), so search up the tree.
        func ancestorProperty(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            )
        }

        return SerialPortInfo(
            path: path,
            usbVendor: ancestorProperty("USB Vendor Name") as? String,
            usbProduct: ancestorProperty("USB Product Name") as? String,
            usbSerialNumber: ancestorProperty("USB Serial Number") as? String,
            usbInterface: (ancestorProperty("bInterfaceNumber") as? NSNumber)?.intValue,
            vendorID: (ancestorProperty("idVendor") as? NSNumber)?.intValue,
            productID: (ancestorProperty("idProduct") as? NSNumber)?.intValue
        )
    }

    private func watch() {
        guard let notifyPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.notifyPort = notifyPort
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
            .defaultMode
        )

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain the iterator to re-arm the notification.
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            let scanner = Unmanaged<PortScanner>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { scanner.refresh() }
        }

        IOServiceAddMatchingNotification(
            notifyPort, kIOFirstMatchNotification, Self.matchingDictionary(), callback, refcon, &addedIterator
        )
        callback(refcon, addedIterator)
        IOServiceAddMatchingNotification(
            notifyPort, kIOTerminatedNotification, Self.matchingDictionary(), callback, refcon, &removedIterator
        )
        callback(refcon, removedIterator)
    }
}
