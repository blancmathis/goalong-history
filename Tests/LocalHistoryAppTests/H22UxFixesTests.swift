#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

final class H22UxFixesTests: XCTestCase {
    func testDeviceOnlyUseUnderExclusionIsNotRecordedButMarksTheDayPartial() {
        let free = GoalongCallPresenceMonitor.deviceOnlyUse(hasExclusions: false, hasAllowList: false)
        XCTAssertTrue(free.record); XCTAssertFalse(free.partial)
        for (exclusions, allow) in [(true, false), (false, true), (true, true)] {
            let use = GoalongCallPresenceMonitor.deviceOnlyUse(hasExclusions: exclusions, hasAllowList: allow)
            XCTAssertFalse(use.record, "exclusions \(exclusions) allow \(allow)")
            XCTAssertTrue(use.partial, "exclusions \(exclusions) allow \(allow)")
        }
    }
    func testQuickPauseOffersNoDurationWhileJevIsOff() {
        XCTAssertEqual(JevQuickPauseControl.menuItems(enabled: false, breakRunning: true).durations, [])
        XCTAssertTrue(JevQuickPauseControl.menuItems(enabled: false, breakRunning: true).resume)
        XCTAssertEqual(JevQuickPauseControl.menuItems(enabled: true, breakRunning: false).durations, [5, 10, 15, 30])
        XCTAssertFalse(JevQuickPauseControl.menuItems(enabled: true, breakRunning: false).resume)
    }
    @MainActor func testUnreadableBreakFileHasOneName() throws {
        let root = URL(fileURLWithPath: "/private/tmp/jev-h22-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JevLocalFiles.write(Data("not json".utf8), name: "break.json", root: root)
        let defaults = UserDefaults(suiteName: "h22-" + UUID().uuidString)!
        let monitor = JevMonitor(scopePreferences: JevMonitoringPreferences(defaults: defaults),
                                 consents: GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("c.json")),
                                 sessionProvider: { nil }, inbox: JevIngress(notificationCenter: NotificationCenter()), localRoot: root)
        XCTAssertTrue(monitor.breakStorageInvalid)
        XCTAssertEqual(monitor.error, JevMonitor.unreadableBreakNotice)
    }
}
#endif
