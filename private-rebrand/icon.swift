import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [20, 29, 40, 50, 57, 58, 60, 72, 76, 80, 87, 100, 114, 120, 144, 152, 167, 180, 1024] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4,
        bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024.0
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()

    // Deep slate-teal background
    NSColor(calibratedRed: 0.04, green: 0.16, blue: 0.20, alpha: 1.0).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()

    // Subtle inner glow ring
    NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.36, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832), xRadius: 180, yRadius: 180).fill()

    // Crisp white document page
    NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: NSRect(x: 248, y: 176, width: 528, height: 672), xRadius: 44, yRadius: 44).fill()

    // Document text bars
    NSColor(calibratedRed: 0.07, green: 0.45, blue: 0.44, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: NSRect(x: 324, y: 650, width: 376, height: 38), xRadius: 19, yRadius: 19).fill()
    NSBezierPath(roundedRect: NSRect(x: 324, y: 548, width: 376, height: 34), xRadius: 17, yRadius: 17).fill()
    NSBezierPath(roundedRect: NSRect(x: 324, y: 446, width: 260, height: 34), xRadius: 17, yRadius: 17).fill()
    NSBezierPath(roundedRect: NSRect(x: 324, y: 344, width: 320, height: 34), xRadius: 17, yRadius: 17).fill()

    // Vibrant cyan-emerald laser scan beam across middle
    NSColor(calibratedRed: 0.00, green: 0.88, blue: 0.72, alpha: 0.95).setFill()
    NSBezierPath(roundedRect: NSRect(x: 140, y: 502, width: 744, height: 22), xRadius: 11, yRadius: 11).fill()

    // Corner auto-crop brackets
    NSColor(calibratedRed: 0.18, green: 0.92, blue: 0.76, alpha: 1.0).setStroke()
    let corners = NSBezierPath()
    corners.lineWidth = 28
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(164.0, 164.0, 104.0, 104.0), (860.0, 164.0, -104.0, 104.0),
                           (164.0, 860.0, 104.0, -104.0), (860.0, 860.0, -104.0, -104.0)] {
        corners.move(to: NSPoint(x: x, y: y + dy))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x + dx, y: y))
    }
    corners.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(size).png"))
}
