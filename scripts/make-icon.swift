// Draws Kitty Finder's app icon (a two-tone kitty face) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

let lightBlue = NSColor(srgbRed: 0.60, green: 0.84, blue: 1.00, alpha: 1)
let deepBlue = NSColor(srgbRed: 0.18, green: 0.44, blue: 0.87, alpha: 1)
let lightEar = NSColor(srgbRed: 0.47, green: 0.76, blue: 0.97, alpha: 1)
let deepEar = NSColor(srgbRed: 0.13, green: 0.35, blue: 0.75, alpha: 1)
let navy = NSColor(srgbRed: 0.10, green: 0.14, blue: 0.25, alpha: 1)
let pink = NSColor(srgbRed: 1.00, green: 0.56, blue: 0.69, alpha: 1)

/// Draws on a 1024 × 1024 canvas, y pointing down.
func drawIcon() {
    // macOS icon grid: 824 pt body inset 100 pt, continuous-looking corners
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()

    deepBlue.setFill()
    body.fill()

    // Light left half with a gently wavy divide, like a face in profile
    let left = NSBezierPath()
    left.move(to: NSPoint(x: 0, y: 0))
    left.line(to: NSPoint(x: 522, y: 0))
    left.curve(to: NSPoint(x: 508, y: 470), controlPoint1: NSPoint(x: 492, y: 170), controlPoint2: NSPoint(x: 540, y: 330))
    left.curve(to: NSPoint(x: 516, y: 1024), controlPoint1: NSPoint(x: 470, y: 640), controlPoint2: NSPoint(x: 546, y: 820))
    left.line(to: NSPoint(x: 0, y: 1024))
    left.close()
    lightBlue.setFill()
    left.fill()

    // Ears, with pink insides
    func triangle(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint, _ color: NSColor) {
        let p = NSBezierPath()
        p.move(to: a); p.line(to: b); p.line(to: c); p.close()
        color.setFill(); p.fill()
    }
    triangle(NSPoint(x: 176, y: 372), NSPoint(x: 236, y: 146), NSPoint(x: 414, y: 322), lightEar)
    triangle(NSPoint(x: 228, y: 326), NSPoint(x: 252, y: 226), NSPoint(x: 350, y: 312), pink)
    triangle(NSPoint(x: 848, y: 372), NSPoint(x: 788, y: 146), NSPoint(x: 610, y: 322), deepEar)
    triangle(NSPoint(x: 796, y: 326), NSPoint(x: 772, y: 226), NSPoint(x: 674, y: 312), pink)

    // Eyes: dark on the light side, white on the dark side
    navy.setFill()
    NSBezierPath(ovalIn: NSRect(x: 340, y: 440, width: 80, height: 124)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 604, y: 440, width: 80, height: 124)).fill()

    // Nose
    triangle(NSPoint(x: 476, y: 628), NSPoint(x: 548, y: 628), NSPoint(x: 512, y: 672), pink)

    // Mouth and whiskers: navy on the left, white on the right
    func stroke(_ color: NSColor, width: CGFloat, _ build: (NSBezierPath) -> Void) {
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        build(p)
        color.setStroke(); p.stroke()
    }
    stroke(navy, width: 16) { p in
        p.move(to: NSPoint(x: 444, y: 700)); p.curve(to: NSPoint(x: 512, y: 700), controlPoint1: NSPoint(x: 460, y: 748), controlPoint2: NSPoint(x: 500, y: 748))
        for (y1, y2) in [(612.0, 638.0), (668.0, 668.0), (724.0, 698.0)] {
            p.move(to: NSPoint(x: 176, y: y1)); p.line(to: NSPoint(x: 360, y: y2))
        }
    }
    stroke(.white, width: 16) { p in
        p.move(to: NSPoint(x: 512, y: 700)); p.curve(to: NSPoint(x: 580, y: 700), controlPoint1: NSPoint(x: 524, y: 748), controlPoint2: NSPoint(x: 564, y: 748))
        for (y1, y2) in [(612.0, 638.0), (668.0, 668.0), (724.0, 698.0)] {
            p.move(to: NSPoint(x: 848, y: y1)); p.line(to: NSPoint(x: 664, y: y2))
        }
    }
    NSGraphicsContext.current?.restoreGraphicsState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Flip so the drawing code can use y-down coordinates
    ctx.cgContext.translateBy(x: 0, y: 1024)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
try png(pixels: 1024).write(to: root.appending(path: "build/AppIcon-preview.png"))
let out = root.appending(path: "Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
