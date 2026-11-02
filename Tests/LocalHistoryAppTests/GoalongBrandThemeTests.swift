#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

final class GoalongBrandThemeTests: XCTestCase {
    /// `increased`: the Mac's Increase Contrast setting; false keeps the plain appearances whatever this Mac says.
    private func color(_ value: Color, _ name: NSAppearance.Name, increased: Bool = false) -> NSColor {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: name)
        LHTheme.increasedContrastOverride = increased
        defer { app.appearance = previous; LHTheme.increasedContrastOverride = nil }
        var resolved: NSColor!
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            resolved = NSColor(value).usingColorSpace(.sRGB)!
        }
        return resolved
    }
    private func luminance(_ color: NSColor) -> Double {
        func channel(_ c: CGFloat) -> Double {
            let value = Double(c)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
    private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x,y) + 0.05) / (min(x,y) + 0.05)
    }
    private func hex(_ color: NSColor) -> UInt32 {
        let c = color.usingColorSpace(.sRGB)!
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
    /// Every surface text or a control sits on (R281-2): page, card, sidebar, selection, hover, pressed, inset, elevated.
    private static let surfaces: [(String, Color)] = [
        ("page", LHTheme.pageBackground), ("card", LHTheme.cardBackground), ("sidebar", LHTheme.sidebarBackground),
        ("selection", LHTheme.selectionBackground), ("hover", LHTheme.hoverBackground),
        ("pressed", LHTheme.pressedBackground), ("inset", LHTheme.insetBackground),
        ("elevated", LHTheme.elevatedBackground),
    ]
    func testBrandColorsMatchWebsite() {
        let lime = color(LHTheme.accent, .darkAqua)
        XCTAssertEqual(lime.redComponent, 211.0 / 255, accuracy: 0.001)
        XCTAssertEqual(lime.greenComponent, 243.0 / 255, accuracy: 0.001)
        XCTAssertEqual(lime.blueComponent, 95.0 / 255, accuracy: 0.001)
        let olive = color(LHTheme.accent, .aqua)
        XCTAssertEqual(olive.redComponent, 75.0 / 255, accuracy: 0.001)
        let forest = color(LHTheme.sidebarBackground, .darkAqua)
        XCTAssertEqual(forest.greenComponent, 16.0 / 255, accuracy: 0.001)
    }
    func testTextAndSemanticTintsMeetNormalTextContrastAcrossAppearances() {
        let tokens: [(String, Color)] = [
            ("text", LHTheme.text), ("secondaryText", LHTheme.secondaryText), ("tertiaryText", LHTheme.tertiaryText),
            ("accent", LHTheme.accent), ("success", LHTheme.success), ("warning", LHTheme.warning),
            ("danger", LHTheme.danger), ("privateTint", LHTheme.privateTint), ("teal", LHTheme.teal),
        ]
        for increased in [false, true] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (surface, background) in Self.surfaces {
                    for (name, foreground) in tokens {
                        XCTAssertGreaterThanOrEqual(ratio(color(foreground, appearance, increased: increased),
                                                          color(background, appearance, increased: increased)), 4.5,
                            "\(name) on \(surface), \(appearance.rawValue), increased \(increased)")
                    }
                }
            }
        }
    }
    func testPrimaryActionInkContrastInEveryState() {
        for fill in [LHTheme.actionBackground, LHTheme.actionHover, LHTheme.actionPressed] {
            XCTAssertGreaterThanOrEqual(ratio(color(LHTheme.onAccent, .aqua), color(fill, .aqua)), 7)
        }
    }
    func testIncreasedContrastSeparatorsAndSelectionIndicator() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            XCTAssertGreaterThanOrEqual(ratio(color(LHTheme.strongSeparator, appearance, increased: true),
                                              color(LHTheme.cardBackground, appearance, increased: true)), 3)
            XCTAssertGreaterThanOrEqual(ratio(color(LHTheme.accent, appearance, increased: true),
                                              color(LHTheme.selectionBackground, appearance, increased: true)), 3)
        }
    }
    /// T-043 R1 (R-1, R-3, R-4, R-5, R-13), R281-2: every disabled, border and state token on every surface, light and
    /// dark, with and without the Mac's Increase Contrast; the placeholder on fields.
    func testR1TokensMeetWCAGAcrossAppearances() {
        let threeToOne: [(String, Color)] = [
            ("disabledText", LHTheme.disabledText), ("controlBorder", LHTheme.controlBorder),
            ("strongSeparator", LHTheme.strongSeparator), ("progressTint", LHTheme.progressTint),
        ]
        for increased in [false, true] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                func c(_ value: Color) -> NSColor { color(value, appearance, increased: increased) }
                let label = "\(appearance.rawValue), increased \(increased)"
                for (surface, background) in Self.surfaces {
                    for (name, foreground) in threeToOne {
                        XCTAssertGreaterThanOrEqual(ratio(c(foreground), c(background)), 3, "\(name) on \(surface), \(label)")
                    }
                    // Disabled stays clearly weaker than an active label (déc. 3).
                    XCTAssertGreaterThan(ratio(c(LHTheme.text), c(background)), ratio(c(LHTheme.disabledText), c(background)) * 1.5,
                                         "disabled vs text on \(surface), \(label)")
                }
                for background in [LHTheme.pageBackground, LHTheme.cardBackground, LHTheme.fieldBackground] {
                    XCTAssertGreaterThanOrEqual(ratio(c(LHTheme.placeholder), c(background)), 4.5, "placeholder \(label)")
                }
                // The placeholder stays clearly paler than typed text.
                let field = c(LHTheme.fieldBackground)
                XCTAssertGreaterThan(ratio(c(LHTheme.text), field), ratio(c(LHTheme.placeholder), field) * 1.5)
                // Off switch: the light knob is drawn by its edge; the dark knob (no edge) stands on its own.
                let isDark = appearance == .darkAqua
                let knob = isDark ? LHTheme.switchKnob : LHTheme.switchKnobEdge
                XCTAssertGreaterThanOrEqual(ratio(c(knob), c(LHTheme.switchTrack)), 3, "knob \(label)")
            }
        }
    }
    /// R281-1: the high* values reach the app. Under Increase Contrast SwiftUI hands the colour a plain Aqua or Dark
    /// Aqua appearance (and `NSAppearance(named: .accessibilityHighContrastAqua)` is itself plain Aqua on macOS 13+),
    /// so the Mac's setting picks them.
    func testIncreasedContrastResolvesHighTokens() {
        let cases: [(String, Color, light: UInt32, dark: UInt32, highLight: UInt32, highDark: UInt32)] = [
            ("text", LHTheme.text, 0x0D100E, 0xF2F6EF, 0x000000, 0xFFFFFF),
            ("secondaryText", LHTheme.secondaryText, 0x566252, 0xAEBBB1, 0x35422F, 0xCCD6CE),
            ("tertiaryText", LHTheme.tertiaryText, 0x5A6355, 0x96A59B, 0x4C5747, 0xB1BEB4),
            ("disabledText", LHTheme.disabledText, 0x757E70, 0x74857A, 0x5E6859, 0x9AAA9E),
            ("controlBorder", LHTheme.controlBorder, 0x777E6B, 0x76887B, 0x666E5C, 0x8AA08E),
            ("danger", LHTheme.danger, 0xA63D32, 0xFFADA0, 0x8E2A22, 0xFFC2B8),
        ]
        for (name, token, light, dark, highLight, highDark) in cases {
            XCTAssertEqual(hex(color(token, .aqua)), light, name)
            XCTAssertEqual(hex(color(token, .darkAqua)), dark, name)
            XCTAssertEqual(hex(color(token, .aqua, increased: true)), highLight, "\(name), light, Increase Contrast")
            XCTAssertEqual(hex(color(token, .darkAqua, increased: true)), highDark, "\(name), dark, Increase Contrast")
        }
        // Through SwiftUI, as the app draws it: a window never shown, filled with the ink token.
        for (appearance, plain, high) in [(NSAppearance.Name.aqua, UInt32(0x0D100E), UInt32(0x000000)),
                                          (.darkAqua, 0xF2F6EF, 0xFFFFFF)] {
            for increased in [false, true] {
                LHTheme.increasedContrastOverride = increased
                defer { LHTheme.increasedContrastOverride = nil }
                let host = NSHostingView(rootView: Rectangle().fill(LHTheme.text).frame(width: 8, height: 8))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 8, height: 8), styleMask: .borderless,
                                      backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                window.contentView = nil
                window.close()
                // The capture's colour space moves a channel by a few steps; black and white stay exact.
                let pixel = hex(rep.colorAt(x: 4, y: 4)!), expected = increased ? high : plain
                let distance = [16, 8, 0].map { abs(Int(pixel >> $0 & 255) - Int(expected >> $0 & 255)) }.max()!
                XCTAssertLessThanOrEqual(distance, 4, "SwiftUI ink, \(appearance.rawValue), increased \(increased)")
                XCTAssertNotEqual(pixel, increased ? plain : high)
            }
        }
    }
    /// R281-10: an empty title never stops the app, even in debug; the pill and the action say something.
    func testEmptyTitlesFallBackInsteadOfCrashing() {
        XCTAssertEqual(StatusPill(title: " ", symbol: "circle", tint: LHTheme.secondaryText).title, StatusPill.fallbackTitle)
        XCTAssertEqual(StatusPill(title: "Actif", symbol: "circle", tint: LHTheme.secondaryText).title, "Actif")
        XCTAssertEqual(GoalongEmptyStateAction(title: "", action: {}).title, GoalongEmptyStateAction.fallbackTitle)
    }
    func testLockedSwitchSpeaksItsPosition() {
        XCTAssertEqual(GoalongSwitch.lockedAccessibilityValue(isOn: true), "Activé, verrouillé")
        XCTAssertEqual(GoalongSwitch.lockedAccessibilityValue(isOn: false), "Désactivé, verrouillé")
    }
}
#endif
