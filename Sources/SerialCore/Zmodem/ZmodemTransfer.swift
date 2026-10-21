// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Built-in ZMODEM. The protocol runs on its own thread, reading what `feed` delivers
/// and writing through `onOutput`.
public final class ZmodemTransfer: FileTransfer, @unchecked Sendable {
    public let kind: TransferKind
    public var onOutput: ((Data) -> Void)?
    public var waitForOutput: ((_ maxPending: Int) -> Void)?
    public var discardOutput: (() -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onFinish: ((_ success: Bool, _ message: String) -> Void)?

    public let options: ZmodemOptions
    /// Typed (with CR) before a send starts, to start the remote's receiver from its prompt:
    /// "rz" for lrzsz, "zr" for Slocum gliders, "" for none.
    public let receiveCommand: String
    /// Protocol trace for this transfer, if tracing is on.
    public let trace: ZmodemTrace?

    private let directory: URL
    private let channel = ByteChannel()

    /// - Parameter traceURL: where to write the protocol trace (ignored if `options.traceLevel` is off).
    public init(kind: TransferKind, directory: URL, options: ZmodemOptions = ZmodemOptions(), traceURL: URL? = nil,
                receiveCommand: String = "rz") {
        self.kind = kind
        self.directory = directory
        self.options = options
        self.receiveCommand = receiveCommand
        if options.traceLevel != .off, let traceURL {
            trace = try? ZmodemTrace(url: traceURL, level: options.traceLevel)
        } else {
            trace = nil
        }
    }

    /// Bytes received before the transfer started (the remote's opening frame when auto-started).
    public func prime(_ data: Data) {
        trace?.note("opening bytes that triggered auto-start:")
        trace?.raw(.rx, data)
        if let trace, !trace.verbose { trace.line(.rx, "  " + ZmodemTrace.hex([UInt8](data), limit: 64)) }
        channel.append(data)
    }

    public func start() throws {
        switch kind {
        case .zmodemReceive, .zmodemSend: break
        default: throw ZmodemError.protocolError("ZmodemTransfer only handles ZMODEM")
        }
        let thread = Thread { [self] in run() }
        thread.name = "ZMODEM"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func feed(_ data: Data) {
        trace?.raw(.rx, data)
        channel.append(data)
    }

    public func cancel() {
        trace?.note("cancel requested")
        channel.cancel()
    }

    private func run() {
        let trace = self.trace
        let link = ZLink(
            reader: ZReader(channel),
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
        trace?.note("\(kind.displayName); \(options.summary); trace level \(options.traceLevel.rawValue)")

        var success = false
        var message = ""
        do {
            switch kind {
            case .zmodemReceive:
                let r = try ZmodemReceiver(link: link, directory: directory, options: options).run()
                message = r.received.isEmpty
                    ? "No files received"
                    : "Received \(Self.files(r.received.count)) (\(ZLink.size(r.bytes)))"
            case let .zmodemSend(files):
                let r = try ZmodemSender(link: link, options: options, receiveCommand: receiveCommand).run(files: files)
                message = "Sent \(Self.files(r.sent.count)) (\(ZLink.size(r.bytes)))"
                    + (r.skipped.isEmpty ? "" : ", \(r.skipped.count) skipped by receiver")
            default:
                break
            }
            success = true
        } catch let error as ZmodemError {
            if error != .remoteCancelled {
                // Stop the remote side too.
                trace?.note("sending abort sequence (CAN×10, BS×10)")
                link.send(Z.abortSequence)
                link.waitForOutput()
            }
            message = error.description
        } catch {
            link.send(Z.abortSequence)
            message = "\(error)"
        }
        trace?.summary(outcome: (success ? "OK: " : "FAILED: ") + message, duration: Date().timeIntervalSince(started))
        onFinish?(success, message)
    }

    private static func files(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }
}
