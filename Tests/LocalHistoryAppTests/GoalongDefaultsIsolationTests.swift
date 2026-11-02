import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-043 T1 (R282-8): no test and no gallery picture reads or writes this Mac's real preferences. Under XCTest the
/// standard domain is one throwaway suite, shared by `GoalongDefaults.standard`, `UserDefaults.standard` (hook) and
/// the stores' default arguments. Every check reads a random key written only into that suite: nothing here touches
/// the owner's domain, even on code without the isolation (the first `XCTUnwrap` stops there).
final class GoalongDefaultsIsolationTests: XCTestCase {
    private func isolatedSuite() throws -> (name: String, suite: UserDefaults) {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["GOALONG_TEST_DEFAULTS_SUITE"]
            ?? getenv("GOALONG_TEST_DEFAULTS_SUITE").map { String(cString: $0) },
                                 "the test process has no throwaway preference suite: it would use the machine's")
        XCTAssertTrue(name.hasPrefix("goalong-tests-defaults-"), name)
        XCTAssertNotNil(UUID(uuidString: String(name.dropFirst("goalong-tests-defaults-".count))),
                        "a UUID name: the headless hook deletes the plist at exit")
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testStandardPreferencesAreTheThrowawaySuite() throws {
        let (_, suite) = try isolatedSuite()
        let key = "t043.t1.\(UUID().uuidString)"
        suite.set("isolated", forKey: key)
        defer { suite.removeObject(forKey: key) }
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "isolated")
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
}
