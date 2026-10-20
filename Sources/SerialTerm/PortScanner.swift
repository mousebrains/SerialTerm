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
