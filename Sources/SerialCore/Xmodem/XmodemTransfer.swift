// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Wire bytes for XMODEM (Ward Christensen's, with the CRC and 1K-block extensions) and
/// YMODEM (Chuck Forsberg's batch XMODEM: a block 0 carrying each file's name and size).
enum X {
    static let soh: UInt8 = 0x01        // 128-byte block follows
    static let stx: UInt8 = 0x02        // 1024-byte block follows
    static let eot: UInt8 = 0x04
    static let ack: UInt8 = 0x06
    static let nak: UInt8 = 0x15        // also the receiver's request for checksum mode
    static let can: UInt8 = 0x18
    static let crcRequest: UInt8 = 0x43 // 'C': the receiver's request for CRC mode
    /// CP/M end of file: fills the last data block.
    static let eofPad: UInt8 = 0x1A

    /// The standard abort, as lrzsz sends it: CANs, then backspaces to erase them if a shell
    /// receives them.
    static let abortSequence = [UInt8](repeating: can, count: 8) + [UInt8](repeating: 0x08, count: 8)

    /// Seconds to wait for a block, or for the reply to one, before trying again.
    static let timeout: TimeInterval = 10
    /// Times a receiver asks for CRC-16 before falling back to the checksum (XMODEM only).
    static let crcAttempts = 3
    /// Seconds allowed between the bytes of one block.
    static let byteTimeout: TimeInterval = 1
    /// Attempts at one block (or EOT) before giving up.
    static let retries = 10

    /// A block as sent: start byte, number and its complement, `size` data bytes (`data`, then
    /// `pad`), and an arithmetic checksum or CRC-16/XMODEM (high byte first).
    static func block<C: Collection>(_ number: UInt8, _ data: C, size: Int, crc: Bool, pad: UInt8) -> [UInt8]
        where C.Element == UInt8 {
        var out: [UInt8] = [size == 1024 ? stx : soh, number, ~number]
        out.reserveCapacity(size + 5)
        out += data.prefix(size)
        out += repeatElement(pad, count: max(0, size - data.count))
        let payload = out[3...]
        if crc {
            let c = CRC.crc16(payload)
            out += [UInt8(c >> 8), UInt8(c & 0xFF)]
        } else {
            out.append(checksum(payload))
        }
        return out
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0, &+)
    }

    /// YMODEM block 0: "name NUL size mtime(octal) mode(octal) serial filesleft bytesleft NUL",
    /// the same fields as a ZMODEM ZFILE offer. An empty name ends the batch.
    static func header(name: String, size: Int, modified: Date?, filesLeft: Int, bytesLeft: Int) -> [UInt8] {
        let mtime = Int(modified?.timeIntervalSince1970 ?? 0)
        let fields = "\(size) \(String(max(0, mtime), radix: 8)) 100644 0 \(filesLeft) \(bytesLeft)"
        return Array(name.utf8) + [0] + Array(fields.utf8) + [0]
    }
}

/// Built-in XMODEM and YMODEM, both directions. Like `ZmodemTransfer`, the protocol runs on its
/// own thread, reading what `feed` delivers and writing through `onOutput`.
public final class XmodemTransfer: FileTransfer, @unchecked Sendable {
    public let kind: TransferKind
    public var onOutput: ((Data) -> Void)?
    public var waitForOutput: ((_ maxPending: Int) -> Void)?
    public var discardOutput: (() -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onFinish: ((_ success: Bool, _ message: String) -> Void)?
    public var typeReceiveCommand: ((String) -> Void)?
    public var onLeftover: ((Data) -> Void)?
    public let trace: ZmodemTrace?
    public var traceURL: URL? { trace?.url }

    /// Send XMODEM in 1024-byte blocks (XMODEM-1K). YMODEM always does.
    public let xmodem1K: Bool
    /// Typed (it includes the CR) before a send starts, to start the remote's receiver from its
    /// shell: `rx 'name'` or `rb`. Nil types nothing.
    public let receiveCommand: String?
    // Set before `start`; the protocol's own values except in tests.
    /// Seconds to wait for a block, or the reply to one, before trying again.
    var timeout = X.timeout
    /// XMODEM receive: times to ask for CRC-16 before asking for the checksum.
    var crcAttempts = X.crcAttempts

    private let directory: URL
    private let channel = ByteChannel()
    private let lock = NSLock()
    /// The protocol has ended; input goes to `onLeftover`.
    private var ended = false

    /// - Parameter directory: where a YMODEM receive saves files (XMODEM receives name their own).
    /// - Parameter traceURL: where to write the protocol trace (ignored if `traceLevel` is off).
    public init(kind: TransferKind, directory: URL, xmodem1K: Bool = false, receiveCommand: String? = nil,
                traceLevel: ZmodemOptions.TraceLevel = .off, traceURL: URL? = nil) {
        self.kind = kind
        self.directory = directory
        self.xmodem1K = xmodem1K
        self.receiveCommand = receiveCommand
        if traceLevel != .off, let traceURL {
            trace = try? ZmodemTrace(url: traceURL, level: traceLevel)
        } else {
            trace = nil
        }
        trace?.onFailure = { [weak self] error in
            self?.onLog?("Transfer trace stopped: \(error.localizedDescription)")
        }
    }

    public func start() throws {
        guard kind.isBlockProtocol else { throw ZmodemError.protocolError("XmodemTransfer only handles XMODEM and YMODEM") }
        let thread = Thread { [self] in run() }
        thread.name = "XMODEM"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func feed(_ data: Data) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            onLeftover?(data)
            return
        }
        trace?.raw(.rx, data)
        channel.append(data)
        lock.unlock()
    }

    public func cancel() {
        trace?.note("cancel requested")
        // Drop queued output now, so the abort goes out at once rather than after the rest.
        discardOutput?()
        channel.cancel()
    }

    private func run() {
        let trace = self.trace
        let reader = ZReader(channel)
        let link = ZLink(
            reader: reader,
            trace: trace,
            output: { [weak self] data in
                trace?.raw(.tx, data)
                self?.onOutput?(data)
            },
            drain: { [weak self] in self?.waitForOutput?($0) },
            discard: { [weak self] in self?.discardOutput?() },
            status: { [weak self] in self?.onStatus?($0) },
            log: { [weak self] in self?.onLog?($0) }
        )
        let started = Date()
        trace?.note("\(kind.displayName)" + (xmodem1K ? "; XMODEM-1K" : "") + "; trace level \(trace?.level.rawValue ?? "off")")

        var success = false
        var message = ""
        // Until the remote has shown it's running the protocol, what arrives may be anything (a
        // shell's "rx: not found"); it's kept, and shown if nothing comes of it.
        var answered = false
        reader.startCapture()
        do {
            switch kind {
            case .xmodemReceive, .ymodemReceive:
                let receiver = XmodemReceiver(link: link, kind: kind, directory: directory, timeout: timeout,
                                              crcAttempts: crcAttempts)
                defer { answered = receiver.sawBlock }
                let r = try receiver.run()
                message = r.received.isEmpty
                    ? "No files received"
                    : "Received \(Self.files(r.received.count)) (\(ZLink.size(r.bytes)))"
            case .xmodemSend, .ymodemSend:
                let sender = XmodemSender(link: link, kind: kind, xmodem1K: xmodem1K, receiveCommand: receiveCommand,
                                          typeReceiveCommand: typeReceiveCommand, timeout: timeout)
                defer { answered = sender.receiverAnswered }
                let r = try sender.run()
                message = "Sent \(Self.files(r.sent)) (\(ZLink.size(r.bytes)))"
            default:
                break
            }
            success = true
        } catch let error as ZmodemError {
            link.discardUnsent()
            if error != .remoteCancelled {
                // Stop the remote side too. After a local cancel don't wait for it to go out:
                // the line may be what's stuck.
                trace?.note("sending abort sequence (CAN×8, BS×8)")
                link.send(X.abortSequence)
                if error == .cancelled { link.flush() } else { link.waitForOutput() }
            }
            message = error.description
        } catch {
            link.discardUnsent()
            link.send(X.abortSequence)
            message = "\(error)"
        }
        trace?.summary(outcome: (success ? "OK: " : "FAILED: ") + message, duration: Date().timeIntervalSince(started),
                       blocks: true)
        lock.withLock {
            ended = true
            let leftover = reader.takeLeftover(includingCapture: !success && !answered)
            if !leftover.isEmpty { onLeftover?(Data(leftover)) }
        }
        onFinish?(success, message)
    }

    private static func files(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }
}
