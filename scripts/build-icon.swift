import AppKit
import Foundation
let output = CommandLine.arguments[1]
let icon = NSImage(size: NSSize(width: 1024, height: 1024))
icon.lockFocus()
let bounds = NSRect(x: 0, y: 0, width: 1024, height: 1024)
let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 44, dy: 44), xRadius: 218, yRadius: 218)
NSGradient(colors: [NSColor(calibratedRed: 0.06, green: 0.28, blue: 0.77, alpha: 1), NSColor(calibratedRed: 0.13, green: 0.63, blue: 1, alpha: 1)])!.draw(in: shape, angle: 55)
NSColor.white.withAlphaComponent(0.12).setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 182, y: 182, width: 660, height: 660)); ring.lineWidth = 3; ring.stroke()
let ring2 = NSBezierPath(ovalIn: NSRect(x: 252, y: 252, width: 520, height: 520)); ring2.lineWidth = 3; ring2.stroke()
NSColor.white.setStroke()
for (index, height) in [110.0, 230, 370, 490, 330, 200, 95].enumerated() {
    let x = 270 + Double(index) * 80
    let wave = NSBezierPath(); wave.lineWidth = 37; wave.lineCapStyle = .round
    wave.move(to: NSPoint(x: x, y: 512 - height / 2)); wave.line(to: NSPoint(x: x, y: 512 + height / 2)); wave.stroke()
}
icon.unlockFocus()
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)); NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
