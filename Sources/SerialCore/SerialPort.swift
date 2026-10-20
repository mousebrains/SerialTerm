import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SerialError: Error, CustomStringConvertible {
    case open(path: String, errno: Int32)
    case configure(step: String, errno: Int32)
    case unsupportedBaudRate(Int)
    case notOpen

    public var description: String {
        switch self {
        case let .open(path, e):
            return "Cannot open \(path): \(String(cString: strerror(e)))"
        case let .configure(step, e):
            return "Cannot configure port (\(step)): \(String(cString: strerror(e)))"
        case let .unsupportedBaudRate(rate):
            return "The driver rejected \(rate) baud"
        case .notOpen:
            return "Port is not open"
        }
    }
}

#if os(macOS)
// From <IOKit/serial/ioss.h> and <sys/ttycom.h>; Swift does not import these function-like macros.
private let TIOCEXCL_: UInt = 0x2000_740D
private let IOSSIOSPEED_: UInt = 0x8008_5402
/// Receive latency in microseconds. Honoured by some drivers; best effort.
private let IOSSDATALAT_: UInt = 0x8008_5400
private let TIOCMBIS_: UInt = 0x8004_746C
private let TIOCMBIC_: UInt = 0x8004_746B
#endif

/// Rates that termios can set directly. Anything else needs a driver-specific path.
private let termiosBaudRates: Set<Int> = [
    50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 7200, 9600,
    14_400, 19_200, 28_800, 38_400, 57_600, 76_800, 115_200, 230_400,
]

/// A raw serial port. Reads arrive on a private queue via `onData`; writes are queued
/// and performed in order on a separate queue so a slow line never blocks the caller.
public final class SerialPort: @unchecked Sendable {
    public let path: String
    public private(set) var config: SerialConfig

    /// Called on the port's read queue with each chunk received.
    public var onData: ((Data) -> Void)?
    /// Called once when the port closes, with an error if it closed unexpectedly
    /// (for example, the USB dongle was unplugged).
    public var onClose: ((Error?) -> Void)?

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "SerialPort.read", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "SerialPort.write", qos: .userInitiated)
    private var closeError: Error?
    /// Bytes queued by `write` but not yet accepted by the driver.
    private let pendingCondition = NSCondition()
    private var pendingBytes = 0

    public init(path: String, config: SerialConfig) {
        self.path = path
        self.config = config
    }

    deinit {
        close()
    }

    public var isOpen: Bool {
        lock.withLock { fd >= 0 }
    }

    public func open() throws {
        let fd = posixOpen(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.open(path: path, errno: errno) }

        do {
            #if os(macOS)
            // Refuse other opens of the device while we hold it.
            _ = ioctl(fd, TIOCEXCL_)
            #endif
            try Self.apply(config, to: fd)
            #if os(macOS)
            var latencyMicroseconds: UInt = 1000
            _ = ioctl(fd, IOSSDATALAT_, &latencyMicroseconds)
            #endif
            tcflush(fd, TCIOFLUSH)
        } catch {
            _ = posixClose(fd)
            throw error
        }

        lock.withLock { self.fd = fd }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in self?.drainInput() }
        source.setCancelHandler { [weak self] in
            _ = posixClose(fd)
            guard let self else { return }
            let error = self.lock.withLock { self.closeError }
            self.onClose?(error)
        }
        readSource = source
        source.resume()
    }

    /// Change line settings on an open port.
    public func reconfigure(_ newConfig: SerialConfig) throws {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { throw SerialError.notOpen }
        try Self.apply(newConfig, to: fd)
        config = newConfig
    }

    public func close() {
        close(error: nil)
    }

    private func close(error: Error?) {
        let source: DispatchSourceRead? = lock.withLock {
            guard fd >= 0 else { return nil }
            fd = -1
            closeError = error
            let s = readSource
            readSource = nil
            return s
        }
        source?.cancel()
    }

    /// Queue bytes for transmission.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingCondition.withLock { pendingBytes += data.count }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeAll(data)
            self.pendingCondition.withLock {
                self.pendingBytes -= data.count
                self.pendingCondition.broadcast()
            }
        }
    }

    /// Block until everything queued with `write` has been handed to the driver.
    public func waitForPendingWrites() {
        writeQueue.sync {}
    }

    /// Block until at most `maxPending` queued bytes remain (0 = all written). Senders use a
    /// non-zero limit to keep the driver busy without queueing unbounded data.
    public func waitForPendingWrites(maxPending: Int) {
        if maxPending <= 0 { return waitForPendingWrites() }
        pendingCondition.lock()
        while pendingBytes > maxPending && isOpen {
            _ = pendingCondition.wait(until: Date().addingTimeInterval(0.25))
        }
        pendingCondition.unlock()
    }

    public func sendBreak() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            let fd = self.lock.withLock { self.fd }
            if fd >= 0 { tcsendbreak(fd, 0) }
        }
    }

    public func setDTR(_ on: Bool) { setModemBit(TIOCM_DTR, on) }
    public func setRTS(_ on: Bool) { setModemBit(TIOCM_RTS, on) }

    // MARK: - Private

    private func setModemBit(_ bit: Int32, _ on: Bool) {
        #if os(macOS)
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return }
        var bits = bit
        _ = ioctl(fd, on ? TIOCMBIS_ : TIOCMBIC_, &bits)
        #endif
    }

    private func drainInput() {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { posixRead(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onData?(Data(buffer[0..<n]))
                if n < buffer.count { return }
            } else if n == 0 {
                close(error: SerialError.open(path: path, errno: ENXIO))
                return
            } else {
                let e = errno
                if e == EAGAIN || e == EINTR { return }
                // ENXIO / EIO: device went away.
                close(error: SerialError.open(path: path, errno: e))
                return
            }
        }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let fd = lock.withLock { self.fd }
                guard fd >= 0 else { return }
                let n = posixWrite(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    // Output buffer full (or flow control holding us off); wait for room.
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 250)
                } else {
                    return
                }
            }
        }
    }

    private static func apply(_ config: SerialConfig, to fd: Int32) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw SerialError.configure(step: "tcgetattr", errno: errno) }

        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)

        t.c_cflag &= ~tcflag_t(CSIZE)
        switch config.dataBits {
        case 5: t.c_cflag |= tcflag_t(CS5)
        case 6: t.c_cflag |= tcflag_t(CS6)
        case 7: t.c_cflag |= tcflag_t(CS7)
        default: t.c_cflag |= tcflag_t(CS8)
        }

        t.c_cflag &= ~tcflag_t(PARENB | PARODD)
        switch config.parity {
        case .none: break
        case .even: t.c_cflag |= tcflag_t(PARENB)
        case .odd: t.c_cflag |= tcflag_t(PARENB | PARODD)
        }

        if config.stopBits == 2 {
            t.c_cflag |= tcflag_t(CSTOPB)
        } else {
            t.c_cflag &= ~tcflag_t(CSTOPB)
        }

        t.c_cflag &= ~tcflag_t(CRTSCTS)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch config.flowControl {
        case .none: break
        case .rtsCts: t.c_cflag |= tcflag_t(CRTSCTS)
        case .xonXoff: t.c_iflag |= tcflag_t(IXON | IXOFF)
        }

        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }

        let standard = termiosBaudRates.contains(config.baudRate)
        // For non-standard rates, set a placeholder here and the real rate below,
        // because tcsetattr would reject it (and resets the speed anyway).
        cfsetspeed(&t, speed_t(standard ? config.baudRate : 9600))
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw SerialError.configure(step: "tcsetattr", errno: errno) }

        if !standard {
            #if os(macOS)
            var speed = speed_t(config.baudRate)
            guard ioctl(fd, IOSSIOSPEED_, &speed) == 0 else {
                throw SerialError.unsupportedBaudRate(config.baudRate)
            }
            #else
            throw SerialError.unsupportedBaudRate(config.baudRate)
            #endif
        }
    }
}

// Free functions so the class's own `open`/`close`/`write` don't shadow the system calls.
private func posixOpen(_ path: String, _ flags: Int32) -> Int32 { open(path, flags) }
private func posixClose(_ fd: Int32) -> Int32 { close(fd) }
private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buf, count) }
private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buf, count) }
