import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistoryBuilderPerformanceParityTests: XCTestCase {
    func testLargeDayStatusInferenceUsesFullSanitizedSemanticWindow() throws {
        let application = fixtureApp("Terminal")
        let interactionID = "late-status-interaction"
        let leadingText = String(repeating: "x", count: 1_100)
        let completionLine = "Deployment completed successfully"
        let afterText = leadingText + "\n" + completionLine
        let completionOffset = try XCTUnwrap(afterText.range(of: completionLine)).lowerBound
        XCTAssertGreaterThan(afterText.distance(from: afterText.startIndex, to: completionOffset), 1_000)

        let before = semanticPayload(
            id: "late-status-before",
            text: leadingText,
            offset: 1,
            application: application
        )
        let after = semanticPayload(
            id: "late-status-after",
            text: afterText,
            offset: 3,
            application: application
        )
        let semanticSnapshots = [before.id: before, after.id: after]
        let scenarioEvents = [
            fixtureEvent(
                id: "late-status-before-event",
                sequence: 1,
                offset: 1,
                kind: .semanticSnapshot,
                app: application,
                windowTitle: nil,
                host: nil,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ],
                semanticContext: before.reference
            ),
            fixtureEvent(
                id: "late-status-action",
                sequence: 2,
                offset: 2,
                kind: .typingBurst,
                app: application,
                windowTitle: nil,
                host: nil,
                metadata: [ComputerHistoryMetadata.interactionID: interactionID],
                keyboard: KeyboardSnapshot(
                    category: "text_activity",
                    key: nil,
                    modifiers: [],
                    isRepeat: false
                )
            ),
            fixtureEvent(
                id: "late-status-after-event",
                sequence: 3,
                offset: 3,
                kind: .semanticSnapshot,
                app: application,
                windowTitle: nil,
                host: nil,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ],
                semanticContext: after.reference
            ),
        ]
        let fillerEvents = (0..<1_022).map { index in
            fixtureEvent(
                id: "late-status-filler-\(index)",
                sequence: UInt64(index + 4),
                offset: TimeInterval(index + 100),
                kind: .semanticSnapshot,
                app: application,
                windowTitle: nil,
                host: nil
            )
        }
        let largeEvents = scenarioEvents + fillerEvents
        XCTAssertEqual(largeEvents.count, 1_025)

        let smallMemory = ComputerHistoryEngine.analyze(
            events: scenarioEvents,
            semanticSnapshots: semanticSnapshots,
            day: fixtureStart,
            generatedAt: fixtureStart
        )
        let largeMemory = ComputerHistoryEngine.analyze(
            events: largeEvents,
            semanticSnapshots: semanticSnapshots,
            day: fixtureStart,
            generatedAt: fixtureStart
        )
        let smallEpisode = try XCTUnwrap(smallMemory.episodes.first)
        let largeEpisode = try XCTUnwrap(largeMemory.episodes.first)
        let largeInteraction = try XCTUnwrap(largeEpisode.interactions.first)

        XCTAssertEqual(smallEpisode.status, .completed)
        XCTAssertEqual(largeEpisode.status, smallEpisode.status)
        XCTAssertEqual(largeMemory.coverage.sourceEventCount, 1_025)
        XCTAssertFalse(largeInteraction.afterContext?.contains(completionLine) ?? true)
        XCTAssertTrue(largeInteraction.semanticDelta.contains(completionLine))

        var resolution = ComputerHistoryResourceResolver.resolve(
            events: largeEvents,
            semanticSnapshots: semanticSnapshots
        )
        let transferredSemanticTexts = resolution.takeInteractionSemanticTexts()
        XCTAssertEqual(transferredSemanticTexts.count, largeEvents.count)
        XCTAssertEqual(transferredSemanticTexts[2], afterText)
        XCTAssertTrue(resolution.interactionSemanticTexts.isEmpty)
    }

    func testResourceResolutionUsesIdentifierAsDeterministicFinalTieBreak() {
        let events = [
            fixtureEvent(
                id: "same-time-page-z",
                sequence: 1,
                offset: 0,
                kind: .windowChanged,
                windowTitle: "Shared page title",
                host: "z.example"
            ),
            fixtureEvent(
                id: "same-time-page-a",
                sequence: 2,
                offset: 0,
                kind: .windowChanged,
                windowTitle: "Shared page title",
                host: "a.example"
            ),
        ]

        let first = ComputerHistoryResourceResolver.resolve(
            events: events,
            semanticSnapshots: [:]
        ).resources.filter { $0.kind == .webPage }
        let second = ComputerHistoryResourceResolver.resolve(
            events: Array(events.reversed()),
            semanticSnapshots: [:]
        ).resources.filter { $0.kind == .webPage }

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(Set(first.map(\.id)).count, 2)
        XCTAssertEqual(first.map(\.firstSeen), [fixtureStart, fixtureStart])
        XCTAssertEqual(first.map(\.title), ["Shared page title", "Shared page title"])
        XCTAssertEqual(first.map(\.id), first.map(\.id).sorted())
        XCTAssertEqual(second, first)
    }

    func testWorkflowFeaturePrecomputationHandlesManyDistinctClustersDeterministically() {
        let episodes = (0..<750).map { index -> ComputerHistoryEpisode in
            let start = fixtureStart.addingTimeInterval(TimeInterval(index * 10))
            let application = "Distinct application \(index)"
            let interactions = [
                ComputerHistoryActionKind.click,
                .typing,
                .shortcut,
            ].enumerated().map { offset, action in
                ComputerHistoryInteraction(
                    id: "workflow-interaction-\(index)-\(offset)",
                    start: start.addingTimeInterval(TimeInterval(offset)),
                    end: start.addingTimeInterval(TimeInterval(offset) + 0.5),
                    action: action,
                    label: "\(action.rawValue) \(index)",
                    application: application,
                    bundleIdentifier: "example.distinct.\(index)",
                    host: nil,
                    resourceIDs: [],
                    beforeContext: nil,
                    afterContext: nil,
                    semanticDelta: [],
                    confidence: 1,
                    provenance: ActivityProvenance(
                        sourceEventIDs: ["workflow-event-\(index)-\(offset)"],
                        sourceSequences: [UInt64(index * 3 + offset + 1)],
                        sourceEventHashes: []
                    )
                )
            }
            return ComputerHistoryEpisode(
                id: "workflow-episode-\(index)",
                start: start,
                end: start.addingTimeInterval(3),
                title: "Distinct workflow title \(index)",
                summary: "Distinct workflow summary \(index)",
                status: .inProgress,
                statusConfidence: 0.8,
                applications: [application],
                sites: [],
                resourceIDs: [],
                requestsOrIntentions: [],
                observableOutcomes: [],
                interactions: interactions,
                eventCount: interactions.count,
                semanticSnapshotCount: 0,
                workflowFingerprint: "distinct-workflow-\(index)",
                provenance: .none
            )
        }

        let first = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: episodes,
            priorMemories: []
        )
        let second = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: episodes,
            priorMemories: []
        )

        XCTAssertTrue(first.patterns.isEmpty)
        XCTAssertTrue(first.suggestions.isEmpty)
        XCTAssertEqual(first.patterns, second.patterns)
        XCTAssertEqual(first.suggestions, second.suggestions)
    }

    func testPreTokenizedSemanticDeltaMatchesPairwiseReference() {
        let before = [
            "Open Goalong History settings",
            "Build finished successfully",
            "Résumé déjà présent",
            "short",
        ].joined(separator: "\n")
        let after = [
            "Open Goalong History settings",
            "Build finished successfully!",
            "Résumé deja present",
            "ab",
            "First new observable line",
            "Second new observable line",
            "Third new observable line",
            "Fourth new observable line",
            "Fifth new observable line",
            "Sixth new observable line",
            "Seventh new observable line",
            "Eighth new observable line",
            "Ninth new observable line",
            "Tenth new observable line",
            "Eleventh line cannot affect the bounded result",
        ].joined(separator: "\n")

        XCTAssertEqual(
            ComputerHistorySupport.semanticDelta(before: before, after: after),
            referenceSemanticDelta(before: before, after: after)
        )
    }

    func testIndexedNeighborLookupMatchesNaiveReference() {
        let applications = [
            AppSnapshot(name: "Browser", bundleIdentifier: "com.example.browser", processIdentifier: 1),
            AppSnapshot(name: "Browser", bundleIdentifier: nil, processIdentifier: 2),
            AppSnapshot(name: "Browser", bundleIdentifier: "com.example.other", processIdentifier: 3),
            AppSnapshot(name: "Editor", bundleIdentifier: nil, processIdentifier: 4),
        ]
        var events: [HistoryEvent] = []
        var snapshots: [String: SemanticContextPayload] = [:]
        var resourceIDs: [String: [String]] = [:]

        for index in 0..<160 {
            let application = applications[index % applications.count]
            let actionID = "action-\(index)"
            let actionOffset = TimeInterval(index * 25 + 10)
            let usesExplicitLink = index.isMultiple(of: 11)
            let interactionID = usesExplicitLink ? "linked-\(index)" : nil
            let actionMetadata = interactionID.map {
                [ComputerHistoryMetadata.interactionID: $0]
            }

            let beforePayload = semanticPayload(
                id: "before-payload-\(index)",
                text: "Before state \(index)",
                offset: actionOffset - 1,
                application: application
            )
            let afterPayload = semanticPayload(
                id: "after-payload-\(index)",
                text: "Before state \(index)\nAfter state \(index)",
                offset: actionOffset + 1,
                application: application
            )
            snapshots[beforePayload.id] = beforePayload
            snapshots[afterPayload.id] = afterPayload

            let beforeMetadata = interactionID.map {
                [
                    ComputerHistoryMetadata.interactionID: $0,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ]
            }
            let afterMetadata = interactionID.map {
                [
                    ComputerHistoryMetadata.interactionID: $0,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            }
            let beforeEvent = fixtureEvent(
                id: "z-before-\(index)",
                sequence: UInt64(index * 4 + 1),
                offset: actionOffset - 1,
                kind: .semanticSnapshot,
                app: application,
                metadata: beforeMetadata,
                semanticContext: beforePayload.reference
            )
            let actionEvent = fixtureEvent(
                id: actionID,
                sequence: UInt64(index * 4 + 2),
                offset: actionOffset,
                kind: .mouseClick,
                app: application,
                metadata: actionMetadata,
                pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
            )
            let afterEvent = fixtureEvent(
                id: "z-after-\(index)",
                sequence: UInt64(index * 4 + 3),
                offset: actionOffset + 1,
                kind: .semanticSnapshot,
                app: application,
                metadata: afterMetadata,
                semanticContext: afterPayload.reference
            )

            // Deliberately append out of order; both implementations must use the
            // deterministic event ordering rather than input order.
            events.append(contentsOf: [actionEvent, afterEvent, beforeEvent])
            resourceIDs[actionID] = ["direct-\(index)"]
            resourceIDs[beforeEvent.id] = ["before-\(index)"]
            resourceIDs[afterEvent.id] = ["after-\(index)"]

            if index.isMultiple(of: 13), !usesExplicitLink {
                let tiePayload = semanticPayload(
                    id: "tie-payload-\(index)",
                    text: "Lexicographically first tied context \(index)",
                    offset: actionOffset - 1,
                    application: application
                )
                snapshots[tiePayload.id] = tiePayload
                events.append(
                    fixtureEvent(
                        id: "a-before-\(index)",
                        sequence: UInt64(index * 4 + 4),
                        offset: actionOffset - 1,
                        kind: .semanticSnapshot,
                        app: application,
                        semanticContext: tiePayload.reference
                    )
                )
            }
        }

        let expected = naiveInteractionBuild(
            events: events,
            semanticSnapshots: snapshots,
            eventResourceIDs: resourceIDs
        )
        let actual = ComputerHistoryInteractionBuilder.build(
            events: events,
            semanticSnapshots: snapshots,
            eventResourceIDs: resourceIDs
        )

        XCTAssertEqual(actual, expected)

        let orderedEvents = events.sorted(by: ComputerHistorySupport.eventOrder)
        let resolution = ComputerHistoryResourceResolver.resolve(
            events: orderedEvents,
            semanticSnapshots: snapshots
        )
        XCTAssertEqual(
            ComputerHistoryInteractionBuilder.build(
                events: orderedEvents,
                semanticSnapshots: snapshots,
                eventResourceIDs: resourceIDs,
                precomputedSemanticTexts: resolution.interactionSemanticTexts
            ),
            ComputerHistoryInteractionBuilder.build(
                events: orderedEvents,
                semanticSnapshots: snapshots,
                eventResourceIDs: resourceIDs
            )
        )
    }

    func testIndexedLookupPreservesFirstDuplicateTimestampAndIdentifier() {
        let bundled = AppSnapshot(
            name: "Browser",
            bundleIdentifier: "com.example.browser",
            processIdentifier: 1
        )
        let unbundled = AppSnapshot(
            name: "Browser",
            bundleIdentifier: nil,
            processIdentifier: 2
        )
        let payloads = [
            semanticPayload(
                id: "unbundled-before",
                text: "Unbundled before",
                offset: 9,
                application: unbundled
            ),
            semanticPayload(
                id: "bundled-before",
                text: "Bundled before",
                offset: 9,
                application: bundled
            ),
            semanticPayload(
                id: "unbundled-after",
                text: "Unbundled after",
                offset: 11,
                application: unbundled
            ),
            semanticPayload(
                id: "bundled-after",
                text: "Bundled after",
                offset: 11,
                application: bundled
            ),
        ]
        let snapshots = Dictionary(uniqueKeysWithValues: payloads.map { ($0.id, $0) })
        let events = [
            fixtureEvent(
                id: "duplicate-before",
                sequence: 1,
                offset: 9,
                kind: .semanticSnapshot,
                app: unbundled,
                semanticContext: payloads[0].reference
            ),
            fixtureEvent(
                id: "duplicate-before",
                sequence: 2,
                offset: 9,
                kind: .semanticSnapshot,
                app: bundled,
                semanticContext: payloads[1].reference
            ),
            fixtureEvent(
                id: "duplicate-action",
                sequence: 3,
                offset: 10,
                kind: .mouseClick,
                app: bundled,
                pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
            ),
            fixtureEvent(
                id: "duplicate-after",
                sequence: 4,
                offset: 11,
                kind: .semanticSnapshot,
                app: unbundled,
                semanticContext: payloads[2].reference
            ),
            fixtureEvent(
                id: "duplicate-after",
                sequence: 5,
                offset: 11,
                kind: .semanticSnapshot,
                app: bundled,
                semanticContext: payloads[3].reference
            ),
        ]

        XCTAssertEqual(
            ComputerHistoryInteractionBuilder.build(
                events: events,
                semanticSnapshots: snapshots,
                eventResourceIDs: [:]
            ),
            naiveInteractionBuild(
                events: events,
                semanticSnapshots: snapshots,
                eventResourceIDs: [:]
            )
        )
    }

    func testIndexedNeighborLookupHandlesHighVolumeDeterministically() {
        let applications = (0..<4).map {
            AppSnapshot(
                name: "Application-\($0)",
                bundleIdentifier: "com.example.application-\($0)",
                processIdentifier: Int32($0 + 1)
            )
        }
        var events: [HistoryEvent] = []
        var snapshots: [String: SemanticContextPayload] = [:]
        events.reserveCapacity(6_000)
        snapshots.reserveCapacity(4_000)

        for index in 0..<2_000 {
            let application = applications[index % applications.count]
            let actionOffset = TimeInterval(index * 5 + 2)
            let before = semanticPayload(
                id: "volume-before-\(index)",
                text: "Before \(index)",
                offset: actionOffset - 1,
                application: application
            )
            let after = semanticPayload(
                id: "volume-after-\(index)",
                text: "Before \(index)\nAfter \(index)",
                offset: actionOffset + 1,
                application: application
            )
            snapshots[before.id] = before
            snapshots[after.id] = after
            events.append(
                fixtureEvent(
                    id: "volume-before-event-\(index)",
                    sequence: UInt64(index * 3 + 1),
                    offset: actionOffset - 1,
                    kind: .semanticSnapshot,
                    app: application,
                    semanticContext: before.reference
                )
            )
            events.append(
                fixtureEvent(
                    id: "volume-action-\(index)",
                    sequence: UInt64(index * 3 + 2),
                    offset: actionOffset,
                    kind: .typingBurst,
                    app: application,
                    keyboard: KeyboardSnapshot(
                        category: "text_activity",
                        key: nil,
                        modifiers: [],
                        isRepeat: false
                    )
                )
            )
            events.append(
                fixtureEvent(
                    id: "volume-after-event-\(index)",
                    sequence: UInt64(index * 3 + 3),
                    offset: actionOffset + 1,
                    kind: .semanticSnapshot,
                    app: application,
                    semanticContext: after.reference
                )
            )
        }

        let first = ComputerHistoryInteractionBuilder.build(
            events: events,
            semanticSnapshots: snapshots,
            eventResourceIDs: [:]
        )
        let second = ComputerHistoryInteractionBuilder.build(
            events: events,
            semanticSnapshots: snapshots,
            eventResourceIDs: [:]
        )

        XCTAssertEqual(first.count, 2_000)
        XCTAssertTrue(first.allSatisfy { $0.beforeContext != nil && $0.afterContext != nil })
        XCTAssertEqual(second, first)
    }

    func testNeighborLookupIncludesExactTwentySecondBoundaries() {
        let application = fixtureApp("BoundaryApp")
        let before = semanticPayload(
            id: "boundary-before",
            text: "Exactly twenty seconds before",
            offset: 80,
            application: application
        )
        let after = semanticPayload(
            id: "boundary-after",
            text: "Exactly twenty seconds after",
            offset: 120,
            application: application
        )
        let outsideBefore = semanticPayload(
            id: "outside-before",
            text: "More than twenty seconds before",
            offset: 79.999,
            application: application
        )
        let outsideAfter = semanticPayload(
            id: "outside-after",
            text: "More than twenty seconds after",
            offset: 120.001,
            application: application
        )
        let payloads = [before, after, outsideBefore, outsideAfter]
        let snapshots = Dictionary(uniqueKeysWithValues: payloads.map { ($0.id, $0) })
        let events = [
            fixtureEvent(
                id: "outside-before-event",
                sequence: 1,
                offset: 79.999,
                kind: .semanticSnapshot,
                app: application,
                semanticContext: outsideBefore.reference
            ),
            fixtureEvent(
                id: "boundary-before-event",
                sequence: 2,
                offset: 80,
                kind: .semanticSnapshot,
                app: application,
                semanticContext: before.reference
            ),
            fixtureEvent(
                id: "boundary-action",
                sequence: 3,
                offset: 100,
                kind: .mouseClick,
                app: application,
                pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
            ),
            fixtureEvent(
                id: "boundary-after-event",
                sequence: 4,
                offset: 120,
                kind: .semanticSnapshot,
                app: application,
                semanticContext: after.reference
            ),
            fixtureEvent(
                id: "outside-after-event",
                sequence: 5,
                offset: 120.001,
                kind: .semanticSnapshot,
                app: application,
                semanticContext: outsideAfter.reference
            ),
        ]

        let interaction = try! XCTUnwrap(
            ComputerHistoryInteractionBuilder.build(
                events: events,
                semanticSnapshots: snapshots,
                eventResourceIDs: [:]
            ).first
        )

        XCTAssertEqual(interaction.beforeContext, before.text)
        XCTAssertEqual(interaction.afterContext, after.text)
    }

    func testEpisodeIndexMatchesNaiveEventFilteringAtVolume() {
        var interactions: [ComputerHistoryInteraction] = []
        var events: [HistoryEvent] = []
        interactions.reserveCapacity(500)
        events.reserveCapacity(2_000)

        for index in 0..<500 {
            let offset = TimeInterval(index * 180)
            let before = fixtureEvent(
                id: "episode-before-\(index)",
                sequence: UInt64(index * 4 + 1),
                offset: offset - 1,
                kind: .semanticSnapshot,
                windowTitle: "Before \(index)"
            )
            let action = fixtureEvent(
                id: "episode-action-\(index)",
                sequence: UInt64(index * 4 + 2),
                offset: offset,
                kind: .mouseClick,
                windowTitle: "Action \(index)",
                pointer: PointerSnapshot(button: "left", x: 10, y: 20, clickCount: 1)
            )
            let after = fixtureEvent(
                id: "episode-after-\(index)",
                sequence: UInt64(index * 4 + 3),
                offset: offset + 0.5,
                kind: .semanticSnapshot,
                windowTitle: "After \(index)"
            )
            let context = fixtureEvent(
                id: "episode-context-\(index)",
                sequence: UInt64(index * 4 + 4),
                offset: offset + 0.75,
                kind: .diagnostic,
                windowTitle: "Context \(index)"
            )
            events.append(contentsOf: [before, action, after, context])
            interactions.append(
                makeInteraction(
                    id: "episode-interaction-\(index)",
                    start: fixtureStart.addingTimeInterval(offset),
                    end: fixtureStart.addingTimeInterval(offset + 0.5),
                    host: "site-\(index).example",
                    provenanceEvents: [before, action]
                )
            )
        }

        // Exercise preservation of the caller's original order. A separate long-
        // episode case below covers the normal chronological fast path.
        events.reverse()
        let episodes = ComputerHistoryEpisodeBuilder.build(
            interactions: interactions,
            events: events,
            resources: []
        )

        XCTAssertEqual(episodes.count, interactions.count)
        for episode in episodes {
            let sourceIDs = Set(episode.interactions.flatMap { $0.provenance.sourceEventIDs })
            let sourceSequences = Set(
                episode.interactions.flatMap { $0.provenance.sourceSequences }
            )
            let naiveEvents = events.filter { event in
                sourceIDs.contains(event.id)
                    || event.integrity.map { sourceSequences.contains($0.sequence) } == true
                    || (event.timestamp >= episode.start
                        && event.timestamp <= episode.end.addingTimeInterval(1))
            }
            XCTAssertEqual(episode.eventCount, naiveEvents.count)
            XCTAssertEqual(
                episode.semanticSnapshotCount,
                naiveEvents.filter { $0.kind == .semanticSnapshot }.count
            )
            XCTAssertEqual(
                episode.provenance,
                ComputerHistorySupport.provenance(for: naiveEvents)
            )
        }
    }

    func testSimultaneousOverlappingEpisodesKeepDistinctStableIdentifiers() {
        let interactions = [
            makeInteraction(
                id: "simultaneous-first",
                start: fixtureStart,
                end: fixtureStart.addingTimeInterval(3),
                host: "same.example",
                provenanceEvents: []
            ),
            makeInteraction(
                id: "simultaneous-second",
                start: fixtureStart,
                end: fixtureStart.addingTimeInterval(3),
                host: "same.example",
                provenanceEvents: []
            ),
        ]

        let first = ComputerHistoryEpisodeBuilder.build(
            interactions: interactions,
            events: [],
            resources: []
        )
        let second = ComputerHistoryEpisodeBuilder.build(
            interactions: interactions,
            events: [],
            resources: []
        )

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
        XCTAssertEqual(first.map(\.start), [fixtureStart, fixtureStart])
    }

    func testEpisodeIndexUsesInclusiveWindowAndIndependentProvenanceKeys() {
        let idOnly = fixtureEvent(
            id: "id-only",
            sequence: 1,
            offset: 0,
            kind: .diagnostic,
            windowTitle: nil
        ).replacingIntegrity(nil)
        let beforeWindow = fixtureEvent(
            id: "before-window",
            sequence: 2,
            offset: 9.999,
            kind: .diagnostic,
            windowTitle: nil
        )
        let atStart = fixtureEvent(
            id: "at-start",
            sequence: 3,
            offset: 10,
            kind: .diagnostic,
            windowTitle: nil
        )
        let atEndPlusOne = fixtureEvent(
            id: "at-end-plus-one",
            sequence: 4,
            offset: 21,
            kind: .diagnostic,
            windowTitle: nil
        )
        let afterWindow = fixtureEvent(
            id: "after-window",
            sequence: 5,
            offset: 21.001,
            kind: .diagnostic,
            windowTitle: nil
        )
        let sequenceOnly = fixtureEvent(
            id: "sequence-only",
            sequence: 777,
            offset: 30,
            kind: .diagnostic,
            windowTitle: nil
        )
        let provenance = ActivityProvenance(
            sourceEventIDs: [idOnly.id],
            sourceSequences: [777],
            sourceEventHashes: []
        )
        let interaction = makeInteraction(
            id: "inclusive-window",
            start: fixtureStart.addingTimeInterval(10),
            end: fixtureStart.addingTimeInterval(20),
            host: "same.example",
            provenanceEvents: [],
            provenance: provenance
        )

        let episode = try! XCTUnwrap(
            ComputerHistoryEpisodeBuilder.build(
                interactions: [interaction],
                events: [
                    idOnly,
                    beforeWindow,
                    atStart,
                    atEndPlusOne,
                    afterWindow,
                    sequenceOnly,
                ],
                resources: []
            ).first
        )

        XCTAssertEqual(episode.eventCount, 4)
        XCTAssertEqual(
            episode.provenance.sourceEventIDs,
            [idOnly.id, atStart.id, atEndPlusOne.id, sequenceOnly.id]
        )
    }

    func testEpisodeIndexPreservesContextOrderAndChronologicalFastPath() {
        let interaction = makeInteraction(
            id: "order-sensitive",
            start: fixtureStart,
            end: fixtureStart.addingTimeInterval(10),
            host: "same.example",
            provenanceEvents: []
        )
        let completed = fixtureEvent(
            id: "completed",
            sequence: 4,
            offset: 9,
            kind: .diagnostic,
            windowTitle: nil,
            message: "Deployment completed successfully"
        )
        let neutral = (1...3).map { index in
            fixtureEvent(
                id: "neutral-\(index)",
                sequence: UInt64(index),
                offset: TimeInterval(index),
                kind: .diagnostic,
                windowTitle: nil,
                message: index == 3
                    ? "Deployment failed with error"
                    : "Neutral observation \(index)"
            )
        }

        let originalOrderEpisode = try! XCTUnwrap(
            ComputerHistoryEpisodeBuilder.build(
                interactions: [interaction],
                events: [completed] + neutral,
                resources: []
            ).first
        )
        let chronologicalEpisode = try! XCTUnwrap(
            ComputerHistoryEpisodeBuilder.build(
                interactions: [interaction],
                events: neutral + [completed],
                resources: []
            ).first
        )

        XCTAssertEqual(originalOrderEpisode.status, .blocked)
        XCTAssertEqual(chronologicalEpisode.status, .completed)
    }

    func testEpisodeIndexHandlesOneLongChronologicalEpisodeAtVolume() {
        let eventCount = 5_000
        let events = (0..<eventCount).map { index in
            fixtureEvent(
                id: "long-episode-\(index)",
                sequence: UInt64(index + 1),
                offset: TimeInterval(index),
                kind: .diagnostic,
                windowTitle: nil
            )
        }
        let interaction = makeInteraction(
            id: "long-episode",
            start: fixtureStart,
            end: fixtureStart.addingTimeInterval(TimeInterval(eventCount - 1)),
            host: "same.example",
            provenanceEvents: []
        )

        let episode = try! XCTUnwrap(
            ComputerHistoryEpisodeBuilder.build(
                interactions: [interaction],
                events: events,
                resources: []
            ).first
        )

        XCTAssertEqual(episode.eventCount, eventCount)
        XCTAssertEqual(episode.provenance.sourceEventIDs.count, eventCount)
    }

    func testSuppressionLookupKeepsStrictBoundarySemantics() {
        let interactions = (0..<3).map { index in
            makeInteraction(
                id: "boundary-\(index)",
                start: fixtureStart.addingTimeInterval(TimeInterval(index * 10)),
                end: fixtureStart.addingTimeInterval(TimeInterval(index * 10)),
                host: "same.example",
                provenanceEvents: []
            )
        }
        let events = [
            fixtureEvent(
                id: "suppressed-at-previous-end",
                sequence: 1,
                offset: 0,
                kind: .captureSuppressed,
                suppression: .manualPause
            ),
            fixtureEvent(
                id: "suppressed-at-next-start",
                sequence: 2,
                offset: 10,
                kind: .captureSuppressed,
                suppression: .manualPause
            ),
            fixtureEvent(
                id: "suppressed-strictly-between",
                sequence: 3,
                offset: 15,
                kind: .captureSuppressed,
                suppression: .manualPause
            ),
        ]

        let episodes = ComputerHistoryEpisodeBuilder.build(
            interactions: interactions,
            events: events,
            resources: []
        )

        XCTAssertEqual(
            episodes.map { $0.interactions.map(\.id) },
            [
                ["boundary-0", "boundary-1"],
                ["boundary-2"],
            ])
    }

    private struct ReferenceObservation {
        let event: HistoryEvent
        let text: String
        let interactionID: String?
        let phase: String?
    }

    private func referenceSemanticDelta(before: String?, after: String?) -> [String] {
        guard let after else { return [] }
        let beforeLines = ComputerHistorySupport.splitSemanticLines(before ?? "")
        let candidates = ComputerHistorySupport.splitSemanticLines(after).filter { line in
            !beforeLines.contains(where: {
                ComputerHistorySupport.tokenSimilarity([$0], [line]) >= 0.88
            })
        }
        return Array(candidates.filter { $0.count >= 3 }.prefix(10))
    }

    /// The pre-index implementation retained as a small fixture oracle.
    private func naiveInteractionBuild(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload],
        eventResourceIDs: [String: [String]]
    ) -> [ComputerHistoryInteraction] {
        let ordered = events.sorted(by: ComputerHistorySupport.eventOrder)
        let observations = ordered.compactMap { event -> ReferenceObservation? in
            guard
                let text = ComputerHistorySupport.semanticText(
                    for: event,
                    semanticSnapshots: semanticSnapshots
                )
            else { return nil }
            return ReferenceObservation(
                event: event,
                text: ComputerHistorySupport.bounded(text, maximum: 6_000),
                interactionID: event.metadata?[ComputerHistoryMetadata.interactionID],
                phase: event.metadata?[ComputerHistoryMetadata.interactionPhase]
            )
        }
        var linked: [String: [ReferenceObservation]] = [:]
        for observation in observations {
            guard let interactionID = observation.interactionID else { continue }
            linked[interactionID, default: []].append(observation)
        }

        var output: [ComputerHistoryInteraction] = []
        for event in ordered where ComputerHistorySupport.isActionEvent(event) {
            let interactionID = event.metadata?[ComputerHistoryMetadata.interactionID] ?? event.id
            let explicit = (linked[interactionID] ?? [])
                .filter { ComputerHistorySupport.sameApplication($0.event, event) }
                .sorted { $0.event.timestamp < $1.event.timestamp }
            let before =
                explicit.last {
                    $0.phase == ComputerHistoryMetadata.Phase.before
                }
                ?? observations
                .filter {
                    $0.event.timestamp <= event.timestamp
                        && event.timestamp.timeIntervalSince($0.event.timestamp) <= 20
                        && ComputerHistorySupport.sameApplication($0.event, event)
                }
                .max { $0.event.timestamp < $1.event.timestamp }
            let settled = explicit.last {
                $0.phase == ComputerHistoryMetadata.Phase.settled
                    && $0.event.timestamp >= event.timestamp
            }
            let after =
                settled
                ?? explicit.last {
                    $0.phase == ComputerHistoryMetadata.Phase.after
                        && $0.event.timestamp >= event.timestamp
                }
                ?? observations
                .filter {
                    $0.event.timestamp >= event.timestamp
                        && $0.event.timestamp.timeIntervalSince(event.timestamp) <= 20
                        && ComputerHistorySupport.sameApplication($0.event, event)
                }
                .min { $0.event.timestamp < $1.event.timestamp }

            let beforeText = before?.text
            let afterText = after?.text
            let explicitDelta =
                event.metadata?[ComputerHistoryMetadata.semanticDelta]
                .map(ComputerHistorySupport.splitSemanticLines) ?? []
            let delta =
                explicitDelta.isEmpty
                ? ComputerHistorySupport.semanticDelta(before: beforeText, after: afterText)
                : explicitDelta
            let linkedEvents = ComputerHistorySupport.distinctEvents(
                [event] + [before?.event, after?.event].compactMap { $0 }
            )
            let directResources = eventResourceIDs[event.id] ?? []
            let contextualResources = [before?.event.id, after?.event.id]
                .compactMap { $0 }
                .flatMap { eventResourceIDs[$0] ?? [] }
            let confidence: Double
            if beforeText != nil && afterText != nil {
                confidence = 0.98
            } else if beforeText != nil || afterText != nil {
                confidence = 0.82
            } else {
                confidence = 0.66
            }

            output.append(
                ComputerHistoryInteraction(
                    id: ComputerHistorySupport.stableIdentifier("interaction|\(interactionID)"),
                    start: event.timestamp,
                    end: max(event.timestamp, after?.event.timestamp ?? event.timestamp),
                    action: ComputerHistorySupport.actionKind(for: event),
                    label: ComputerHistorySupport.actionLabel(for: event),
                    application: event.app?.name,
                    bundleIdentifier: event.app?.bundleIdentifier,
                    host: ComputerHistorySupport.normalizedHost(event.url?.host),
                    resourceIDs: ComputerHistorySupport.distinct(
                        directResources + contextualResources
                    ),
                    beforeContext: beforeText.map {
                        ComputerHistorySupport.bounded($0, maximum: 1_800)
                    },
                    afterContext: afterText.map {
                        ComputerHistorySupport.bounded($0, maximum: 1_800)
                    },
                    semanticDelta: Array(
                        delta.map {
                            ComputerHistorySupport.bounded($0, maximum: 500)
                        }.prefix(10)
                    ),
                    confidence: confidence,
                    provenance: ComputerHistorySupport.provenance(for: linkedEvents)
                )
            )
        }
        return output.sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return $0.start < $1.start
        }
    }

    private func semanticPayload(
        id: String,
        text: String,
        offset: TimeInterval,
        application: AppSnapshot
    ) -> SemanticContextPayload {
        SemanticContextPayload(
            id: id,
            capturedAt: fixtureStart.addingTimeInterval(offset),
            application: application,
            window: WindowSnapshot(title: "Context", role: "AXWindow", subrole: nil),
            url: nil,
            focusedRole: "AXButton",
            source: .mixed,
            text: text,
            contentSHA256: SHA256Digest.hashHex(text),
            redacted: false,
            truncated: false
        )
    }

    private func makeInteraction(
        id: String,
        start: Date,
        end: Date,
        host: String,
        provenanceEvents: [HistoryEvent],
        provenance: ActivityProvenance? = nil
    ) -> ComputerHistoryInteraction {
        ComputerHistoryInteraction(
            id: id,
            start: start,
            end: end,
            action: .click,
            label: "Clicked \(id)",
            application: "Safari",
            bundleIdentifier: "com.apple.Safari",
            host: host,
            resourceIDs: [],
            beforeContext: nil,
            afterContext: nil,
            semanticDelta: ["Changed \(id)"],
            confidence: 0.9,
            provenance: provenance
                ?? ComputerHistorySupport.provenance(for: provenanceEvents)
        )
    }
}
