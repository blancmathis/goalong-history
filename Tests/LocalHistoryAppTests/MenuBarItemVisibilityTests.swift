#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp

final class MenuBarItemVisibilityTests: XCTestCase {
    private let laptop = MenuBarItemVisibility.Screen(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                                      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
                                                      topLeftArea: CGRect(x: 0, y: 1080, width: 764, height: 37),
                                                      topRightArea: CGRect(x: 964, y: 1080, width: 764, height: 37))

    func testParkedShownUnderNotchAndUnknown() {
        // The real case of 2026-11-05: macOS parked the item at the bottom left.
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 7, y: -7, width: 24, height: 24), screens: [laptop]), .parkedBySystem)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 1327, y: 1088, width: 43, height: 24), screens: [laptop]), .shown)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 850, y: 1088, width: 24, height: 24), screens: [laptop]), .underNotch)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 7, y: -7, width: 24, height: 24), screens: []), .unknown)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: .zero, screens: [laptop]), .unknown)
        // Without a notch and with an auto-hidden menu bar, the top 24 pt still count.
        let plain = MenuBarItemVisibility.Screen(frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 3000, y: 1418, width: 24, height: 22), screens: [laptop, plain]), .shown)
        XCTAssertEqual(MenuBarItemVisibility.parkedBySystem.message?.contains("Autoriser dans la barre des menus"), true)
        XCTAssertEqual(MenuBarItemVisibility.underNotch.message?.contains("encoche"), true)
        XCTAssertNil(MenuBarItemVisibility.unknown.message)
        XCTAssertEqual(MenuBarItemVisibility.settingsURL.absoluteString, "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")
        XCTAssertTrue(GoalongWorkspaceOpenPolicy.permits(MenuBarItemVisibility.settingsURL, purpose: .systemSettings))
    }

    @MainActor func testBannerNeedsTwoHiddenReadingsInARowAndUnknownShowsNothing() {
        let watch = MenuBarVisibilityWatch()
        watch.record(.parkedBySystem, frame: .zero); XCTAssertNil(watch.banner, "one reading is not enough")
        watch.record(.shown, frame: .zero); watch.record(.parkedBySystem, frame: .zero); XCTAssertNil(watch.banner)
        watch.record(.parkedBySystem, frame: .zero); XCTAssertEqual(watch.banner, .parkedBySystem)
        watch.record(.shown, frame: .zero); XCTAssertNil(watch.banner, "the banner goes once the icon is back")
        watch.record(.unknown, frame: .zero); watch.record(.unknown, frame: .zero); XCTAssertNil(watch.banner)
        watch.record(.underNotch, frame: .zero); watch.record(.underNotch, frame: .zero); XCTAssertEqual(watch.banner, .underNotch)
        watch.record(.unknown, frame: .zero); XCTAssertNil(watch.banner, ".unknown never shows anything")
    }
}
#endif
