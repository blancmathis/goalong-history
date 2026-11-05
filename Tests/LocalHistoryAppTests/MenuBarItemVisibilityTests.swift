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

    /// Review B1 point 1: an auto-hidden bar or a full-screen app moves the item to the top edge or above
    /// it. That is not « masquée ». Only a frame far from every top is parked.
    func testAutoHiddenBarAndFullScreenAreNotParked() {
        let autoHidden = MenuBarItemVisibility.Screen(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        // Bar hidden: the item window sits just above the screen, or flush with its top edge.
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 1327, y: 1117, width: 43, height: 24), screens: [autoHidden]), .shown)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 1327, y: 1141, width: 43, height: 24), screens: [autoHidden]), .shown)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 1327, y: 1094, width: 43, height: 22), screens: [autoHidden]), .shown)
        // Full screen on the notched laptop: visibleFrame covers the whole screen, the item goes above.
        let fullScreen = MenuBarItemVisibility.Screen(frame: laptop.frame, visibleFrame: laptop.frame,
                                                      topLeftArea: laptop.topLeftArea, topRightArea: laptop.topRightArea)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 1327, y: 1117, width: 43, height: 37), screens: [fullScreen]), .shown)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 850, y: 1117, width: 24, height: 37), screens: [fullScreen]), .shown,
                       "above the notch while the bar is hidden: not a notch case")
        // Still parked: far from the top (bottom left), and next to the screen rather than above it.
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 7, y: -7, width: 24, height: 24), screens: [fullScreen]), .parkedBySystem)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: 7, y: 500, width: 24, height: 24), screens: [autoHidden]), .parkedBySystem)
        XCTAssertEqual(MenuBarItemVisibility.state(itemFrame: CGRect(x: -400, y: 1117, width: 24, height: 24), screens: [autoHidden]), .parkedBySystem)
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

    /// T-048 C1: each reading names the item, so the log tells which Control Centre key was parked.
    func testLogLineNamesTheItem() {
        XCTAssertEqual(MenuBarVisibilityWatch.logLine(.parkedBySystem, frame: CGRect(x: 0, y: -17, width: 38, height: 22), item: "goalong-status"),
                       "state=parkedBySystem frame=0,-17,38,22 item=goalong-status")
        XCTAssertEqual(MenuBarVisibilityWatch.logLine(.shown, frame: .zero, item: ""), "state=shown frame=0,0,0,0 item=?")
    }
}
#endif
