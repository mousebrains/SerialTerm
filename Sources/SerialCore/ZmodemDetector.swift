// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation

/// Watches the incoming byte stream for the ZMODEM hex headers that start a transfer.
///
/// - `ZRQINIT` (`**\x18B00`): the remote ran `sz` and wants us to receive.
/// - `ZRINIT`  (`**\x18B01`): the remote ran `rz` and is waiting for us to send.
///
/// Matches are found even when a header is split across reads.
public struct ZmodemDetector: Sendable {
    public enum Trigger: Equatable, Sendable {
        /// Remote is sending; start a receive.
        case remoteSending
        /// Remote is receiving; ask the user which files to send.
        case remoteReceiving
    }

    public struct Match: Equatable, Sendable {
        public var trigger: Trigger
        /// Offset in the scanned chunk where the header began (0 if it began in an earlier chunk).
        public var headerStart: Int
        /// Offset just past the matched header bytes.
        public var headerEnd: Int
        /// How many of the header's bytes arrived in earlier chunks (the start of `prefix`).
        public var carried = 0
    }

    static let prefix: [UInt8] = [0x2A, 0x2A, 0x18, 0x42, 0x30] // "**", ZDLE, "B0"
    private var matched = 0

    public init() {}

    public mutating func reset() {
        matched = 0
    }

    /// Scan a chunk; returns the first header found, if any. Bytes after the match are not scanned.
    public mutating func scan(_ data: Data) -> Match? {
        let prefix = Self.prefix
        for (i, byte) in data.enumerated() {
            if matched == prefix.count {
                matched = 0
                let start = max(0, i - prefix.count), carried = max(0, prefix.count - i)
                switch byte {
                case 0x30: return Match(trigger: .remoteSending, headerStart: start, headerEnd: i + 1, carried: carried)
                case 0x31: return Match(trigger: .remoteReceiving, headerStart: start, headerEnd: i + 1, carried: carried)
                default: break
                }
            }
            if byte == prefix[matched] {
                matched += 1
            } else if byte == prefix[0] {
                // "***" still leaves us with a valid "**" prefix.
                matched = (matched >= 1 && prefix[matched - 1] == 0x2A) ? min(matched, 2) : 1
            } else {
                matched = 0
            }
        }
        return nil
    }
}
