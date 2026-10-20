// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
import Testing
@testable import SerialCore

struct ZmodemDetectorTests {
    let zrqinit = Data("rz\r**\u{18}B00000000000000\r\n".utf8)
    let zrinit = Data("**\u{18}B0100000023be50\r\n".utf8)

    @Test func detectsRemoteSending() {
        var d = ZmodemDetector()
        let m = d.scan(zrqinit)
        #expect(m == .init(trigger: .remoteSending, headerStart: 3, headerEnd: 9))
    }

    @Test func detectsRemoteReceiving() {
        var d = ZmodemDetector()
        #expect(d.scan(zrinit)?.trigger == .remoteReceiving)
    }

    @Test func detectsHeaderSplitAcrossChunks() {
        var d = ZmodemDetector()
        #expect(d.scan(Data("hello **\u{18}".utf8)) == nil)
        let m = d.scan(Data("B00000".utf8))
        #expect(m?.trigger == .remoteSending)
        #expect(m?.headerStart == 0)
        #expect(m?.headerEnd == 3)
    }

    @Test func extraLeadingAsterisks() {
        var d = ZmodemDetector()
        #expect(d.scan(Data("****\u{18}B00".utf8))?.trigger == .remoteSending)
    }

    @Test func ignoresOtherFrameTypesAndText() {
        var d = ZmodemDetector()
        #expect(d.scan(Data("**\u{18}B0500".utf8)) == nil)
        #expect(d.scan(Data("** B00 *\u{18}B00 normal text".utf8)) == nil)
    }

    @Test func resetForgetsPartialMatch() {
        var d = ZmodemDetector()
        _ = d.scan(Data("**\u{18}B".utf8))
        d.reset()
        #expect(d.scan(Data("00".utf8)) == nil)
    }
}

struct SessionLoggerTests {
    @Test func escapesControlAndBinary() {
        let data = Data([0x41, 0x0D, 0x0A, 0x09, 0x1B, 0x5C, 0x00, 0xFF])
        #expect(SessionLogger.escape(data) == "A\\r\\n\\t\\e\\\\\\x00\\xFF")
    }

    @Test func writesMillisecondTimestampedLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("t.log")
        let logger = try SessionLogger(url: url)
        logger.log(.rx, Data("login: ".utf8))
        logger.log(.tx, Data("root\r".utf8))
        logger.note("hello")
        logger.flush()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let pattern = #/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} (RX|TX|--) .*$/#
        for line in lines { #expect(line.wholeMatch(of: pattern) != nil, "\(line)") }
        #expect(lines[0].hasSuffix(" RX login: "))
        #expect(lines[1].hasSuffix(" TX root\\r"))
        #expect(lines[2].hasSuffix(" -- hello"))
    }
}
