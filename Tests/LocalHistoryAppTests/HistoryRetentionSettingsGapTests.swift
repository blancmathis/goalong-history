#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// The wording and the change tracking of the retention settings.
final class HistoryRetentionSettingsGapTests: XCTestCase {
    private func policy(events: Int? = nil, seals: Int? = nil, receipts: Int? = nil) -> HistoryRetentionPolicy {
        HistoryRetentionPolicy(detailedEvents: RetentionDuration(days: events), semanticSnapshots: .indefinite, memories: .indefinite,
                               analysisCaches: .indefinite, minuteSeals: RetentionDuration(days: seals),
                               anchorReceipts: RetentionDuration(days: receipts))
    }

    func testDescriptionNamesEveryClassWithSingularPluralAndIndefinite() {
        let lines = policy(events: 1, seals: 30).retentionDescription.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, HistoryDataClass.allCases.count)
        XCTAssertTrue(lines.contains("Activité détaillée : 1 jour"))
        XCTAssertTrue(lines.contains("Sceaux d’intégrité : 30 jours"))
        XCTAssertTrue(lines.contains("Reçus de vérification : jusqu’à ce que je supprime"))
        for kind in HistoryDataClass.allCases { XCTAssertFalse(kind.retentionTitle.isEmpty) }
    }

    func testProofExpiryOnlyCountsSealsAndReceipts() {
        XCTAssertFalse(policy(events: 7).includesProofExpiry)
        XCTAssertTrue(policy(seals: 7).includesProofExpiry)
        XCTAssertTrue(policy(receipts: 7).includesProofExpiry)
        XCTAssertEqual(HistoryRetentionPolicy.automaticCleanupSummary(enabled: true), "Suppression automatique activée")
        XCTAssertEqual(HistoryRetentionPolicy.automaticCleanupSummary(enabled: false), "Jusqu’à suppression manuelle")
    }

    func testSetDurationTouchesOnlyItsOwnClass() {
        for kind in HistoryDataClass.allCases {
            var value = policy()
            value.setDuration(RetentionDuration(days: 90), for: kind)
            XCTAssertEqual(value.duration(for: kind).days, 90, "\(kind)")
            for other in HistoryDataClass.allCases where other != kind {
                XCTAssertNil(value.duration(for: other).days, "\(kind) changed \(other)")
            }
        }
    }

    @MainActor func testModelTracksChangesAndSavesWithoutActivatingCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = HistoryRetentionStorage(policyFile: root.appendingPathComponent("policy.json"),
                                              activationFile: root.appendingPathComponent("activation.json"),
                                              artifactDirectories: [], prepare: {})
        let model = HistoryRetentionSettingsModel(store: HistoryRetentionStore(legacyRetentionDays: 30, storage: storage))
        XCTAssertFalse(model.hasChanges)
        model.draft.setDuration(RetentionDuration(days: 7), for: .detailedEvents)
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(model.apply(proofDeletionConfirmed: false))
        XCTAssertFalse(model.hasChanges, "Saving makes the draft the saved policy")
        XCTAssertFalse(model.automaticCleanup, "Saving alone never turns deletion on")
        XCTAssertNil(model.error)
        model.automaticCleanup = true
        XCTAssertTrue(model.hasChanges, "Switching cleanup on is a change")
    }
}
#endif
