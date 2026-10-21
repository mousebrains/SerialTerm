// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// How fast typed and pasted text may go out. Many device command lines (a shell parser
/// reading from a small buffer) drop characters that arrive faster than ~10–50 per second.
public struct Pacing: Codable, Equatable, Hashable, Sendable {
    /// 0 = no limit.
    public var charactersPerSecond: Int
    /// Extra pause after each line end (CR, or LF not following CR), in seconds.
    public var lineDelay: Double
    /// Send each character only after the device echoes the previous one (or `echoTimeout` passes).
    public var waitForEcho: Bool
    /// Seconds to wait for an echo before sending the next character anyway.
    public var echoTimeout: Double

    public init(charactersPerSecond: Int = 0, lineDelay: Double = 0, waitForEcho: Bool = false, echoTimeout: Double = 1) {
        self.charactersPerSecond = charactersPerSecond
        self.lineDelay = lineDelay
        self.waitForEcho = waitForEcho
        self.echoTimeout = echoTimeout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Pacing()
        charactersPerSecond = (try? c.decode(Int.self, forKey: .charactersPerSecond)) ?? d.charactersPerSecond
        lineDelay = (try? c.decode(Double.self, forKey: .lineDelay)) ?? d.lineDelay
        waitForEcho = (try? c.decode(Bool.self, forKey: .waitForEcho)) ?? d.waitForEcho
        echoTimeout = (try? c.decode(Double.self, forKey: .echoTimeout)) ?? d.echoTimeout
    }

    public var isOn: Bool { charactersPerSecond > 0 || lineDelay > 0 || waitForEcho }

    /// Short form such as "echo + 30 char/s + 0.5 s/line"; empty when off.
    public var summary: String {
        var parts: [String] = []
        if waitForEcho { parts.append("echo") }
        if charactersPerSecond > 0 { parts.append("\(charactersPerSecond) char/s") }
        if lineDelay > 0 { parts.append("\(String(format: "%g", lineDelay)) s/line") }
        return parts.joined(separator: " + ")
    }
}

/// Sends bytes no faster than `pacing` allows, in order. Used for typed and pasted text only;
/// file transfers write to the port directly.
final class PacedSender: @unchecked Sendable {
    /// Writes a chunk. Called on the pacer's queue.
    var output: ((Data) -> Void)?
    /// Bytes still waiting, reported as the count changes (at most every 0.1 s, and always at 0),
    /// and whether the last character got no echo in time.
    var onPending: ((_ remaining: Int, _ echoMissing: Bool) -> Void)?

    var pacing: Pacing {
        get { lock.withLock { _pacing } }
        set { lock.withLock { _pacing = newValue } }
    }

    /// True while bytes are waiting or the pause after the last one hasn't elapsed.
    var isBusy: Bool { lock.withLock { running } }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "PacedSender")
    private var _pacing = Pacing()
    private var pending: [UInt8] = []
    private var head = 0
    private var running = false
    private var previous: UInt8 = 0
    private var lastReport = Date.distantPast
    /// While waiting for an echo: what satisfies it, the pause to take after it, and the
    /// timeout that sends the next character anyway.
    private var awaiting: (echo: Echo, gap: Double, timeout: DispatchWorkItem)?
    private var echoMissing = false

    private static let cr: UInt8 = 0x0D, lf: UInt8 = 0x0A

    /// The reply that shows the device has taken a character.
    enum Echo: Equatable {
        case byte(UInt8)
        /// CR or LF: devices echo a line end as either or both.
        case lineEnd
        /// Control characters come back in many forms (^C, "\b \b"); any reply will do.
        case anything

        init(for sent: UInt8) {
            switch sent {
            case 0x20...0x7E: self = .byte(sent)
            case PacedSender.cr, PacedSender.lf: self = .lineEnd
            default: self = .anything
            }
        }

        func isSatisfied(by data: Data) -> Bool {
            switch self {
            case let .byte(b): return data.contains(b)
            case .lineEnd: return data.contains(PacedSender.cr) || data.contains(PacedSender.lf)
            case .anything: return !data.isEmpty
            }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        let start: Bool = lock.withLock {
            pending.append(contentsOf: data)
            defer { running = true }
            return !running
        }
        if start { queue.async { [weak self] in self?.pump() } }
    }

    /// Bytes received from the device; may be the echo being waited for.
    func received(_ data: Data) {
        let gap: Double? = lock.withLock {
            guard let a = awaiting, a.echo.isSatisfied(by: data) else { return nil }
            a.timeout.cancel()
            awaiting = nil
            echoMissing = false
            return a.gap
        }
        if let gap { queue.asyncAfter(deadline: .now() + gap) { [weak self] in self?.pump() } }
    }

    /// Drop everything not yet sent.
    func cancel() {
        let had: Bool = lock.withLock {
            defer { pending.removeAll(); head = 0 }
            return head < pending.count
        }
        if had { onPending?(0, false) }
    }

    /// Send the next byte (or, with no per-character pacing, everything up to the next line end),
    /// then come back after the pause it calls for, or once it is echoed. Stops when nothing is left.
    private func pump() {
        let next: (chunk: Data, gap: Double, echo: Echo?, left: Int, missing: Bool)? = lock.withLock {
            guard head < pending.count else {
                running = false
                pending.removeAll()
                head = 0
                return nil
            }
            let p = _pacing
            let perCharacter = p.charactersPerSecond > 0 || p.waitForEcho
            let start = head
            var lineEnd = false
            repeat {
                let b = pending[head]
                head += 1
                lineEnd = b == Self.cr || (b == Self.lf && previous != Self.cr)
                previous = b
            } while !perCharacter && !(lineEnd && p.lineDelay > 0) && head < pending.count
            let chunk = Data(pending[start..<head])
            if head > 4096, head * 2 > pending.count {
                pending.removeFirst(head)
                head = 0
            }
            var gap = p.charactersPerSecond > 0 ? 1 / Double(p.charactersPerSecond) : 0
            if lineEnd { gap += p.lineDelay }
            return (chunk, gap, p.waitForEcho ? Echo(for: chunk.last!) : nil, pending.count - head, echoMissing)
        }
        guard let next else { return }

        if let echo = next.echo {
            // Arm before writing, so a fast echo can't arrive first and be missed.
            let timeout = DispatchWorkItem { [weak self] in self?.echoTimedOut() }
            lock.withLock { awaiting = (echo, next.gap, timeout) }
            queue.asyncAfter(deadline: .now() + max(pacing.echoTimeout, 0.01), execute: timeout)
        }
        output?(next.chunk)
        let now = Date()
        if next.left == 0 || now.timeIntervalSince(lastReport) >= 0.1 {
            lastReport = now
            onPending?(next.left, next.missing)
        }
        if next.echo == nil {
            queue.asyncAfter(deadline: .now() + next.gap) { [weak self] in self?.pump() }
        }
    }

    /// No echo in time: note it and carry on, so a device with echo off is only slowed down.
    private func echoTimedOut() {
        let gap: Double? = lock.withLock {
            guard let a = awaiting else { return nil }
            awaiting = nil
            echoMissing = true
            return a.gap
        }
        guard let gap else { return }
        let left = lock.withLock { pending.count - head }
        onPending?(left, true)
        queue.asyncAfter(deadline: .now() + gap) { [weak self] in self?.pump() }
    }
}
