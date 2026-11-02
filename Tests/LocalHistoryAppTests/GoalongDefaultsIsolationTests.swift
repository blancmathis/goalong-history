import Foundation
import XCTest
import GoalongHeadlessTestSupport
@testable import LocalHistoryApp
import AppleScreenTime

/// T-043 T1 (R282-8): no test and no gallery picture reads or writes this Mac's real preferences. Under XCTest the
/// standard domain is one throwaway suite, shared by `GoalongDefaults.standard`, `UserDefaults.standard` (hook) and
/// the stores' default arguments. Every check reads a random key written only into that suite: nothing here touches
/// the owner's domain, even on code without the isolation (the first `XCTUnwrap` stops there).
final class GoalongDefaultsIsolationTests: XCTestCase {
    private static let prefix = "goalong-tests-defaults-"

    /// The account's real preference folder (cfprefsd ignores CFFIXED_USER_HOME).
    private var realPreferences: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    private func isolatedSuite() throws -> (name: String, suite: UserDefaults) {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["GOALONG_TEST_DEFAULTS_SUITE"]
            ?? getenv("GOALONG_TEST_DEFAULTS_SUITE").map { String(cString: $0) },
                                 "the test process has no throwaway preference suite: it would use the machine's")
        let file = (name as NSString).lastPathComponent
        XCTAssertTrue(file.hasPrefix("\(Self.prefix)\(getpid())-"), name)
        XCTAssertNotNil(UUID(uuidString: String(file.dropFirst("\(Self.prefix)\(getpid())-".count))), name)
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testStandardPreferencesAreTheThrowawaySuite() throws {
        let (_, suite) = try isolatedSuite()
        let key = "t043.t1.\(UUID().uuidString)"
        suite.set("isolated", forKey: key)
        defer { suite.removeObject(forKey: key) }
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "isolated")
        XCTAssertEqual(GoalongDefaults.standard.string(forKey: key), "isolated")
    }

    func testStoresWithDefaultArgumentsReadTheThrowawaySuite() throws {
        let (_, suite) = try isolatedSuite()
        let key = GoalongDeveloperPreferences.enabledKey
        let before = suite.object(forKey: key)
        defer { suite.set(before, forKey: key) }
        suite.set(true, forKey: key)
        XCTAssertTrue(GoalongDeveloperPreferences.isEnabled())
        suite.set(false, forKey: key)
        XCTAssertFalse(GoalongDeveloperPreferences.isEnabled())
    }

    /// R-286 F1: cfprefsd writes a suite's plist seconds after the process exits, so no cleanup at exit can win
    /// that race in ~/Library/Preferences. The suite is a path inside the throwaway HOME instead: its file never
    /// reaches the account's preference folder and goes with that HOME.
    func testThrowawaySuiteFileStaysInTheThrowawayHome() throws {
        let (name, suite) = try isolatedSuite()
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["GOALONG_TEST_HOME"]
            ?? getenv("GOALONG_TEST_HOME").map { String(cString: $0) })
        XCTAssertTrue(name.hasPrefix(home + "/"), "\(name) is not inside the throwaway HOME \(home)")
        let key = "t043.t1.f1.\(UUID().uuidString)"
        suite.set(1, forKey: key)
        defer { suite.removeObject(forKey: key) }
        XCTAssertTrue(suite.synchronize())
        let leaked = realPreferences.appendingPathComponent((name as NSString).lastPathComponent + ".plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaked.path), leaked.path)
    }

    /// R-286 F1: files left by a killed run (SIGKILL, timeout) go at the next start. A live process's file stays.
    func testSweepRemovesOnlyOrphanedTestPreferences() throws {
        let folder = realPreferences
        func make(_ name: String, age: TimeInterval = 0) throws -> URL {
            let url = folder.appendingPathComponent(name + ".plist")
            try Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>"#.utf8).write(to: url)
            if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path) }
            return url
        }
        // 99999 is above the macOS pid limit (99998): never a live process.
        let dead = try make("\(Self.prefix)99999-\(UUID().uuidString)")
        let legacy = try make("\(Self.prefix)\(UUID().uuidString)", age: 3600)
        let recentLegacy = try make("\(Self.prefix)\(UUID().uuidString)")
        let live = try make("\(Self.prefix)\(getpid())-\(UUID().uuidString)")
        // Tour 3: names are parsed strictly. A recent legacy UUID whose first block is all digits is not `<pid>-…`
        // (here a dead "pid" 12345678); a tagged `<pid>-gallery-<UUID>` of a dead process is.
        let digitLegacy = try make("\(Self.prefix)12345678-\(UUID().uuidString.dropFirst(9))")
        let deadGallery = try make("\(Self.prefix)99999-gallery-\(UUID().uuidString)")
        defer { for url in [dead, legacy, recentLegacy, live, digitLegacy, deadGallery] { try? FileManager.default.removeItem(at: url) } }
        XCTAssertGreaterThanOrEqual(GoalongHeadlessSweepOrphanedTestPreferences(), 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: digitLegacy.path), "a recent legacy UUID was read as a dead pid")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deadGallery.path), "a dead process's gallery file stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path), "a dead process's file stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "an old UUID-only file stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentLegacy.path), "a recent UUID-only file may be live")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live process's file was removed")
    }

    /// Tour 3: a suite opened with a bare name (as the 83 test call sites do) never reaches the account's
    /// ~/Library/Preferences, not even after `removePersistentDomain` and cfprefsd's late write: its file lives only in
    /// the throwaway HOME. The name is `goalong-tests-defaults-<pid>-bare-<UUID>` so that, on code without the
    /// isolation, the next run's sweep removes the file this red test leaks.
    func testBareSuiteNameNeverReachesTheRealPreferences() throws {
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["GOALONG_TEST_HOME"]
            ?? getenv("GOALONG_TEST_HOME").map { String(cString: $0) })
        let name = "\(Self.prefix)\(getpid())-bare-\(UUID().uuidString)"
        let real = realPreferences.appendingPathComponent(name + ".plist")
        let isolated = URL(fileURLWithPath: home).appendingPathComponent("goalong-test-preferences/\(name).plist")
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        suite.set("bare", forKey: "t043.t1.tour3")
        XCTAssertTrue(suite.synchronize())
        XCTAssertEqual(UserDefaults(suiteName: name)?.string(forKey: "t043.t1.tour3"), "bare")
        XCTAssertEqual(suite.persistentDomain(forName: name)?["t043.t1.tour3"] as? String, "bare")
        let written = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: isolated.path), Date() < written {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated.path), "no plist in the throwaway HOME: \(isolated.path)")
        suite.removePersistentDomain(forName: name)
        XCTAssertNil(suite.persistentDomain(forName: name)?["t043.t1.tour3"])
        // cfprefsd writes seconds later: watch the real folder for 15 s.
        let deadline = Date().addingTimeInterval(15)
        repeat {
            XCTAssertFalse(FileManager.default.fileExists(atPath: real.path), "leaked into the real Preferences: \(real.path)")
            if FileManager.default.fileExists(atPath: real.path) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
    }

    /// R-286 F2: in a gallery session a `GoalongDefaults.standard` read is counted (the picture becomes `.leaky`)
    /// and lands in that session's fresh suite, so no picture sees what an earlier one wrote.
    func testGallerySessionCountsGoalongDefaultsAndStartsEmpty() throws {
        try XCTSkipUnless(GoalongGalleryGuardsInstalled(), "gallery guards are off (GOALONG_TESTS_VISIBLE=1)")
        let (_, suite) = try isolatedSuite()
        let key = "t043.t1.f2.\(UUID().uuidString)"
        GoalongGalleryGuardsBegin()
        GoalongDefaults.standard.set("first picture", forKey: key)
        let first = GoalongGalleryGuardsTake()
        XCTAssertGreaterThanOrEqual(first["standardDefaults"] as? Int ?? 0, 1, "the gallery did not see the read")
        XCTAssertNil(suite.object(forKey: key), "a gallery write reached the process-wide suite")
        GoalongGalleryGuardsBegin()
        let leftover = GoalongDefaults.standard.object(forKey: key)
        _ = GoalongGalleryGuardsTake()
        XCTAssertNil(leftover, "the second picture read the first one's write")
    }
}
