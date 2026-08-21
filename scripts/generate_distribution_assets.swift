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
    guard let tiff = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: tiff),
        let data = representation.representation(using: .png, properties: [:])
    else {
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

private func makeAppIcon() -> NSImage {
    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let outer = NSRect(x: 90, y: 100, width: 844, height: 844)
    let shadow = NSShadow()
    shadow.shadowColor = color(0.03, 0.06, 0.15, 0.52)
    shadow.shadowBlurRadius = 46
    shadow.shadowOffset = NSSize(width: 0, height: -20)
    shadow.set()

    let outerPath = NSBezierPath(roundedRect: outer, xRadius: 220, yRadius: 220)
    NSGradient(
        colors: [
            color(0.15, 0.39, 0.96),
            color(0.39, 0.25, 0.90),
        ]
    )?.draw(in: outerPath, angle: -35)

    NSGraphicsContext.current?.saveGraphicsState()
    NSShadow().set()
    color(1, 1, 1, 0.38).setStroke()
    outerPath.lineWidth = 5
    outerPath.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    let clockRect = NSRect(x: 238, y: 278, width: 490, height: 490)
    color(0.035, 0.075, 0.19, 0.95).setFill()
    let clock = NSBezierPath(ovalIn: clockRect)
    clock.fill()
    color(1, 1, 1, 0.96).setStroke()
    clock.lineWidth = 24
    clock.stroke()

    let center = NSPoint(x: clockRect.midX, y: clockRect.midY)
    let radius: CGFloat = 210
    for index in 0..<12 {
        let angle = CGFloat(index) * .pi / 6
        let outerPoint = NSPoint(
            x: center.x + sin(angle) * radius,
            y: center.y + cos(angle) * radius
        )
        let inset: CGFloat = index % 3 == 0 ? 38 : 26
        let innerPoint = NSPoint(
            x: center.x + sin(angle) * (radius - inset),
            y: center.y + cos(angle) * (radius - inset)
        )
        let tick = NSBezierPath()
        tick.move(to: innerPoint)
        tick.line(to: outerPoint)
        tick.lineWidth = index % 3 == 0 ? 12 : 7
        tick.lineCapStyle = .round
        color(1, 1, 1, index % 3 == 0 ? 0.92 : 0.58).setStroke()
        tick.stroke()
    }

    let hands = NSBezierPath()
    hands.move(to: center)
    hands.line(to: NSPoint(x: center.x, y: center.y + 136))
    hands.move(to: center)
    hands.line(to: NSPoint(x: center.x + 114, y: center.y - 62))
    hands.lineWidth = 25
    hands.lineCapStyle = .round
    color(1, 1, 1, 0.98).setStroke()
    hands.stroke()
    color(1, 1, 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 24, y: center.y - 24, width: 48, height: 48)).fill()

    let badgeCenter = NSPoint(x: 710, y: 314)
    let badgeOuter = NSRect(x: badgeCenter.x - 116, y: badgeCenter.y - 116, width: 232, height: 232)
    color(0.97, 0.98, 1).setFill()
    NSBezierPath(ovalIn: badgeOuter).fill()
    let badgeInner = badgeOuter.insetBy(dx: 24, dy: 24)
    color(0.13, 0.72, 0.45).setFill()
    NSBezierPath(ovalIn: badgeInner).fill()

    let check = NSBezierPath()
    check.move(to: NSPoint(x: badgeCenter.x - 50, y: badgeCenter.y + 2))
    check.line(to: NSPoint(x: badgeCenter.x - 12, y: badgeCenter.y - 40))
    check.line(to: NSPoint(x: badgeCenter.x + 62, y: badgeCenter.y + 45))
    check.lineWidth = 24
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor.white.setStroke()
    check.stroke()

    return image
}

private func makeDMGBackground() -> NSImage {
    let width: CGFloat = 1440
    let height: CGFloat = 880
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGradient(colors: [color(0.97, 0.975, 0.99), color(0.94, 0.95, 0.98)])?
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    color(0.20, 0.43, 0.95).setFill()
    NSBezierPath(roundedRect: NSRect(x: 108, y: 738, width: 68, height: 68), xRadius: 18, yRadius: 18).fill()

    let miniClock = NSBezierPath(ovalIn: NSRect(x: 123, y: 753, width: 38, height: 38))
    NSColor.white.setStroke()
    miniClock.lineWidth = 5
    miniClock.stroke()
    let miniHands = NSBezierPath()
    miniHands.move(to: NSPoint(x: 142, y: 772))
    miniHands.line(to: NSPoint(x: 142, y: 783))
    miniHands.move(to: NSPoint(x: 142, y: 772))
    miniHands.line(to: NSPoint(x: 152, y: 767))
    miniHands.lineWidth = 4
    miniHands.lineCapStyle = .round
    miniHands.stroke()

    NSString(string: "Goalong History").draw(
        at: NSPoint(x: 198, y: 748),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 58, weight: .bold),
            .foregroundColor: color(0.08, 0.11, 0.20),
        ]
    )
    NSString(string: "Private, verifiable activity for your Mac").draw(
        at: NSPoint(x: 200, y: 704),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .regular),
            .foregroundColor: color(0.38, 0.41, 0.50),
        ]
    )

    drawCenteredText(
        "Drag Goalong History to Applications",
        y: 582,
        width: width,
        font: NSFont.systemFont(ofSize: 26, weight: .medium),
        foreground: color(0.22, 0.25, 0.34)
    )

    for centerX in [CGFloat(360), CGFloat(1080)] {
        color(1, 1, 1, 0.82).setFill()
        let circle = NSBezierPath(ovalIn: NSRect(x: centerX - 128, y: 279, width: 256, height: 256))
        circle.fill()
        color(0.13, 0.24, 0.52, 0.18).setStroke()
        circle.lineWidth = 3
        circle.stroke()
    }

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 555, y: 407))
    arrow.line(to: NSPoint(x: 865, y: 407))
    arrow.lineWidth = 8
    arrow.lineCapStyle = .round
    color(0.28, 0.43, 0.84, 0.75).setStroke()
    arrow.stroke()
    color(0.28, 0.43, 0.84, 0.85).setFill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 865, y: 407))
    head.line(to: NSPoint(x: 821, y: 436))
    head.line(to: NSPoint(x: 821, y: 378))
    head.close()
    head.fill()

    let badges = [
        "✓  Signed by Goalong",
        "✓  Notarized by Apple",
        "✓  Universal Intel + Apple Silicon",
    ]
    let badgeFont = NSFont.systemFont(ofSize: 19, weight: .semibold)
    let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: badgeFont,
        .foregroundColor: color(0.25, 0.29, 0.40),
    ]
    let widths = badges.map { NSString(string: $0).size(withAttributes: badgeAttributes).width + 44 }
    let gap: CGFloat = 20
    var badgeX = (width - widths.reduce(0, +) - gap * CGFloat(badges.count - 1)) / 2
    for (index, title) in badges.enumerated() {
        let rect = NSRect(x: badgeX, y: 122, width: widths[index], height: 54)
        color(1, 1, 1, 0.86).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 27, yRadius: 27)
        path.fill()
        color(0.13, 0.24, 0.52, 0.14).setStroke()
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
        foreground: color(0.45, 0.47, 0.55)
    )

    return image
}

let arguments = CommandLine.arguments
let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Distribution", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try savePNG(makeAppIcon(), to: outputDirectory.appendingPathComponent("AppIcon.png"))
try savePNG(makeDMGBackground(), to: outputDirectory.appendingPathComponent("DMGBackground.png"))
print("Generated distribution assets in \(outputDirectory.path)")
