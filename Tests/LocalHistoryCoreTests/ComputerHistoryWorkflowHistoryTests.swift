import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistoryWorkflowHistoryTests: XCTestCase {
    func testCompactedPriorEpisodeUsesExactInteractionCount() throws {
        let fingerprint = "workflow-compacted-history"
        let priorEpisode = makeEpisode(
            id: "prior-compacted",
            start: fixtureStart,
            fingerprint: fingerprint,
            retainedActionCount: 1,
            sourceInteractionCount: 3
        )
        let currentEpisode = makeEpisode(
            id: "current-full",
            start: fixtureStart.addingTimeInterval(86_400),
            fingerprint: fingerprint
        )
        let result = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: [currentEpisode],
            priorMemories: [makeMemory(episodes: [priorEpisode])]
        )

        let pattern = try XCTUnwrap(result.patterns.first)
        XCTAssertEqual(priorEpisode.interactions.count, 1)
        XCTAssertEqual(priorEpisode.totalInteractionCount, 3)
        XCTAssertEqual(pattern.occurrenceCount, 2)
        XCTAssertEqual(pattern.episodeIDs, [currentEpisode.id])
        XCTAssertEqual(result.suggestions.first?.episodeIDs, [currentEpisode.id])
    }

    func testCumulativePriorPatternsUseMaximumAndEncodedMemoryPassesChecker() throws {
        let fingerprint = "workflow-cumulative-history"
        let olderEpisode = makeEpisode(
            id: "prior-older",
            start: fixtureStart,
            fingerprint: fingerprint,
            retainedActionCount: 1,
            sourceInteractionCount: 3
        )
        let newerEpisode = makeEpisode(
            id: "prior-newer",
            start: fixtureStart.addingTimeInterval(86_400),
            fingerprint: fingerprint,
            retainedActionCount: 1,
            sourceInteractionCount: 3
        )
        let olderPattern = makePattern(
            fingerprint: fingerprint,
            occurrenceCount: 2,
            episodeIDs: [olderEpisode.id]
        )
        let newerPattern = makePattern(
            fingerprint: fingerprint,
            occurrenceCount: 7,
            episodeIDs: [newerEpisode.id]
        )
        let currentEpisodes = [
            makeEpisode(
                id: "current-first",
                start: fixtureStart.addingTimeInterval(2 * 86_400),
                fingerprint: fingerprint
            ),
            makeEpisode(
                id: "current-second",
                start: fixtureStart.addingTimeInterval(2 * 86_400 + 3_600),
                fingerprint: fingerprint
            ),
        ]
        let result = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: currentEpisodes,
            priorMemories: [
                makeMemory(
                    episodes: [olderEpisode],
                    workflowPatterns: [olderPattern]
                ),
                makeMemory(
                    episodes: [newerEpisode],
                    workflowPatterns: [newerPattern]
                ),
            ]
        )

        let pattern = try XCTUnwrap(result.patterns.first)
        let currentEpisodeIDs = Set(currentEpisodes.map(\.id))
        XCTAssertEqual(pattern.fingerprint, fingerprint)
        XCTAssertEqual(pattern.occurrenceCount, 9)
        XCTAssertEqual(Set(pattern.episodeIDs), currentEpisodeIDs)
        XCTAssertEqual(Set(result.suggestions.first?.episodeIDs ?? []), currentEpisodeIDs)
        XCTAssertFalse(pattern.episodeIDs.contains(olderEpisode.id))
        XCTAssertFalse(pattern.episodeIDs.contains(newerEpisode.id))

        let currentMemory = makeMemory(
            episodes: currentEpisodes,
            workflowPatterns: result.patterns,
            suggestions: result.suggestions
        )
        try assertCheckerAccepts(currentMemory)
    }

    func testSimilarCurrentFingerprintDoesNotInheritDifferentFingerprintHistory() throws {
        let priorFingerprint = "workflow-prior-similar"
        let currentFingerprint = "workflow-current-similar"
        let priorEpisode = makeEpisode(
            id: "prior-similar",
            start: fixtureStart,
            fingerprint: priorFingerprint
        )
        let currentEpisode = makeEpisode(
            id: "current-similar",
            start: fixtureStart.addingTimeInterval(86_400),
            fingerprint: currentFingerprint
        )
        let result = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: [currentEpisode],
            priorMemories: [
                makeMemory(
                    episodes: [priorEpisode],
                    workflowPatterns: [
                        makePattern(
                            fingerprint: priorFingerprint,
                            occurrenceCount: 7,
                            episodeIDs: [priorEpisode.id]
                        )
                    ]
                )
            ]
        )

        let pattern = try XCTUnwrap(result.patterns.first)
        XCTAssertEqual(pattern.fingerprint, currentFingerprint)
        XCTAssertEqual(pattern.occurrenceCount, 2)
        XCTAssertEqual(pattern.episodeIDs, [currentEpisode.id])
    }

    func testHistoricalOnlyClustersAreNotReemittedForCurrentDay() {
        let fingerprint = "workflow-historical-only"
        let priorEpisodes = [
            makeEpisode(id: "prior-only-1", start: fixtureStart, fingerprint: fingerprint),
            makeEpisode(
                id: "prior-only-2",
                start: fixtureStart.addingTimeInterval(3_600),
                fingerprint: fingerprint
            ),
        ]
        let result = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: [],
            priorMemories: [
                makeMemory(
                    episodes: priorEpisodes,
                    workflowPatterns: [
                        makePattern(
                            fingerprint: fingerprint,
                            occurrenceCount: 7,
                            episodeIDs: priorEpisodes.map(\.id)
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(result.patterns.isEmpty)
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testFingerprintLearnedThroughSimilarityKeepsOneCanonicalCluster() throws {
        let baseActions: [ComputerHistoryActionKind] = [.click, .typing, .shortcut]
        let extendedActions = baseActions + [.navigationKey]
        let sharedFingerprint = "workflow-shared-through-similarity"
        let currentEpisodes = [
            makeEpisode(
                id: "zero-seed",
                start: fixtureStart,
                fingerprint: "workflow-zero-seed",
                actions: baseActions,
                application: "Zero App",
                title: "Zero workflow"
            ),
            makeEpisode(
                id: "one-seed",
                start: fixtureStart.addingTimeInterval(60),
                fingerprint: "workflow-one-seed",
                actions: baseActions,
                application: "One App",
                title: "One workflow"
            ),
            makeEpisode(
                id: "bridge-one",
                start: fixtureStart.addingTimeInterval(120),
                fingerprint: sharedFingerprint,
                retainedActionCount: extendedActions.count,
                actions: extendedActions,
                application: "One App",
                title: "One workflow"
            ),
            makeEpisode(
                id: "bridge-zero",
                start: fixtureStart.addingTimeInterval(180),
                fingerprint: sharedFingerprint,
                retainedActionCount: extendedActions.count,
                actions: extendedActions,
                application: "Zero App",
                title: "Zero workflow"
            ),
        ]

        let result = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: currentEpisodes,
            priorMemories: []
        )

        let pattern = try XCTUnwrap(result.patterns.first)
        XCTAssertEqual(result.patterns.count, 1)
        XCTAssertEqual(Set(result.patterns.map(\.id)).count, result.patterns.count)
        XCTAssertEqual(pattern.fingerprint, sharedFingerprint)
        XCTAssertEqual(pattern.occurrenceCount, 3)
        XCTAssertEqual(
            Set(pattern.episodeIDs),
            Set(["one-seed", "bridge-one", "bridge-zero"])
        )

        let memory = makeMemory(
            episodes: currentEpisodes,
            workflowPatterns: result.patterns,
            suggestions: result.suggestions
        )
        try assertCheckerAccepts(memory)
    }

    private func makeEpisode(
        id: String,
        start: Date,
        fingerprint: String,
        retainedActionCount: Int = 3,
        sourceInteractionCount: Int? = nil,
        actions: [ComputerHistoryActionKind] = [.click, .typing, .shortcut],
        application: String = "Workflow App",
        title: String = "Reviewed customer workflow"
    ) -> ComputerHistoryEpisode {
        let interactions = actions.prefix(retainedActionCount).enumerated().map {
            offset, action in
            ComputerHistoryInteraction(
                id: "\(id)-interaction-\(offset)",
                start: start.addingTimeInterval(TimeInterval(offset * 10)),
                end: start.addingTimeInterval(TimeInterval(offset * 10 + 1)),
                action: action,
                label: "\(action.rawValue) customer record",
                application: application,
                bundleIdentifier: "example.workflow",
                host: "workflow.example",
                resourceIDs: [],
                beforeContext: nil,
                afterContext: nil,
                semanticDelta: [],
                confidence: 1,
                provenance: ActivityProvenance(
                    sourceEventIDs: ["\(id)-event-\(offset)"],
                    sourceSequences: [UInt64(offset + 1)],
                    sourceEventHashes: []
                )
            )
        }
        let end = interactions.last?.end ?? start
        return ComputerHistoryEpisode(
            id: id,
            start: start,
            end: end,
            title: title,
            summary: "Observed a repeated customer workflow.",
            status: .completed,
            statusConfidence: 1,
            applications: [application],
            sites: ["workflow.example"],
            resourceIDs: [],
            requestsOrIntentions: [],
            observableOutcomes: ["Customer record saved"],
            interactions: interactions,
            sourceInteractionCount: sourceInteractionCount,
            eventCount: sourceInteractionCount ?? interactions.count,
            semanticSnapshotCount: 0,
            workflowFingerprint: fingerprint,
            provenance: ActivityProvenance(
                sourceEventIDs: ["\(id)-event"],
                sourceSequences: [1],
                sourceEventHashes: []
            )
        )
    }

    private func makePattern(
        fingerprint: String,
        occurrenceCount: Int,
        episodeIDs: [String]
    ) -> ComputerHistoryWorkflowPattern {
        ComputerHistoryWorkflowPattern(
            id: ComputerHistorySupport.stableIdentifier("workflow|\(fingerprint)"),
            fingerprint: fingerprint,
            title: "Reviewed customer workflow",
            occurrenceCount: occurrenceCount,
            episodeIDs: episodeIDs,
            actionSequence: ["click in Workflow App", "typing in Workflow App"],
            applications: ["Workflow App"],
            confidence: 0.98
        )
    }

    private func makeMemory(
        episodes: [ComputerHistoryEpisode],
        workflowPatterns: [ComputerHistoryWorkflowPattern] = [],
        suggestions: [ComputerHistorySuggestion] = []
    ) -> ComputerHistoryDayMemory {
        let exactInteractionCount = episodes.reduce(0) {
            $0 + $1.totalInteractionCount
        }
        let retainedInteractionCount = episodes.reduce(0) {
            $0 + $1.interactions.count
        }
        let usesProjection = exactInteractionCount != retainedInteractionCount
        let dayStart =
            episodes.first.map {
                Calendar(identifier: .gregorian).startOfDay(for: $0.start)
            } ?? fixtureStart
        return ComputerHistoryDayMemory(
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400 - 0.001),
            generatedAt: dayStart.addingTimeInterval(86_000),
            title: "Workflow history fixture",
            executiveSummary: "Workflow history fixture.",
            episodes: episodes,
            resources: [],
            workflowPatterns: workflowPatterns,
            suggestions: suggestions,
            coverage: ComputerHistoryCoverage(
                sourceEventCount: exactInteractionCount,
                actionEventCount: exactInteractionCount,
                semanticSnapshotCount: 0,
                linkedInteractionCount: exactInteractionCount,
                interactionsWithBeforeAndAfterContext: 0,
                resourceCount: 0,
                episodeCount: episodes.count,
                suppressedEventCount: 0,
                firstSourceSequence: episodes.isEmpty ? nil : 1,
                lastSourceSequence: episodes.isEmpty ? nil : UInt64(exactInteractionCount),
                lastSourceEventHash: episodes.isEmpty ? nil : "workflow-history-hash",
                retainedEpisodeCount: usesProjection ? episodes.count : nil,
                retainedInteractionCount: usesProjection ? retainedInteractionCount : nil,
                retainedResourceCount: usesProjection ? 0 : nil
            ),
            markdown: ""
        )
    }

    private func assertCheckerAccepts(
        _ memory: ComputerHistoryDayMemory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        struct Envelope: Encodable {
            let memory: ComputerHistoryDayMemory
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let input = try encoder.encode(Envelope(memory: memory))
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checker =
            repositoryRoot
            .appendingPathComponent("scripts/check_computer_history_memory.py")
        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: checker.path),
            "Checker is missing at \(checker.path)",
            file: file,
            line: line
        )

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", checker.path, "-", "--quiet-errors"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        standardInput.fileHandleForWriting.write(input)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: error + output, encoding: .utf8) ?? "Checker failed",
            file: file,
            line: line
        )
    }
}
