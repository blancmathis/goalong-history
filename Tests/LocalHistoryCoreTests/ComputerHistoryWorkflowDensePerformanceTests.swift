import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistoryWorkflowDensePerformanceTests: XCTestCase {
    func testActionPrefixFilterMatchesExhaustiveWeightedReference() {
        let actionFeatures: [(ComputerHistoryActionKind, String)] = [
            (.click, "Action feature alpha"),
            (.typing, "Action feature beta"),
            (.shortcut, "Action feature gamma"),
            (.navigationKey, "Action feature delta"),
        ]

        for leftMask in 1..<(1 << actionFeatures.count) {
            for rightMask in 1..<(1 << actionFeatures.count) {
                let left = makeActionSetEpisode(
                    id: "prefix-left-\(leftMask)-\(rightMask)",
                    fingerprint: "prefix-left-fingerprint-\(leftMask)-\(rightMask)",
                    mask: leftMask,
                    features: actionFeatures
                )
                let right = makeActionSetEpisode(
                    id: "prefix-right-\(leftMask)-\(rightMask)",
                    fingerprint: "prefix-right-fingerprint-\(leftMask)-\(rightMask)",
                    mask: rightMask,
                    features: actionFeatures
                )
                let intersectionCount = (leftMask & rightMask).nonzeroBitCount
                let unionCount = (leftMask | rightMask).nonzeroBitCount
                let actionJaccard = Double(intersectionCount) / Double(unionCount)
                let shouldMatch = actionJaccard * 0.55 + 0.25 + 0.20 >= 0.72

                let result = ComputerHistoryWorkflowDetector.detect(
                    currentEpisodes: [left, right],
                    priorMemories: []
                )

                XCTAssertEqual(
                    result.patterns.count,
                    shouldMatch ? 1 : 0,
                    "Unexpected prefix result for masks \(leftMask) and \(rightMask)"
                )
            }
        }
    }

    func testDenseSharedPostingsRemainDeterministicWithinBudget() {
        let episodes = (0..<5_000).map(makeDenseEpisode)

        let clock = ContinuousClock()
        let startedAt = clock.now
        let first = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: episodes,
            priorMemories: []
        )
        let second = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: episodes,
            priorMemories: []
        )
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(first.patterns, second.patterns)
        XCTAssertEqual(first.suggestions, second.suggestions)
        XCTAssertEqual(first.patterns.count, 1)
        XCTAssertEqual(first.patterns.first?.occurrenceCount, 2)
        XCTAssertEqual(
            first.patterns.first?.episodeIDs,
            ["dense-episode-123", "dense-episode-4999"]
        )
        XCTAssertEqual(first.suggestions.count, 1)
        XCTAssertLessThan(
            elapsed,
            .seconds(8),
            "Two deterministic passes over 5,000 dense candidates exceeded the bounded budget"
        )
    }

    private func makeActionSetEpisode(
        id: String,
        fingerprint: String,
        mask: Int,
        features: [(ComputerHistoryActionKind, String)]
    ) -> ComputerHistoryEpisode {
        let selected = features.enumerated().compactMap { index, feature in
            mask & (1 << index) == 0 ? nil : feature
        }
        var expanded = selected
        while expanded.count < 3 {
            expanded.append(selected[expanded.count % selected.count])
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interactions = expanded.enumerated().map { offset, feature in
            makeInteraction(
                episodeIndex: mask,
                offset: offset,
                action: feature.0,
                application: feature.1,
                start: start
            )
        }
        return ComputerHistoryEpisode(
            id: id,
            start: start,
            end: start.addingTimeInterval(Double(interactions.count)),
            title: "Shared title tokens",
            summary: "Prefix-filter parity fixture.",
            status: .inProgress,
            statusConfidence: 1,
            applications: ["Shared context application"],
            sites: [],
            resourceIDs: [],
            requestsOrIntentions: [],
            observableOutcomes: [],
            interactions: interactions,
            eventCount: interactions.count,
            semanticSnapshotCount: 0,
            workflowFingerprint: fingerprint,
            provenance: .none
        )
    }

    private func makeDenseEpisode(_ index: Int) -> ComputerHistoryEpisode {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 10))
        let uniqueApplication = "Dense unique application \(index)"
        let interactions = [
            makeInteraction(
                episodeIndex: index,
                offset: 0,
                action: .click,
                application: "Dense shared application",
                start: start
            ),
            makeInteraction(
                episodeIndex: index,
                offset: 1,
                action: .typing,
                application: uniqueApplication,
                start: start
            ),
            makeInteraction(
                episodeIndex: index,
                offset: 2,
                action: .shortcut,
                application: uniqueApplication,
                start: start
            ),
        ]
        let fingerprint =
            index == 4_999
            ? "dense-fingerprint-123"
            : "dense-fingerprint-\(index)"
        return ComputerHistoryEpisode(
            id: "dense-episode-\(index)",
            start: start,
            end: start.addingTimeInterval(3),
            title: "Dense adversarial workflow \(index)",
            summary: "A distinct dense workflow that must remain separate.",
            status: .inProgress,
            statusConfidence: 1,
            applications: ["Dense shared application", uniqueApplication],
            sites: [],
            resourceIDs: [],
            requestsOrIntentions: [],
            observableOutcomes: [],
            interactions: interactions,
            eventCount: interactions.count,
            semanticSnapshotCount: 0,
            workflowFingerprint: fingerprint,
            provenance: .none
        )
    }

    private func makeInteraction(
        episodeIndex: Int,
        offset: Int,
        action: ComputerHistoryActionKind,
        application: String,
        start: Date
    ) -> ComputerHistoryInteraction {
        ComputerHistoryInteraction(
            id: "dense-interaction-\(episodeIndex)-\(offset)",
            start: start.addingTimeInterval(Double(offset)),
            end: start.addingTimeInterval(Double(offset) + 0.5),
            action: action,
            label: action.rawValue,
            application: application,
            bundleIdentifier: nil,
            host: nil,
            resourceIDs: [],
            beforeContext: nil,
            afterContext: nil,
            semanticDelta: [],
            confidence: 1,
            provenance: ActivityProvenance(
                sourceEventIDs: ["dense-event-\(episodeIndex)-\(offset)"],
                sourceSequences: [UInt64(episodeIndex * 3 + offset + 1)],
                sourceEventHashes: []
            )
        )
    }
}
