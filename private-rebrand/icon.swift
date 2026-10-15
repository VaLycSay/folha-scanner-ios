import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [29, 40, 57, 58, 60, 76, 80, 87, 114, 120, 152, 167, 180, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    NSColor(calibratedRed: 0.035, green: 0.20, blue: 0.18, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.89, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 254, y: 184, width: 516, height: 660), xRadius: 40, yRadius: 40).fill()
    NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.37, alpha: 1).setFill()
    for y in [610, 500, 390] {
        NSBezierPath(roundedRect: NSRect(x: 330, y: y, width: y == 390 ? 230 : 360, height: 34), xRadius: 17, yRadius: 17).fill()
    }
    NSColor(calibratedRed: 0.70, green: 0.88, blue: 0.42, alpha: 1).setStroke()
    let corners = NSBezierPath()
    corners.lineWidth = 25
    for (x, y, dx, dy) in [(170.0, 170.0, 95.0, 95.0), (854, 170, -95, 95), (170, 854, 95, -95), (854, 854, -95, -95)] {
        corners.move(to: NSPoint(x: x, y: y + dy))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x + dx, y: y))
    }
    corners.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(size).png"))
}
