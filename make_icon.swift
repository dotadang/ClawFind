import AppKit
import Foundation

// 基于脚本自身位置推导项目根目录
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outDir = scriptDir.appendingPathComponent("ClawFind/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let sizes = [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024]
let names = [
    "icon_16x16.png",
    "icon_16x16@2x.png",
    "icon_32x32.png",
    "icon_32x32@2x.png",
    "icon_128x128.png",
    "icon_128x128@2x.png",
    "icon_256x256.png",
    "icon_256x256@2x.png",
    "icon_512x512.png",
    "icon_512x512@2x.png"
]

func drawIcon(pixelSize: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.22

    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.53, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.34, green: 0.22, blue: 0.95, alpha: 1)
    ])!
    gradient.draw(in: bg, angle: -45)

    let glowRect = rect.insetBy(dx: size * 0.08, dy: size * 0.08)
    let glow = NSBezierPath(roundedRect: glowRect, xRadius: radius * 0.8, yRadius: radius * 0.8)
    NSColor.white.withAlphaComponent(0.10).setFill()
    glow.fill()

    // magnifier
    let ringSize = size * 0.34
    let ringRect = NSRect(x: size * 0.23, y: size * 0.38, width: ringSize, height: ringSize)
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = max(3, size * 0.07)
    NSColor.white.setStroke()
    ring.stroke()

    let handle = NSBezierPath()
    handle.lineWidth = max(3, size * 0.08)
    handle.lineCapStyle = .round
    handle.move(to: NSPoint(x: ringRect.maxX - size * 0.01, y: ringRect.minY + size * 0.02))
    handle.line(to: NSPoint(x: size * 0.78, y: size * 0.22))
    handle.stroke()

    // claw accents
    let clawColor = NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.33, alpha: 1)
    clawColor.setFill()
    for offset in [0.0, 1.0, 2.0] {
        let p = NSBezierPath()
        let baseX = size * (0.60 + offset * 0.07)
        let baseY = size * (0.63 - offset * 0.04)
        p.move(to: NSPoint(x: baseX, y: baseY))
        p.curve(to: NSPoint(x: baseX + size * 0.045, y: baseY + size * 0.14), controlPoint1: NSPoint(x: baseX + size * 0.015, y: baseY + size * 0.05), controlPoint2: NSPoint(x: baseX + size * 0.05, y: baseY + size * 0.1))
        p.curve(to: NSPoint(x: baseX - size * 0.005, y: baseY + size * 0.10), controlPoint1: NSPoint(x: baseX + size * 0.03, y: baseY + size * 0.16), controlPoint2: NSPoint(x: baseX + size * 0.0, y: baseY + size * 0.13))
        p.close()
        p.fill()
    }

    // subtle C letter
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.22, weight: .black),
        .foregroundColor: NSColor.white.withAlphaComponent(0.18),
        .paragraphStyle: paragraph
    ]
    let text = NSAttributedString(string: "C", attributes: attrs)
    text.draw(in: NSRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.3))

    return rep
}

for (size, name) in zip(sizes, names) {
    let rep = drawIcon(pixelSize: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        continue
    }
    try png.write(to: outDir.appendingPathComponent(name))
}
print("done")
