import XCTest
import Foundation
@testable import LocalHistoryCore

final class GoalongSimplePrivacyTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-simple-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testMissingPolicyHasStableRevisionAndDoesNotChangeExistingConfig() throws {
        let root = try temporaryRoot()
        let first = GoalongPrivacyPolicy.load(in: root), second = GoalongPrivacyPolicy.load(in: root)
        XCTAssertEqual(first, second); XCTAssertEqual(first.revision, "none")
        XCTAssertFalse(first.hasExclusions)
        let config = RecorderConfig.default
        XCTAssertEqual(first.applying(to: config).excludedBundleIdentifiers.sorted(), config.excludedBundleIdentifiers.sorted())
    }
    func testPolicyPersistsAndInvalidFilesFailClosed() throws {
        let root = try temporaryRoot()
        var policy = GoalongPrivacyPolicy()
        policy.applications = ["com.test.private": "Private App"]
        policy.domains = ["private.example"]
        policy.effectiveFrom = Date()
        try policy.save(in: root)
        XCTAssertEqual(GoalongPrivacyPolicy.load(in: root), policy)
        let attrs = try FileManager.default.attributesOfItem(atPath: GoalongPrivacyPolicy.file(in: root).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("invalid".utf8).write(to: GoalongPrivacyPolicy.file(in: root))
        let blocked = GoalongPrivacyPolicy.load(in: root)
        XCTAssertTrue(blocked.blocked); XCTAssertTrue(blocked.excludes(appID: "anything"))
    }
    func testExcludedDomainsIncludeSubdomainsNotSimilarSuffixes() {
        var policy = GoalongPrivacyPolicy(); policy.domains = ["private.example"]
        XCTAssertTrue(policy.excludes(domain: "mail.private.example"))
        XCTAssertTrue(policy.excludes(domain: "PRIVATE.EXAMPLE"))
        XCTAssertFalse(policy.excludes(domain: "notprivate.example"))
        XCTAssertFalse(policy.excludes(domain: "private.example.evil.test"))
    }
    func testExclusionAddsDenyWithoutEmptyingAllowlist() {
        var config = RecorderConfig.default
        config.includedBundleIdentifiers = ["com.test.only"]
        var policy = GoalongPrivacyPolicy(); policy.applications = ["com.test.only":"Only"]
        let result = policy.applying(to: config)
        XCTAssertEqual(result.includedBundleIdentifiers, ["com.test.only"])
        XCTAssertTrue(result.excludedBundleIdentifiers.contains("com.test.only"))
        XCTAssertFalse(result.allowsApplication(bundleIdentifier: "com.test.other"))
    }
    func testPendingObservationIsScrubbedWhenPrivacyRevisionChanges() throws {
        let event = HistoryEvent(sessionID: "session", kind: .applicationActivated,
            app: .init(name: "Private App", bundleIdentifier: "com.test.private", processIdentifier: 7),
            window: .init(title: "SECRET DOCUMENT", role: nil, subrole: nil), message: "SECRET MESSAGE")
        var policy = GoalongPrivacyPolicy(); policy.revision = "new"
        let safe = policy.eventForPersistence(event, expectedRevision: "old")
        XCTAssertEqual(safe.id, event.id); XCTAssertEqual(safe.timestamp, event.timestamp)
        XCTAssertNil(safe.app); XCTAssertNil(safe.window); XCTAssertNil(safe.message)
        XCTAssertNil(safe.url); XCTAssertNil(safe.semanticContext); XCTAssertNil(safe.metadata)
        XCTAssertEqual(safe.kind, .heartbeat)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(safe), as: UTF8.self).contains("SECRET"))
        XCTAssertEqual(policy.eventForPersistence(event, expectedRevision: "new"), event)
        policy.applications["com.test.private"] = "Private App"
        XCTAssertNil(policy.eventForPersistence(event, expectedRevision: "new").app)
    }
    func testFastPolicyCacheSeesSameSizeReplacements() throws {
        let root = try temporaryRoot()
        var policy = GoalongPrivacyPolicy(); policy.revision = "one"
        try policy.save(in: root)
        XCTAssertEqual(GoalongPrivacyPolicyCache.read(in: root).revision, "one")
        policy.revision = "two"; try policy.save(in: root)
        XCTAssertEqual(GoalongPrivacyPolicyCache.read(in: root).revision, "two")
    }
}
