#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

final class GoalongBrandThemeTests: XCTestCase {
    private func color(_ value: Color, _ name: NSAppearance.Name) -> NSColor {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: name)
        defer { app.appearance = previous }
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
        for appearance: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            for background in [LHTheme.pageBackground, LHTheme.cardBackground, LHTheme.sidebarBackground] {
                for foreground in [LHTheme.text, LHTheme.secondaryText, LHTheme.accent, LHTheme.success, LHTheme.warning, LHTheme.danger, LHTheme.privateTint, LHTheme.teal] {
                    XCTAssertGreaterThanOrEqual(ratio(color(foreground, appearance), color(background, appearance)), 4.5,
                        "Insufficient text contrast in \(appearance.rawValue)")
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
        for appearance: NSAppearance.Name in [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            XCTAssertGreaterThanOrEqual(ratio(color(LHTheme.strongSeparator, appearance), color(LHTheme.cardBackground, appearance)), 3)
            XCTAssertGreaterThanOrEqual(ratio(color(LHTheme.accent, appearance), color(LHTheme.selectionBackground, appearance)), 3)
        }
    }
}
#endif
