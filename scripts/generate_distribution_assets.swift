#!/usr/bin/env xcrun swift

import AppKit
import Foundation

private enum AssetError: Error {
    case pngEncodingFailed
}

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

private func savePNG(_ image: NSImage, to url: URL) throws {
    // Explicit pixels keep release assets deterministic on Retina and non-Retina hosts.
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw AssetError.pngEncodingFailed
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw AssetError.pngEncodingFailed
    }
    try data.write(to: url, options: .atomic)
}

private func drawCenteredText(
    _ text: String,
    y: CGFloat,
    width: CGFloat,
    font: NSFont,
    foreground: NSColor
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: foreground,
        .paragraphStyle: paragraph,
    ]
    NSString(string: text).draw(in: NSRect(x: 0, y: y, width: width, height: font.pointSize * 1.5), withAttributes: attributes)
}

private func brandColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// Exact existing GoalongMark geometry, shared with the website.
private func drawGoalongMark(in rect: NSRect) {
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: rect.minX + x * rect.width / 26, y: rect.maxY - y * rect.height / 18)
    }
    let p = NSBezierPath()
    p.move(to: point(2.08, 9))
    p.curve(to: point(13.26, 9), controlPoint1: point(2.08, 1.8), controlPoint2: point(9.62, 1.44))
    p.curve(to: point(23.92, 9), controlPoint1: point(16.64, 16.56), controlPoint2: point(23.92, 16.2))
    p.curve(to: point(13.26, 9), controlPoint1: point(23.92, 1.8), controlPoint2: point(16.64, 1.44))
    p.curve(to: point(2.08, 9), controlPoint1: point(9.62, 16.56), controlPoint2: point(2.08, 16.2))
    p.move(to: point(2.08, 9))
    p.line(to: point(10.14, 9))
    p.curve(to: point(12.74, 10.62), controlPoint1: point(11.44, 9), controlPoint2: point(12.74, 9.72))
    p.lineWidth = 2.1 * rect.width / 26
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    brandColor(0xD3F35F).setStroke()
    p.stroke()
}

private func makeAppIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    defer { image.unlockFocus() }
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let tile = NSBezierPath(roundedRect: NSRect(x: 90, y: 100, width: 844, height: 844), xRadius: 220, yRadius: 220)
    let shadow = NSShadow()
    shadow.shadowColor = brandColor(0x0B100D, 0.3)
    shadow.shadowBlurRadius = 32
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSGradient(colors: [brandColor(0x1B251E), brandColor(0x0B100D)])?.draw(in: tile, angle: -35)
    NSShadow().set()
    brandColor(0x506455, 0.55).setStroke()
    tile.lineWidth = 3
    tile.stroke()
    drawGoalongMark(in: NSRect(x: 200, y: 306, width: 624, height: 432))
    return image
}

private func makeDMGBackground() -> NSImage {
    let width: CGFloat = 1440
    let height: CGFloat = 880
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGradient(colors: [brandColor(0x101712), brandColor(0x0B100D)])?
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    brandColor(0x1B251E).setFill()
    NSBezierPath(roundedRect: NSRect(x: 108, y: 738, width: 68, height: 68), xRadius: 18, yRadius: 18).fill()

    drawGoalongMark(in: NSRect(x: 119, y: 756, width: 46, height: 32))

    NSString(string: "Goalong History").draw(
        at: NSPoint(x: 198, y: 748),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 58, weight: .bold),
            .foregroundColor: brandColor(0xF2F6EF),
        ]
    )
    NSString(string: "Private, verifiable activity for your Mac").draw(
        at: NSPoint(x: 200, y: 704),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .regular),
            .foregroundColor: brandColor(0xA0B0A4),
        ]
    )

    drawCenteredText(
        "Drag Goalong History to Applications",
        y: 582,
        width: width,
        font: NSFont.systemFont(ofSize: 26, weight: .medium),
        foreground: brandColor(0xC0CCC2)
    )

    for centerX in [CGFloat(360), CGFloat(1080)] {
        brandColor(0x131B16).setFill()
        let circle = NSBezierPath(ovalIn: NSRect(x: centerX - 128, y: 279, width: 256, height: 256))
        circle.fill()
        brandColor(0x2D3C31).setStroke()
        circle.lineWidth = 3
        circle.stroke()
    }

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 555, y: 407))
    arrow.line(to: NSPoint(x: 865, y: 407))
    arrow.lineWidth = 8
    arrow.lineCapStyle = .round
    brandColor(0xD3F35F).setStroke()
    arrow.stroke()
    brandColor(0xD3F35F).setFill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 865, y: 407))
    head.line(to: NSPoint(x: 821, y: 436))
    head.line(to: NSPoint(x: 821, y: 378))
    head.close()
    head.fill()

    let badges = [
        "Local activity history",
        "You choose what to share",
        "Native macOS workspace",
    ]
    let badgeFont = NSFont.systemFont(ofSize: 19, weight: .semibold)
    let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: badgeFont,
        .foregroundColor: brandColor(0xC0CCC2),
    ]
    let widths = badges.map { NSString(string: $0).size(withAttributes: badgeAttributes).width + 44 }
    let gap: CGFloat = 20
    var badgeX = (width - widths.reduce(0, +) - gap * CGFloat(badges.count - 1)) / 2
    for (index, title) in badges.enumerated() {
        let rect = NSRect(x: badgeX, y: 122, width: widths[index], height: 54)
        brandColor(0x1B251E).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 27, yRadius: 27)
        path.fill()
        brandColor(0x2D3C31).setStroke()
        path.lineWidth = 2
        path.stroke()
        NSString(string: title).draw(at: NSPoint(x: badgeX + 22, y: 138), withAttributes: badgeAttributes)
        badgeX += widths[index] + gap
    }

    drawCenteredText(
        "Open Goalong History after copying it — the setup assistant will guide every permission step.",
        y: 54,
        width: width,
        font: NSFont.systemFont(ofSize: 21, weight: .regular),
        foreground: brandColor(0xA0B0A4)
    )

    return image
}

let arguments = CommandLine.arguments
let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Distribution", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try savePNG(makeAppIcon(), to: outputDirectory.appendingPathComponent("AppIcon.png"))
try savePNG(makeDMGBackground(), to: outputDirectory.appendingPathComponent("DMGBackground.png"))
print("Generated distribution assets in \(outputDirectory.path)")
