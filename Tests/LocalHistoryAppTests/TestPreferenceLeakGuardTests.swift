#if os(macOS)
import Foundation
import GoalongHeadlessTestSupport
import XCTest

/// A bare `swift test` used to leave one `<suite>.plist` per `UserDefaults(suiteName:)` in the
/// real ~/Library/Preferences. The test support hook now removes the plists the run created.
final class TestPreferenceLeakGuardTests: XCTestCase {
    private func plistURL(_ suite: String) -> URL {
        URL(fileURLWithPath: GoalongHeadlessSuitePlistPath(suite) ?? "/nonexistent/\(suite).plist")
    }

    func testCleanupRemovesTheSuitePlistThisRunCreated() throws {
        let suite = "goalong-leak-guard-\(UUID().uuidString)"
        let path = plistURL(suite)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("value", forKey: "key")
        defaults.synchronize()
        // The proof is only worth something if the file really existed before the cleanup.
        XCTAssertTrue(waitForFile(path, exists: true), "the suite plist never reached the disk: the test proves nothing")
        GoalongHeadlessCleanLeakedDefaultSuites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "suite plist survived the cleanup")
    }

    func testCleanupNeverRemovesASuiteWithoutAUUIDInItsName() throws {
        let suite = "goalong-leak-guard-real-domain-\(UInt32.random(in: 0...UInt32.max))"
        let path = plistURL(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: path) }
        defaults.set("value", forKey: "key")
        defaults.synchronize()
        XCTAssertTrue(waitForFile(path, exists: true), "the suite plist never reached the disk")
        GoalongHeadlessCleanLeakedDefaultSuites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "a name that is not UUID-unique must never be deleted")
    }

    private func waitForFile(_ url: URL, exists: Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) == exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return FileManager.default.fileExists(atPath: url.path) == exists
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
