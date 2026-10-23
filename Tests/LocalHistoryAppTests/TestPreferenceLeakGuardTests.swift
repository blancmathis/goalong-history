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
        GoalongHeadlessCleanLeakedDefaultSuite(suite)
        // cfprefsd writes asynchronously: a late rewrite must not bring the file back.
        XCTAssertTrue(waitForFile(path, exists: false), "suite plist survived the cleanup")
    }

    func testCleanupNeverRemovesASuiteWithoutAUUIDInItsName() throws {
        let suite = "goalong-leak-guard-real-domain-\(UInt32.random(in: 0...UInt32.max))"
        let path = plistURL(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            // cfprefsd may still write the domain after a first removal: remove until it stays away.
            for _ in 0..<5 { try? FileManager.default.removeItem(at: path); RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
        defaults.set("value", forKey: "key")
        defaults.synchronize()
        XCTAssertTrue(waitForFile(path, exists: true), "the suite plist never reached the disk")
        GoalongHeadlessCleanLeakedDefaultSuite(suite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "a name that is not UUID-unique must never be deleted")
    }

    /// Returns as soon as the file state matches, so a fast cfprefsd costs milliseconds; 15 s only bounds a stuck one.
    private func waitForFile(_ url: URL, exists: Bool, timeout: TimeInterval = 15) -> Bool {
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
        GoalongHeadlessCleanLeakedDefaultSuite(suite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "a pre-existing plist must stay")
    }

    func testCleaningOneSuiteLeavesTheOtherTrackedSuitesAlone() throws {
        let first = "goalong-leak-guard-first-\(UUID().uuidString)"
        let second = "goalong-leak-guard-second-\(UUID().uuidString)"
        let firstPath = plistURL(first), secondPath = plistURL(second)
        let one = try XCTUnwrap(UserDefaults(suiteName: first)), two = try XCTUnwrap(UserDefaults(suiteName: second))
        one.set("1", forKey: "key"); two.set("2", forKey: "key")
        one.synchronize(); two.synchronize()
        XCTAssertTrue(waitForFile(firstPath, exists: true) && waitForFile(secondPath, exists: true), "the suite plists never reached the disk")
        GoalongHeadlessCleanLeakedDefaultSuite(first)
        XCTAssertTrue(waitForFile(firstPath, exists: false), "the cleaned suite survived")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath.path), "cleaning one suite erased another test's tracked suite")
        GoalongHeadlessCleanLeakedDefaultSuite(second)
        XCTAssertTrue(waitForFile(secondPath, exists: false))
    }
}
#endif
