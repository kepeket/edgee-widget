#!/usr/bin/swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let usage = "Usage: make-icon.swift OUTPUT_ICONSET_DIRECTORY"
guard CommandLine.arguments.count == 2 else {
    fputs("\(usage)\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
do {
    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
} catch {
    fputs("make-icon.swift: cannot create output directory: \(error)\n", stderr)
    exit(1)
}

let iconFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func makeImage(pixelSize: Int) -> NSBitmapImageRep? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        return nil
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.setShouldAntialias(true)

    let scale = CGFloat(pixelSize) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    color(0.035, 0.045, 0.043).setFill()
    NSBezierPath(rect: canvas).fill()

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 34, y: 34, width: 956, height: 956),
        xRadius: 224,
        yRadius: 224
    )
    let backgroundGradient = NSGradient(colors: [
        color(0.105, 0.145, 0.135),
        color(0.035, 0.055, 0.051)
    ])!
    backgroundGradient.draw(in: tile, angle: -42)

    color(0.45, 1.0, 0.38, 0.10).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // A rounded, continuous lowercase “e” gives the mark its readable silhouette.
    let e = NSBezierPath()
    e.move(to: NSPoint(x: 748, y: 408))
    e.curve(
        to: NSPoint(x: 677, y: 367),
        controlPoint1: NSPoint(x: 727, y: 394),
        controlPoint2: NSPoint(x: 705, y: 376)
    )
    e.curve(
        to: NSPoint(x: 505, y: 382),
        controlPoint1: NSPoint(x: 628, y: 347),
        controlPoint2: NSPoint(x: 550, y: 361)
    )
    e.curve(
        to: NSPoint(x: 397, y: 469),
        controlPoint1: NSPoint(x: 442, y: 398),
        controlPoint2: NSPoint(x: 404, y: 429)
    )
    e.curve(
        to: NSPoint(x: 418, y: 602),
        controlPoint1: NSPoint(x: 377, y: 518),
        controlPoint2: NSPoint(x: 386, y: 570)
    )
    e.curve(
        to: NSPoint(x: 545, y: 674),
        controlPoint1: NSPoint(x: 444, y: 666),
        controlPoint2: NSPoint(x: 493, y: 688)
    )
    e.curve(
        to: NSPoint(x: 712, y: 604),
        controlPoint1: NSPoint(x: 610, y: 667),
        controlPoint2: NSPoint(x: 670, y: 641)
    )
    e.lineWidth = 112
    e.lineCapStyle = .round
    e.lineJoinStyle = .round
    color(0.69, 1.0, 0.36).setStroke()
    e.stroke()

    let crossbar = NSBezierPath()
    crossbar.move(to: NSPoint(x: 397, y: 515))
    crossbar.line(to: NSPoint(x: 704, y: 515))
    crossbar.lineWidth = 112
    crossbar.lineCapStyle = .round
    color(0.79, 1.0, 0.42).setStroke()
    crossbar.stroke()

    // The sharp cut and bright inset turn the e into a lightning mark at larger sizes.
    let cut = NSBezierPath()
    cut.move(to: NSPoint(x: 515, y: 327))
    cut.line(to: NSPoint(x: 620, y: 487))
    cut.line(to: NSPoint(x: 558, y: 487))
    cut.line(to: NSPoint(x: 652, y: 695))
    cut.line(to: NSPoint(x: 450, y: 501))
    cut.line(to: NSPoint(x: 516, y: 501))
    cut.close()
    color(0.035, 0.055, 0.051).setFill()
    cut.fill()

    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 535, y: 353))
    bolt.line(to: NSPoint(x: 599, y: 476))
    bolt.line(to: NSPoint(x: 565, y: 476))
    bolt.line(to: NSPoint(x: 620, y: 613))
    bolt.line(to: NSPoint(x: 493, y: 501))
    bolt.line(to: NSPoint(x: 539, y: 501))
    bolt.close()
    color(0.82, 1.0, 0.46).setFill()
    bolt.fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

for iconFile in iconFiles {
    guard let bitmap = makeImage(pixelSize: iconFile.pixels),
          let cgImage = bitmap.cgImage,
          let destination = CGImageDestinationCreateWithURL(
              outputURL.appendingPathComponent(iconFile.name) as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        fputs("make-icon.swift: failed to render \(iconFile.name)\n", stderr)
        exit(1)
    }

    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fputs("make-icon.swift: failed to write \(iconFile.name)\n", stderr)
        exit(1)
    }
}
