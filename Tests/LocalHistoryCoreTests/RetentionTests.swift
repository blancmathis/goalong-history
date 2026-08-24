import XCTest
@testable import LocalHistoryCore

final class RetentionTests: XCTestCase {
    func testNonPositiveAndAdversarialDurationsKeepHistoryIndefinitely() throws {
        for value in [0, -1, Int.min] {
            let duration = RetentionDuration(days: value)
            XCTAssertNil(duration.days)
            XCTAssertNil(duration.cutoff(relativeTo: fixtureStart))
        }

        let decoded = try JSONDecoder().decode(
            RetentionDuration.self,
            from: Data(#"{"days":-9223372036854775808}"#.utf8)
        )
        XCTAssertNil(decoded.days)
        XCTAssertNil(decoded.cutoff(relativeTo: fixtureStart))

        let old = fixtureStart.addingTimeInterval(-10_000 * 86_400)
        var policy = HistoryRetentionPolicy.migratingLegacy(retentionDays: 30)
        policy.detailedEvents = decoded
        let decision = RetentionPlanner.decisions(
            for: [
                HistoryStoredArtifact(
                    id: "old-event",
                    dataClass: .detailedEvents,
                    start: old,
                    end: old,
                    localPath: "events/old.jsonl"
                )
            ],
            policy: policy,
            now: fixtureStart
        ).first
        XCTAssertEqual(decision?.shouldDelete, false)
        XCTAssertEqual(decision?.reason, .indefiniteRetention)
    }

    func testDurationUpperBoundCannotExpandArithmeticOrPolicyWindow() throws {
        let direct = RetentionDuration(days: Int.max)
        XCTAssertEqual(direct.days, RetentionDuration.maximumDays)

        let decoded = try JSONDecoder().decode(
            RetentionDuration.self,
            from: Data(#"{"days":9223372036854775807}"#.utf8)
        )
        XCTAssertEqual(decoded.days, RetentionDuration.maximumDays)
        XCTAssertNotNil(decoded.cutoff(relativeTo: fixtureStart))
    }

    func testUnknownPolicySchemaAndInvalidLegacyProvenanceCannotAuthorizeCleanup() {
        let unsupported = HistoryRetentionPolicy(
            schemaVersion: 999,
            detailedEvents: RetentionDuration(days: 1),
            semanticSnapshots: .indefinite,
            memories: .indefinite,
            analysisCaches: .indefinite,
            minuteSeals: .indefinite,
            anchorReceipts: .indefinite
        )
        XCTAssertFalse(unsupported.isSupportedForAutomaticCleanup)

        let invalidProvenance = HistoryRetentionPolicy(
            detailedEvents: RetentionDuration(days: 1),
            semanticSnapshots: .indefinite,
            memories: .indefinite,
            analysisCaches: .indefinite,
            minuteSeals: .indefinite,
            anchorReceipts: .indefinite,
            migratedFromLegacyRetentionDays: Int.min
        )
        XCTAssertFalse(invalidProvenance.isSupportedForAutomaticCleanup)
    }

    func testLegacyMigrationIsNonDestructiveForMemoriesAndProofs() {
        let policy = HistoryRetentionPolicy.migratingLegacy(retentionDays: 30)
        XCTAssertEqual(policy.detailedEvents.days, 30)
        XCTAssertEqual(policy.semanticSnapshots.days, 30)
        XCTAssertEqual(policy.analysisCaches.days, 30)
        XCTAssertNil(policy.memories.days)
        XCTAssertNil(policy.minuteSeals.days)
        XCTAssertNil(policy.anchorReceipts.days)
        XCTAssertEqual(policy.migratedFromLegacyRetentionDays, 30)
    }

    func testNegativeLegacyMigrationIsNonDestructiveForEveryInheritedClass() {
        let policy = HistoryRetentionPolicy.migratingLegacy(retentionDays: Int.min)
        XCTAssertNil(policy.detailedEvents.days)
        XCTAssertNil(policy.semanticSnapshots.days)
        XCTAssertNil(policy.analysisCaches.days)
        XCTAssertNil(policy.memories.days)
        XCTAssertNil(policy.minuteSeals.days)
        XCTAssertNil(policy.anchorReceipts.days)
        XCTAssertEqual(policy.migratedFromLegacyRetentionDays, 0)
    }

    func testRetentionDecisionsAreIndependentByDataClass() {
        let now = fixtureStart
        let old = fixtureStart.addingTimeInterval(-100 * 86_400)
        let artifacts = [
            HistoryStoredArtifact(id: "event", dataClass: .detailedEvents, start: old, end: old, localPath: "events/old.jsonl"),
            HistoryStoredArtifact(id: "memory", dataClass: .memories, start: old, end: old, localPath: "memories/old.json"),
            HistoryStoredArtifact(id: "seal", dataClass: .minuteSeals, start: old, end: old, localPath: "seals/old.jsonl"),
        ]
        let decisions = RetentionPlanner.decisions(
            for: artifacts,
            policy: .migratingLegacy(retentionDays: 30),
            now: now
        )
        XCTAssertTrue(decisions.first(where: { $0.artifact.id == "event" })!.shouldDelete)
        XCTAssertFalse(decisions.first(where: { $0.artifact.id == "memory" })!.shouldDelete)
        XCTAssertFalse(decisions.first(where: { $0.artifact.id == "seal" })!.shouldDelete)
    }

    func testDeleteAllDetailedDataPreservesProofs() {
        let artifacts = HistoryDataClass.allCases.map { dataClass in
            HistoryStoredArtifact(
                id: dataClass.rawValue,
                dataClass: dataClass,
                start: fixtureStart,
                end: fixtureStart,
                localPath: dataClass.rawValue
            )
        }
        let plan = HistoryDeletionPlanner.plan(
            request: HistoryDeletionRequest(scope: .allDetailedData),
            artifacts: artifacts
        )
        XCTAssertEqual(Set(plan.matchingArtifactIDs), Set(["detailedEvents", "semanticSnapshots"]))
        XCTAssertTrue(plan.preservedProofArtifactIDs.isEmpty)

        let allPlan = HistoryDeletionPlanner.plan(
            request: HistoryDeletionRequest(scope: .allLocalHistoryIncludingProofs),
            artifacts: artifacts
        )
        XCTAssertEqual(Set(allPlan.preservedProofArtifactIDs), Set(["minuteSeals", "anchorReceipts"]))
        XCTAssertFalse(allPlan.matchingArtifactIDs.contains("minuteSeals"))
    }

    func testExplicitProofDeletionIncludesLocalSealsAndReceipts() {
        let artifacts = [
            HistoryStoredArtifact(id: "seal", dataClass: .minuteSeals, start: fixtureStart, end: fixtureStart, localPath: "seal"),
            HistoryStoredArtifact(id: "receipt", dataClass: .anchorReceipts, start: fixtureStart, end: fixtureStart, localPath: "receipt"),
        ]
        let plan = HistoryDeletionPlanner.plan(
            request: HistoryDeletionRequest(
                scope: .allLocalHistoryIncludingProofs,
                includeCryptographicProofs: true
            ),
            artifacts: artifacts
        )
        XCTAssertEqual(Set(plan.matchingArtifactIDs), Set(["seal", "receipt"]))
        XCTAssertTrue(plan.preservedProofArtifactIDs.isEmpty)
        XCTAssertTrue(plan.explanation.contains("published external commitments"))
    }
}
