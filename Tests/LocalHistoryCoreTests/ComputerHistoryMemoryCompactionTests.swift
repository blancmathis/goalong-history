import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistoryMemoryCompactionTests: XCTestCase {
    func testResourceResolutionBoundsRepeatedProvenanceBeforeProjection() throws {
        let actionCount = 4_096
        var events: [HistoryEvent] = []
        events.reserveCapacity(actionCount)
        for index in 0..<actionCount {
            events.append(
                fixtureEvent(
                    id: "shared-resource-action-\(index)",
                    sequence: UInt64(index + 1),
                    offset: TimeInterval(index),
                    kind: .mouseClick,
                    windowTitle: "Shared resource",
                    host: "shared-resource.example"
                )
            )
        }

        let resolution = ComputerHistoryResourceResolver.resolve(
            events: events,
            semanticSnapshots: [:]
        )

        XCTAssertEqual(resolution.resources.count, 1)
        XCTAssertEqual(resolution.eventResourceIDs.count, actionCount)
        let resource = try XCTUnwrap(resolution.resources.first)
        XCTAssertTrue(
            resolution.eventResourceIDs.values.allSatisfy {
                $0 == [resource.id]
            }
        )
        XCTAssertEqual(
            resource.provenance.sourceEventIDs,
            [0, 1, 2, 3, 4_092, 4_093, 4_094, 4_095].map {
                "shared-resource-action-\($0)"
            }
        )
        XCTAssertEqual(
            resource.provenance.sourceSequences,
            [1, 2, 3, 4, 4_093, 4_094, 4_095, 4_096]
        )
        XCTAssertEqual(resource.provenance.sourceEventHashes.count, 8)
        XCTAssertEqual(resource.firstSeen, events.first?.timestamp)
        XCTAssertEqual(resource.lastSeen, events.last?.timestamp)
    }

    func testTenThousandActionsProduceBoundedRepresentativeMemoryWithExactCoverage() throws {
        let actionCount = 10_000
        let gapCount = 10
        var events: [HistoryEvent] = []
        events.reserveCapacity(actionCount + gapCount)
        var sequence: UInt64 = 1

        for index in 0..<actionCount {
            events.append(
                fixtureEvent(
                    id: "compact-action-\(index)",
                    sequence: sequence,
                    offset: TimeInterval(index * 2),
                    kind: .mouseClick,
                    windowTitle: "Editor state \(index)",
                    host: "resource-\(index).example",
                    metadata: [
                        ComputerHistoryMetadata.semanticDelta:
                            "Observable editor change \(index) "
                            + String(repeating: "payload-\(index)-", count: 24)
                    ],
                    pointer: PointerSnapshot(
                        button: "left",
                        x: Double(index % 1_440),
                        y: Double(index % 900),
                        clickCount: 1
                    )
                )
            )
            sequence += 1
            if (index + 1).isMultiple(of: 1_000) {
                events.append(
                    fixtureEvent(
                        id: "compact-gap-\(index)",
                        sequence: sequence,
                        offset: TimeInterval(index * 2) + 0.5,
                        kind: .captureSuppressed,
                        app: nil,
                        windowTitle: nil,
                        host: nil,
                        suppression: .manualPause
                    )
                )
                sequence += 1
            }
        }

        let startedAt = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: fixtureStart,
            calendar: calendar,
            generatedAt: fixtureStart.addingTimeInterval(86_000)
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(memory.coverage.sourceEventCount, actionCount + gapCount)
        XCTAssertEqual(memory.coverage.actionEventCount, actionCount)
        XCTAssertEqual(memory.coverage.linkedInteractionCount, actionCount)
        XCTAssertEqual(memory.coverage.suppressedEventCount, gapCount)
        XCTAssertEqual(memory.coverage.resourceCount, actionCount)
        XCTAssertEqual(memory.coverage.episodeCount, memory.episodes.count)
        XCTAssertTrue(memory.coverage.usesRepresentativeProjection)

        let retainedInteractionCount = memory.episodes.reduce(0) {
            $0 + $1.interactions.count
        }
        let exactEpisodeInteractionCount = memory.episodes.reduce(0) {
            $0 + $1.totalInteractionCount
        }
        XCTAssertEqual(exactEpisodeInteractionCount, actionCount)
        XCTAssertEqual(
            memory.coverage.retainedInteractionCount,
            retainedInteractionCount
        )
        XCTAssertLessThanOrEqual(retainedInteractionCount, 640)
        XCTAssertEqual(memory.coverage.retainedResourceCount, memory.resources.count)
        XCTAssertLessThanOrEqual(memory.resources.count, 384)
        XCTAssertTrue(memory.episodes.allSatisfy { !$0.interactions.isEmpty })

        XCTAssertTrue(
            memory.resources.allSatisfy {
                $0.canonicalURI != nil || $0.localPath != nil
            }
        )
        XCTAssertTrue(
            memory.resources.allSatisfy {
                $0.provenance.sourceEventIDs.count <= 8
                    && $0.provenance.sourceSequences.count <= 8
                    && $0.provenance.sourceEventHashes.count <= 8
            }
        )
        for episode in memory.episodes {
            XCTAssertLessThanOrEqual(episode.provenance.sourceEventIDs.count, 16)
            for interaction in episode.interactions {
                XCTAssertLessThanOrEqual(interaction.provenance.sourceEventIDs.count, 4)
                XCTAssertLessThanOrEqual(interaction.resourceIDs.count, 4)
                XCTAssertLessThanOrEqual(interaction.semanticDelta.count, 3)
            }
        }

        var retainedTextCharacters = 0
        for episode in memory.episodes {
            for interaction in episode.interactions {
                retainedTextCharacters += interaction.label.count
                retainedTextCharacters += interaction.beforeContext?.count ?? 0
                retainedTextCharacters += interaction.afterContext?.count ?? 0
                for line in interaction.semanticDelta {
                    retainedTextCharacters += line.count
                }
            }
        }
        XCTAssertLessThan(retainedTextCharacters, 1_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(memory)
        XCTAssertLessThan(encoded.count, 5 * 1_024 * 1_024)

        print(
            "ComputerHistory compact-10k: bytes=\(encoded.count) "
                + "interactions=\(retainedInteractionCount)/\(actionCount) "
                + "resources=\(memory.resources.count)/\(actionCount) "
                + String(format: "seconds=%.3f", elapsed)
        )
    }

    func testFragmentedDayBoundsEpisodesWithoutLosingExactCoverage() throws {
        let actionCount = 600
        var events: [HistoryEvent] = []
        events.reserveCapacity(actionCount * 2)
        var sequence: UInt64 = 1

        for index in 0..<actionCount {
            events.append(
                fixtureEvent(
                    id: "fragmented-action-\(index)",
                    sequence: sequence,
                    offset: TimeInterval(index * 2),
                    kind: .mouseClick,
                    windowTitle: "Fragmented state \(index)",
                    host: "fragmented.example"
                )
            )
            sequence += 1
            events.append(
                fixtureEvent(
                    id: "fragmented-gap-\(index)",
                    sequence: sequence,
                    offset: TimeInterval(index * 2 + 1),
                    kind: .captureSuppressed,
                    app: nil,
                    windowTitle: nil,
                    host: nil,
                    suppression: .manualPause
                )
            )
            sequence += 1
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: fixtureStart,
            calendar: calendar,
            generatedAt: fixtureStart.addingTimeInterval(86_000)
        )

        XCTAssertEqual(memory.coverage.sourceEventCount, actionCount * 2)
        XCTAssertEqual(memory.coverage.actionEventCount, actionCount)
        XCTAssertEqual(memory.coverage.linkedInteractionCount, actionCount)
        XCTAssertEqual(memory.coverage.episodeCount, actionCount)
        XCTAssertEqual(memory.coverage.retainedEpisodeCount, memory.episodes.count)
        XCTAssertLessThanOrEqual(memory.episodes.count, 256)
        XCTAssertTrue(memory.episodes.allSatisfy { !$0.interactions.isEmpty })

        let retainedEpisodeIDs = Set(memory.episodes.map(\.id))
        XCTAssertTrue(
            memory.workflowPatterns.allSatisfy {
                Set($0.episodeIDs).isSubset(of: retainedEpisodeIDs)
            }
        )
        XCTAssertTrue(
            memory.suggestions.allSatisfy {
                Set($0.episodeIDs).isSubset(of: retainedEpisodeIDs)
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertLessThan(try encoder.encode(memory).count, 5 * 1_024 * 1_024)
    }
}
