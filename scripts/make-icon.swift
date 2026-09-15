#!/usr/bin/swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift OUTPUT_ICONSET_DIRECTORY\n", stderr)
    exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Sources/EdgeeWidget/Resources/EdgeeMark.pdf")
guard let mark = NSImage(contentsOf: source) else {
    fputs("Cannot load the bundled official Edgee mark.\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.imageInterpolation = .high
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 216, yRadius: 216).fill()
        mark.draw(in: NSRect(x: 32, y: 32, width: 960, height: 960), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage,
              let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                  UTType.png.identifier as CFString, 1, nil) else { exit(1) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { exit(1) }
    }
}
