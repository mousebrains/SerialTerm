// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

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
///
/// The descriptor is only used while holding `lock` (see `withFD`), and `close` gives it up under
/// the same lock, so no call can reach a descriptor number that has been closed and reused.
public final class SerialPort: @unchecked Sendable {
    public let path: String
    public var config: SerialConfig { lock.withLock { _config } }

    /// Called on the port's read queue with each chunk received.
    public var onData: ((Data) -> Void)?
    /// Called once when the port closes, with an error if it closed unexpectedly
    /// (for example, the USB dongle was unplugged).
    public var onClose: ((Error?) -> Void)?

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var _config: SerialConfig
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "SerialPort.read", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "SerialPort.write", qos: .userInitiated)
    private var closeError: Error?
    private var _adapterReport: [String] = []
    /// Bytes queued by `write` but not yet accepted by the driver.
    private let pendingCondition = NSCondition()
    private var pendingBytes = 0
    /// Bumped by `discardPendingWrites`; queued writes from an older generation are skipped.
    private var writeGeneration = 0
    /// Reused for every read (read queue only).
    private var readBuffer = [UInt8](repeating: 0, count: 65_536)

    public init(path: String, config: SerialConfig) {
        self.path = path
        _config = config
    }

    deinit {
        close()
    }

    public var isOpen: Bool {
        lock.withLock { fd >= 0 }
    }

    /// The adapter and driver behind the port, and whether the driver took the request for a short
    /// receive latency, as found when the port opened. For traces and logs; empty until then.
    public var adapterReport: [String] { lock.withLock { _adapterReport } }

    public func open() throws {
        // O_CLOEXEC: a program the app starts mustn't inherit the port (and keep the device busy).
        let fd = posixOpen(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SerialError.open(path: path, errno: errno) }

        var report = PortDescription.lookUp(path: path)?.lines ?? ["adapter: not listed by IOKit"]
        do {
            #if os(macOS)
            // Refuse other opens of the device while we hold it.
            _ = ioctl(fd, TIOCEXCL_)
            #endif
            try Self.apply(config, to: fd)
            #if os(macOS)
            // Drivers that buffer received bytes may hold a partial packet until this much time
            // passes. Not every driver supports it, and one that accepts it may still not apply it.
            var latencyMicroseconds: UInt = 1000
            let latency = ioctl(fd, IOSSDATALAT_, &latencyMicroseconds) == 0
                ? "accepted" : "refused (\(String(cString: strerror(errno))))"
            report.append("receive latency: asked the driver for 1 ms (IOSSDATALAT): \(latency)")
            #endif
            tcflush(fd, TCIOFLUSH)
        } catch {
            _ = posixClose(fd)
            throw error
        }

        lock.withLock {
            self.fd = fd
            _adapterReport = report
        }

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

    /// Change line settings on an open port. If the driver refuses them, the old settings are
    /// put back (a refused custom rate would otherwise leave the line at the 9600 placeholder).
    public func reconfigure(_ newConfig: SerialConfig) throws {
        try lock.withLock {
            guard fd >= 0 else { throw SerialError.notOpen }
            do {
                try Self.apply(newConfig, to: fd)
            } catch {
                try? Self.apply(_config, to: fd)
                throw error
            }
            _config = newConfig
        }
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
        let generation = pendingCondition.withLock {
            pendingBytes += data.count
            return writeGeneration
        }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeAll(data, generation: generation)
            self.pendingCondition.withLock {
                self.pendingBytes -= data.count
                self.pendingCondition.broadcast()
            }
        }
    }

    /// Block until everything queued with `write` has been handed to the driver.
    public func waitForPendingWrites() {
        waitForPendingWrites(maxPending: 0)
    }

    /// Drop output that is queued but not yet sent: writes still waiting here, the rest of the
    /// one being written, and whatever the driver hasn't transmitted (TCOFLUSH). Used when a
    /// protocol rewinds or aborts and that data is stale.
    public func discardPendingWrites() {
        pendingCondition.withLock { writeGeneration += 1 }
        withFD { _ = tcflush($0, TCOFLUSH) }
    }

    /// Blocks until at most `maxPending` queued bytes remain (0 = all written). Senders use a
    /// non-zero limit to keep the driver busy without queueing unbounded data.
    ///
    /// Also returns when the port closes, when `timeout` passes, or when `stop` returns true
    /// (checked about every 0.1 s), so flow control holding the line can't block a cancel forever.
    /// Returns whether the backlog got down to `maxPending`.
    @discardableResult
    public func waitForPendingWrites(maxPending: Int, timeout: TimeInterval? = nil, until stop: (() -> Bool)? = nil) -> Bool {
        let deadline = timeout.map { Uptime.now + $0 }
        pendingCondition.lock()
        defer { pendingCondition.unlock() }
        while pendingBytes > max(0, maxPending) {
            guard isOpen else { return false }
            if let deadline, Uptime.now >= deadline { return false }
            if let stop {
                // Not under our lock: the check may take the caller's own locks.
                pendingCondition.unlock()
                let stopped = stop()
                pendingCondition.lock()
                if stopped { return false }
            }
            // A short wait from now, so a clock change can't stretch it.
            let wait = deadline.map { min(0.1, max(0, $0 - Uptime.now)) } ?? 0.1
            _ = pendingCondition.wait(until: Date(timeIntervalSinceNow: wait))
        }
        return true
    }

    public func sendBreak() {
        writeQueue.async { [weak self] in
            self?.withFD { _ = tcsendbreak($0, 0) }
        }
    }

    public func setDTR(_ on: Bool) { setModemBit(TIOCM_DTR, on) }
    public func setRTS(_ on: Bool) { setModemBit(TIOCM_RTS, on) }

    // MARK: - Private

    /// Runs `body` with the open descriptor while holding `lock`, so `close` can't give it up
    /// meanwhile. `body` must not block for long or take `lock`.
    @discardableResult
    private func withFD<T>(_ body: (Int32) throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return nil }
        return try body(fd)
    }

    private func setModemBit(_ bit: Int32, _ on: Bool) {
        #if os(macOS)
        withFD { fd in
            var bits = bit
            _ = ioctl(fd, on ? TIOCMBIS_ : TIOCMBIC_, &bits)
        }
        #endif
    }

    /// Runs on the read queue, as does the cancel handler that closes the descriptor, so the
    /// descriptor stays valid here without holding the lock.
    private func drainInput() {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return }
        while true {
            let n = readBuffer.withUnsafeMutableBytes { posixRead(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onData?(Data(readBuffer[0..<n]))
                if n < readBuffer.count { return }
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

    /// Writes `data`, stopping early if it is discarded meanwhile (a protocol rewind or abort),
    /// so stale data doesn't keep going out after `discardPendingWrites`.
    private func writeAll(_ data: Data, generation: Int) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard pendingCondition.withLock({ writeGeneration == generation }) else { return }
                // O_NONBLOCK: write never blocks, so it's fine under the lock.
                let result: (n: Int, error: Int32)? = withFD { fd in
                    let n = posixWrite(fd, raw.baseAddress! + offset, raw.count - offset)
                    return (n, n < 0 ? errno : 0)
                }
                guard let result else { return }  // closed
                if result.n > 0 {
                    offset += result.n
                } else if result.n < 0 && (result.error == EAGAIN || result.error == EINTR) {
                    // Output buffer full (or flow control holding us off); wait for room, without
                    // the lock. At worst poll waits on a number reused meanwhile, which is harmless.
                    let fd = lock.withLock { self.fd }
                    guard fd >= 0 else { return }
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 250)
                } else if result.n < 0 {
                    // EIO, ENXIO: the device went away or the driver failed. Close, so the session
                    // hears of it even if no read comes along to notice.
                    close(error: SerialError.open(path: path, errno: result.error))
                    return
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
