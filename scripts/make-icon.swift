// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch
//
// Draws SerialTerm's app icon, an old green-screen terminal reading SERIAL / TERM, and writes
// it as an .icns. Each size is drawn on its own so the screen's dots land on whole pixels; below
// 128 pixels the words can't be read, so the screen shows a prompt instead.
//
//   swift scripts/make-icon.swift [assets/AppIcon.icns]
//
// Set ICON_PNG_DIR to a folder to also save each size there as a PNG, for a look.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.dropFirst().first ?? "assets/AppIcon.icns"

// 5×7 dot-matrix letters, and a prompt, >_, for the small sizes.
let font: [Character: [String]] = [
    "S": [".###.", "#...#", "#....", ".###.", "....#", "#...#", ".###."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
]
let words = ["SERIAL", "TERM"]
let prompt = ["#......", ".#.....", "..#....", ".#.....", "#...###"]

/// The lit dots of `lines` in 5×7 letters one column apart, lines two rows apart.
func dots(_ lines: [String]) -> [(x: Int, y: Int)] {
    var lit: [(x: Int, y: Int)] = []
    for (row, line) in lines.enumerated() {
        for (col, ch) in line.enumerated() {
            for (y, bits) in font[ch]!.enumerated() {
                for (x, bit) in bits.enumerated() where bit == "#" { lit.append((col * 6 + x, row * 9 + y)) }
            }
        }
    }
    return lit
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

/// Fills `path` with a top-to-bottom gradient.
func fill(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor]) {
    let box = path.boundingBoxOfPath
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
    ctx.restoreGState()
}

/// Draws the icon `size` pixels square. Drawing is in a 1024-point, y-down space on the
/// macOS icon grid (an 824-point rounded square, inset 100); `px` converts device pixels to it.
func draw(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)
    func px(_ n: CGFloat) -> CGFloat { n / scale }
    // Shadow offsets and blurs are in device pixels, and y-up.
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ color: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: color)
    }
    let small = size < 128

    // The tile.
    let tile = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    shadow(10, 20, rgb(0x000000, 0.3))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0x2c4459))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, tile, [rgb(0x557a99), rgb(0x2b4258)])

    // The terminal: a putty case on a foot, with the screen set into it.
    let foot = rounded(CGRect(x: 322, y: 772, width: 380, height: 58), 22)
    let neck = CGRect(x: 446, y: 730, width: 132, height: 52)
    let body = rounded(CGRect(x: 148, y: 176, width: 728, height: 572), 64)
    ctx.saveGState()
    shadow(14, 28, rgb(0x000000, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(ctx, foot, [rgb(0xd6cba9), rgb(0xa89b76)])
    ctx.setFillColor(rgb(0x9c8f6c))
    ctx.fill(neck)
    fill(ctx, body, [rgb(0xefe7cf), rgb(0xcfc29e)])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    if !small {
        // A highlight along the top edge of the case.
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.setStrokeColor(rgb(0xffffff, 0.55))
        ctx.setLineWidth(max(px(1), 6))
        ctx.addPath(rounded(CGRect(x: 148, y: 179, width: 728, height: 600), 64))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The bezel's recess and the glass.
    let recess = rounded(CGRect(x: 190, y: 214, width: 644, height: 454), 46)
    fill(ctx, recess, [rgb(0x9f936f), rgb(0xc2b590)])
    let glass = CGRect(x: 202, y: 226, width: 620, height: 430)
    let screen = rounded(glass, 38)
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0x11351e), rgb(0x061409)]),
                           startCenter: CGPoint(x: glass.midX, y: glass.midY - 20), startRadius: 0,
                           endCenter: CGPoint(x: glass.midX, y: glass.midY), endRadius: 400, options: [.drawsAfterEndLocation])

    // The dots, snapped to whole device pixels, and a block cursor after TERM.
    let lit: [(x: Int, y: Int)]
    let cols: Int, rows: Int, cell: CGFloat
    if small {
        lit = prompt.enumerated().flatMap { y, bits in bits.enumerated().filter { $0.1 == "#" }.map { (x: $0.0, y: y) } }
        cols = 7; rows = 5
        cell = max(1, (min(glass.width * scale / 8, glass.height * scale / 6)).rounded(.down))
    } else {
        lit = dots(words)
        cols = 35; rows = 16
        cell = (glass.width * scale / CGFloat(cols + 2)).rounded(.down)
    }
    let x0 = (glass.midX * scale - cell * CGFloat(cols) / 2).rounded()
    let y0 = (glass.midY * scale - cell * CGFloat(rows) / 2).rounded()
    let dot = small || cell < 4 ? cell : cell * 0.8
    func cellRect(_ d: (x: Int, y: Int), _ size: CGFloat, across: Int = 1, down: Int = 1) -> CGRect {
        let gap = (cell - size) / 2
        return CGRect(x: px(x0 + CGFloat(d.x) * cell + gap), y: px(y0 + CGFloat(d.y) * cell + gap),
                      width: px(size + CGFloat(across - 1) * cell), height: px(size + CGFloat(down - 1) * cell))
    }
    let radius = cell >= 8 ? px(dot * 0.22) : 0
    // A wide bloom, then a tight glow.
    for (blur, alpha) in [(cell * 4, 0.5), (cell * 1.2, 0.9)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: max(1.5, blur), color: rgb(0x2dff63, alpha))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(rgb(0x5dff83))
        for d in lit { ctx.addPath(rounded(cellRect(d, dot), radius)) }
        if !small { ctx.addPath(rounded(cellRect((24, 9), dot, across: 5, down: 7), radius)) }
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    if cell >= 8 {
        // Hot centres.
        ctx.setFillColor(rgb(0xd8ffe0, 0.5))
        for d in lit { ctx.addPath(rounded(cellRect(d, dot * 0.45), px(dot * 0.12))) }
        ctx.fillPath()
        // Scan lines, two to a dot.
        ctx.setFillColor(rgb(0x000000, 0.28))
        let period = cell / 2, thick = max(1, (cell / 8).rounded())
        var y = y0 - period * ((y0 - glass.minY * scale) / period).rounded(.up)
        while y < glass.maxY * scale {
            ctx.fill(CGRect(x: glass.minX, y: px(y + period - thick), width: glass.width, height: px(thick)))
            y += period
        }
    }
    // The tube's curve: a shade at the top and a reflection across the upper left.
    ctx.drawLinearGradient(gradient([rgb(0x000000, 0.45), rgb(0x000000, 0)]),
                           start: CGPoint(x: 0, y: glass.minY), end: CGPoint(x: 0, y: glass.minY + 70), options: [])
    if !small {
        let sheen = CGMutablePath()
        sheen.move(to: CGPoint(x: glass.minX, y: glass.minY))
        sheen.addLine(to: CGPoint(x: glass.minX + 430, y: glass.minY))
        sheen.addQuadCurve(to: CGPoint(x: glass.minX, y: glass.minY + 250), control: CGPoint(x: glass.minX + 160, y: glass.minY + 60))
        sheen.closeSubpath()
        ctx.addPath(sheen)
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xffffff, 0.13), rgb(0xffffff, 0.0)]),
                               start: CGPoint(x: glass.minX, y: glass.minY), end: CGPoint(x: glass.minX + 200, y: glass.minY + 160), options: [])
    }
    ctx.restoreGState()

    // The chin: a power light and a vent.
    if !small {
        ctx.saveGState()
        shadow(0, 14, rgb(0xffa21f, 0.9))
        ctx.setFillColor(rgb(0xffb43a))
        ctx.fillEllipse(in: CGRect(x: 228, y: 696, width: 22, height: 22))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xa49773))
        for i in 0..<5 { ctx.addPath(rounded(CGRect(x: 602 + CGFloat(i) * 46, y: 690, width: 26, height: 34), 8)) }
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Can't write \(url.path)") }
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
var drawn: [Int: CGImage] = [:]
for points in [16, 32, 128, 256, 512] {
    for (factor, suffix) in [(1, ""), (2, "@2x")] {
        let size = points * factor
        if drawn[size] == nil { drawn[size] = draw(size: size) }
        writePNG(drawn[size]!, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
if let dir = ProcessInfo.processInfo.environment["ICON_PNG_DIR"] {
    for (size, image) in drawn { writePNG(image, to: URL(fileURLWithPath: dir).appendingPathComponent("icon-\(size).png")) }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
