import XCTest
import LocalHistoryCore
@testable import LocalHistoryQueryCLI

/// The last gate before an export leaves the Mac: any doubt about an excluded app or site must refuse.
final class GoalongOutgoingPrivacyTests: XCTestCase {
    private func makeRoot(_ configure: (inout GoalongPrivacyPolicy) -> Void) throws -> (URL, GoalongPrivacyPolicy) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-outgoing-\(UUID().uuidString)", isDirectory: true)
        var policy = GoalongPrivacyPolicy()
        configure(&policy)
        try policy.save(in: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, GoalongPrivacyPolicy.load(in: root))
    }

    private func payload(
        version: Int = 2,
        summary: String = "",
        agent: Any = NSNull(),
        device: [String: Any] = ["apps": []],
        websites: Any = NSNull()
    ) throws -> Data {
        let day: [String: Any] = [
            "date": "2026-10-20", "summary": summary, "outcomes": [], "activities": [],
            "telemetry": ["agent": agent, "devices": [device], "websites": websites],
        ]
        return try JSONSerialization.data(withJSONObject: ["version": version, "days": [day]])
    }

    private func assertRefused(_ data: Data, root: URL, revision: String?, _ fragment: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GoalongOutgoingPrivacy.validate(data, root: root, expectedRevision: revision),
                             file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(fragment), "\(error)", file: file, line: line)
        }
    }

    func testBlockedPolicyRefusesEveryExport() throws {
        let (root, policy) = try makeRoot { $0.blocked = true }
        assertRefused(try payload(), root: root, revision: policy.revision, "Les exclusions ont changé")
    }

    func testNoExclusionsLetsAnyPayloadThroughWithoutParsingIt() throws {
        let (root, policy) = try makeRoot { _ in }
        XCTAssertFalse(policy.hasExclusions)
        XCTAssertNoThrow(try GoalongOutgoingPrivacy.validate(Data("not json".utf8), root: root, expectedRevision: nil))
    }

    func testExclusionsRefuseAnExportThatIsNotVersionTwoWithDays() throws {
        let (root, policy) = try makeRoot { $0.domains = ["secret.example"] }
        assertRefused(try payload(version: 1), root: root, revision: policy.revision, "ne permet pas de vérifier")
        let empty = try JSONSerialization.data(withJSONObject: ["version": 2, "days": []])
        assertRefused(empty, root: root, revision: policy.revision, "ne permet pas de vérifier")
    }

    func testExclusionsRefuseFreeTextAndAgentAnalyses() throws {
        let (root, policy) = try makeRoot { $0.applications = ["com.secret.app": "Secret"] }
        assertRefused(try payload(summary: "Worked on Secret"), root: root, revision: policy.revision, "textes et analyses")
        assertRefused(try payload(agent: ["seconds": 10]), root: root, revision: policy.revision, "textes et analyses")
    }

    func testExclusionsRefuseTotalsAndHourlyBucketsThatCouldHideExcludedTime() throws {
        let (root, policy) = try makeRoot { $0.applications = ["com.secret.app": "Secret"] }
        assertRefused(try payload(device: ["apps": [], "screenSeconds": 3600]), root: root, revision: policy.revision, "total ou un horaire")
        assertRefused(try payload(device: ["apps": [], "hourly": [1, 2]]), root: root, revision: policy.revision, "total ou un horaire")
        assertRefused(try payload(device: ["screenSeconds": NSNull()]), root: root, revision: policy.revision, "total ou un horaire")
    }

    func testDomainExclusionsRefuseAppleDurationsButAllowTheirAbsence() throws {
        let (root, policy) = try makeRoot { $0.domains = ["secret.example"] }
        assertRefused(try payload(device: ["apps": [["id": "com.apple.Safari", "name": "Safari"]]]),
                      root: root, revision: policy.revision, "durées Apple")
        XCTAssertNoThrow(try GoalongOutgoingPrivacy.validate(try payload(), root: root, expectedRevision: policy.revision))
    }

    func testExcludedApplicationIsRefusedByIdentifierOrByNameIgnoringCase() throws {
        let (root, policy) = try makeRoot { $0.applications = ["com.secret.app": "Secret"] }
        assertRefused(try payload(device: ["apps": [["id": "COM.SECRET.APP", "name": "x"]]]),
                      root: root, revision: policy.revision, "application désormais exclue")
        assertRefused(try payload(device: ["apps": [["id": "other", "name": "secret"]]]),
                      root: root, revision: policy.revision, "application désormais exclue")
        XCTAssertNoThrow(try GoalongOutgoingPrivacy.validate(
            try payload(device: ["apps": [["id": "com.ok.app", "name": "Ok"]]]), root: root, expectedRevision: policy.revision))
    }

    func testExcludedWebsiteRowsAndRowsWithoutADomainAreRefused() throws {
        let (root, policy) = try makeRoot { $0.domains = ["secret.example"] }
        func sites(_ rows: [[String: Any]]) throws -> Data { try payload(websites: ["rows": rows]) }
        assertRefused(try sites([["domain": "a.secret.example"]]), root: root, revision: policy.revision, "site désormais exclu")
        assertRefused(try sites([["domain": "ok.example"], ["seconds": 5]]), root: root, revision: policy.revision, "site désormais exclu")
        XCTAssertNoThrow(try GoalongOutgoingPrivacy.validate(try sites([["domain": "ok.example"]]), root: root, expectedRevision: policy.revision))
    }

    func testStaleRevisionIsRefusedEvenWhenThePayloadIsClean() throws {
        let (root, _) = try makeRoot { $0.domains = ["secret.example"] }
        assertRefused(try payload(), root: root, revision: "stale", "Préparez un nouvel aperçu")
        assertRefused(try payload(), root: root, revision: nil, "Préparez un nouvel aperçu")
    }
}
