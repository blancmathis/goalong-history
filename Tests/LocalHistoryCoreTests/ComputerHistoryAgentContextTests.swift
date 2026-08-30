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
        XCTAssertTrue(projection.markdown.contains("Complete chronological skeleton"))
        XCTAssertTrue(projection.markdown.contains("Skeleton coverage: 48/48 episodes"))
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

    func testDenseSingleEpisodeUsesProgressiveDetailInsteadOfDisappearing() {
        let memory = makeDenseSingleEpisodeMemory()

        let startedAt = ProcessInfo.processInfo.systemUptime
        let projection = ComputerHistoryAgentContextRenderer.render(
            memory,
            tokenBudget: 1_500
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertLessThanOrEqual(projection.approximateTokenCount, 1_500)
        XCTAssertEqual(projection.selectedEpisodeCount, 1)
        XCTAssertGreaterThanOrEqual(projection.selectedInteractionCount, 8)
        XCTAssertTrue(projection.markdown.contains("Ask For More Time"))
        XCTAssertTrue(projection.markdown.contains("nearby_observed_change=Time Limit"))
        XCTAssertTrue(projection.markdown.contains("IMG_9031.HEIC"))
        XCTAssertTrue(projection.markdown.contains("Terminer sauvegarde Google Photos"))
        XCTAssertTrue(
            projection.markdown.contains(
                "nearby_focus=Terminer sauvegarde Google Photos lots 10 à 15"
            )
        )
        XCTAssertTrue(projection.markdown.contains("Interval minutes"))
        XCTAssertTrue(projection.markdown.contains("IMG_9033.MOV 23.6 MB"))
        XCTAssertTrue(projection.markdown.contains("Downloading"))
        XCTAssertTrue(projection.markdown.contains("SFR_B5EF_EXT"))
        XCTAssertTrue(projection.markdown.contains("30 minutes"))
        XCTAssertGreaterThan(projection.approximateTokenCount, 700)
        XCTAssertTrue(projection.markdown.contains("640 actions"))
        XCTAssertLessThan(
            elapsed,
            2.0,
            "A dense persisted episode must remain cheap enough for an interactive CLI read."
        )
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

    private func makeDenseSingleEpisodeMemory() -> ComputerHistoryDayMemory {
        let interactions = (0..<640).map { index -> ComputerHistoryInteraction in
            let start = fixtureStart.addingTimeInterval(TimeInterval(index * 4))
            let application: String
            let action: ComputerHistoryActionKind
            let label: String
            let semanticDelta: [String]
            switch index {
            case 15:
                application = "Google Chrome"
                action = .drag
                label = "Dragged to Download - Shift+D"
                semanticDelta = ["Downloading..."]
            case 16:
                application = "Google Chrome"
                action = .windowChange
                label = "Opened or focused window Recent download history"
                semanticDelta = ["IMG_9033.MOV 23.6 MB • Done"]
            case 30:
                application = "QuickTime Player"
                action = .drag
                label = "Dragged to Ask For More Time"
                semanticDelta = []
            case 31:
                application = "QuickTime Player"
                action = .focusChange
                label = "Focused standard window"
                semanticDelta = ["Time Limit", "You’ve reached your limit on QuickTime Player."]
            case 60:
                application = "Preview"
                action = .windowChange
                label = "Opened or focused window IMG_9031.HEIC"
                semanticDelta = ["IMG_9031.HEIC"]
            case 61:
                application = "Preview"
                action = .click
                label = "Clicked image"
                semanticDelta = []
            case 89:
                application = "ChatGPT"
                action = .focusChange
                label = "Focused Terminer sauvegarde Google Photos lots 10 à 15"
                semanticDelta = []
            case 90:
                application = "ChatGPT"
                action = .click
                label = "Opened scheduled task"
                semanticDelta = ["Details", "Frequency"]
            case 91:
                application = "ChatGPT"
                action = .typing
                label = "Typed 2 key events in Interval minutes"
                semanticDelta = ["30 minutes", "Open settings"]
            case 105:
                application = "Control Center"
                action = .windowChange
                label = "Opened or focused window Control Center"
                semanticDelta = ["SFR_B5EF_EXT", "3 bars"]
            default:
                application = "Google Chrome"
                action = index.isMultiple(of: 7) ? .click : .scroll
                label = index.isMultiple(of: 7)
                    ? "Opened Google Photos item \(index)"
                    : "Scrolled through Google Photos"
                semanticDelta = index.isMultiple(of: 17)
                    ? ["Google Photos item \(index)"]
                    : []
            }
            return ComputerHistoryInteraction(
                id: "dense-interaction-\(String(format: "%03d", index))",
                start: start,
                end: start.addingTimeInterval(1),
                action: action,
                label: label,
                application: application,
                bundleIdentifier: "test.\(application.replacingOccurrences(of: " ", with: "-"))",
                host: application == "Google Chrome" ? "photos.google.com" : nil,
                resourceIDs: [],
                beforeContext: nil,
                afterContext: semanticDelta.isEmpty ? nil : semanticDelta.joined(separator: "\n"),
                semanticDelta: semanticDelta,
                confidence: 0.9,
                provenance: provenance(index + 1, index + 1)
            )
        }
        let episode = ComputerHistoryEpisode(
            id: "dense-episode",
            start: fixtureStart,
            end: fixtureStart.addingTimeInterval(2_560),
            title: "Google Photos browsing, media checks and scheduled task editing",
            summary: "Browsed Google Photos, opened downloaded media and edited a scheduled task.",
            status: .inProgress,
            statusConfidence: 0.8,
            applications: ["Google Chrome", "QuickTime Player", "Preview", "ChatGPT", "Control Center"],
            sites: ["photos.google.com"],
            resourceIDs: [],
            requestsOrIntentions: [],
            observableOutcomes: ["Returned to Google Photos"],
            interactions: interactions,
            eventCount: 1_280,
            semanticSnapshotCount: 160,
            workflowFingerprint: "dense-fixture",
            provenance: provenance(1, 1_280)
        )
        return ComputerHistoryDayMemory(
            dayStart: fixtureStart,
            dayEnd: fixtureStart.addingTimeInterval(86_399),
            generatedAt: fixtureStart.addingTimeInterval(86_400),
            title: "Dense local evidence",
            executiveSummary: "One dense episode reconstructed from complete local evidence.",
            episodes: [episode],
            resources: [],
            workflowPatterns: [],
            suggestions: [],
            coverage: ComputerHistoryCoverage(
                sourceEventCount: 1_280,
                actionEventCount: 640,
                semanticSnapshotCount: 160,
                linkedInteractionCount: 640,
                interactionsWithBeforeAndAfterContext: 0,
                resourceCount: 0,
                episodeCount: 1,
                suppressedEventCount: 0,
                firstSourceSequence: 1,
                lastSourceSequence: 1_280,
                lastSourceEventHash: String(repeating: "b", count: 64)
            ),
            markdown: ""
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
