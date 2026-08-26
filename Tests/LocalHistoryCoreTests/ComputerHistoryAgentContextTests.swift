import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryAgentContextTests: XCTestCase {
    func testEvidencePackIsBoundedDenseChronologicalAndSourceGrounded() throws {
        let memory = makeMemory(episodeCount: 48)

        let projection = ComputerHistoryAgentContextRenderer.render(
            memory,
            tokenBudget: 800
        )

        XCTAssertLessThanOrEqual(projection.approximateTokenCount, 800)
        XCTAssertLessThan(projection.selectedEpisodeCount, memory.episodes.count)
        XCTAssertGreaterThan(projection.selectedEpisodeCount, 1)
        XCTAssertGreaterThan(projection.selectedInteractionCount, 0)
        XCTAssertGreaterThan(projection.selectedResourceCount, 0)
        XCTAssertGreaterThan(projection.informationFactsPerThousandTokens, 18)
        XCTAssertTrue(projection.markdown.contains("events=960"))
        XCTAssertTrue(projection.markdown.contains("actions=480"))
        XCTAssertTrue(projection.markdown.contains("paired_before_after=240"))
        XCTAssertTrue(projection.markdown.contains("source_seq=1-960"))
        XCTAssertTrue(projection.markdown.contains("last_hash=" + String(repeating: "a", count: 64)))
        XCTAssertTrue(projection.markdown.contains("Action sequence"))
        XCTAssertTrue(projection.markdown.contains("locator=https://example.com/document/"))
        XCTAssertTrue(projection.markdown.contains("Projection:"))
        XCTAssertFalse(projection.markdown.contains("STALE_MARKDOWN_MUST_NOT_BE_REUSED"))
        XCTAssertFalse(projection.markdown.contains("hunter2"))
        XCTAssertTrue(projection.markdown.contains("REDACTED"))

        let headings = projection.markdown.components(separatedBy: "\n")
            .filter { $0.hasPrefix("### ") }
        let times = headings.compactMap {
            $0.dropFirst(4).split(separator: " ").first.map(String.init)
        }
        XCTAssertEqual(times, times.sorted())
    }

    func testEvidencePackIsDeterministicAndUsesExtraBudgetForMoreFacts() {
        let memory = makeMemory(episodeCount: 64)
        let compact = ComputerHistoryAgentContextRenderer.render(memory, tokenBudget: 800)
        let repeated = ComputerHistoryAgentContextRenderer.render(memory, tokenBudget: 800)
        let larger = ComputerHistoryAgentContextRenderer.render(memory, tokenBudget: 3_000)

        XCTAssertEqual(compact, repeated)
        XCTAssertEqual(compact.availableInformationFactCount, larger.availableInformationFactCount)
        XCTAssertGreaterThanOrEqual(larger.informationFactCount, compact.informationFactCount)
        XCTAssertGreaterThanOrEqual(larger.selectedEpisodeCount, compact.selectedEpisodeCount)
        XCTAssertLessThanOrEqual(larger.approximateTokenCount, 3_000)
        XCTAssertLessThan(larger.markdown.utf8.count, memory.markdown.utf8.count)
        XCTAssertFalse(larger.markdown.contains("Run this suggested prompt"))
    }

    private func makeMemory(episodeCount: Int) -> ComputerHistoryDayMemory {
        let resources = (0..<episodeCount).map { index in
            ComputerHistoryResourceReference(
                id: "resource-\(index)",
                kind: .document,
                title: "Document \(index)",
                canonicalURI: "https://example.com/document/\(index)",
                localPath: nil,
                host: "example.com",
                application: "Safari",
                bundleIdentifier: "com.apple.Safari",
                locatorConfidence: 0.95,
                firstSeen: fixtureStart.addingTimeInterval(TimeInterval(index * 600)),
                lastSeen: fixtureStart.addingTimeInterval(TimeInterval(index * 600 + 120)),
                provenance: provenance(index * 10 + 1, index * 10 + 4)
            )
        }
        let episodes = (0..<episodeCount).map { index in
            let start = fixtureStart.addingTimeInterval(TimeInterval(index * 600))
            let interaction = ComputerHistoryInteraction(
                id: "interaction-\(index)",
                start: start.addingTimeInterval(30),
                end: start.addingTimeInterval(34),
                action: index.isMultiple(of: 3) ? .typing : .click,
                label: "Edited useful field \(index)",
                application: "Safari",
                bundleIdentifier: "com.apple.Safari",
                host: "example.com",
                resourceIDs: ["resource-\(index)"],
                beforeContext: "Draft \(index)",
                afterContext: "Saved result \(index)",
                semanticDelta: ["Saved result \(index)"],
                confidence: 0.92,
                provenance: provenance(index * 10 + 2, index * 10 + 3)
            )
            return ComputerHistoryEpisode(
                id: "episode-\(index)",
                start: start,
                end: start.addingTimeInterval(180),
                title: "Work episode \(String(format: "%02d", index))",
                summary: index == 0
                    ? "password=hunter2 was visible before completing the first task"
                    : "Worked on document \(index) and preserved the observable result",
                status: index.isMultiple(of: 5) ? .completed : .inProgress,
                statusConfidence: 0.8,
                applications: ["Safari"],
                sites: ["example.com"],
                resourceIDs: ["resource-\(index)"],
                requestsOrIntentions: ["Update document \(index)"],
                observableOutcomes: ["Saved result \(index)"],
                interactions: [interaction],
                eventCount: 20,
                semanticSnapshotCount: 5,
                workflowFingerprint: "document-edit",
                provenance: provenance(index * 10 + 1, index * 10 + 4)
            )
        }
        let coverage = ComputerHistoryCoverage(
            sourceEventCount: 960,
            actionEventCount: 480,
            semanticSnapshotCount: 240,
            linkedInteractionCount: episodeCount,
            interactionsWithBeforeAndAfterContext: 240,
            resourceCount: episodeCount,
            episodeCount: episodeCount,
            suppressedEventCount: 12,
            firstSourceSequence: 1,
            lastSourceSequence: 960,
            lastSourceEventHash: String(repeating: "a", count: 64)
        )
        return ComputerHistoryDayMemory(
            dayStart: fixtureStart,
            dayEnd: fixtureStart.addingTimeInterval(86_399),
            generatedAt: fixtureStart.addingTimeInterval(86_400),
            title: "Dense local evidence",
            executiveSummary: "A deterministic local day projection.",
            episodes: episodes,
            resources: resources,
            workflowPatterns: [],
            suggestions: [
                ComputerHistorySuggestion(
                    id: "suggestion",
                    kind: .automation,
                    title: "Suggestion",
                    rationale: "Repeated workflow",
                    suggestedPrompt: "Run this suggested prompt",
                    workflowID: nil,
                    episodeIDs: ["episode-0"],
                    confidence: 0.9
                )
            ],
            coverage: coverage,
            markdown: String(repeating: "STALE_MARKDOWN_MUST_NOT_BE_REUSED\n", count: 10_000)
        )
    }

    private func provenance(_ first: Int, _ last: Int) -> ActivityProvenance {
        ActivityProvenance(
            sourceEventIDs: ["event-\(first)", "event-\(last)"],
            sourceSequences: [UInt64(first), UInt64(last)],
            sourceEventHashes: ["hash-\(first)", "hash-\(last)"]
        )
    }
}
