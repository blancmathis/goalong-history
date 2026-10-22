#if os(macOS)
import Foundation
import GoalongHeadlessTestSupport
import XCTest

/// A bare `swift test` used to leave one `<suite>.plist` per `UserDefaults(suiteName:)` in the
/// real ~/Library/Preferences. The test support hook now removes the plists the run created.
final class TestPreferenceLeakGuardTests: XCTestCase {
    private func plistURL(_ suite: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences/\(suite).plist")
    }

    func testCleanupRemovesTheSuitePlistThisRunCreated() throws {
        let suite = "goalong-leak-guard-\(UUID().uuidString)"
        let path = plistURL(suite)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("value", forKey: "key")
        defaults.synchronize()
        GoalongHeadlessCleanLeakedDefaultSuites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "suite plist survived the cleanup")
    }

    func testCleanupNeverTouchesAPlistThatExistedBeforeTheSuiteWasOpened() throws {
        let suite = "goalong-leak-guard-existing-\(UUID().uuidString)"
        let path = plistURL(suite)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["owner": "kept"], format: .xml, options: 0).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        _ = UserDefaults(suiteName: suite)
        GoalongHeadlessCleanLeakedDefaultSuites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "a pre-existing plist must stay")
    }
}
#endif
