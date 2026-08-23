import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryHardeningTests: XCTestCase {
    func testLegacyConfigMigratesToExclusionModeWithoutExpandingCapture() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(RecorderConfig.default))
                as? [String: Any]
        )
        object.removeValue(forKey: "applicationCaptureMode")
        object.removeValue(forKey: "websiteCaptureMode")
        object.removeValue(forKey: "includedBundleIdentifiers")
        object.removeValue(forKey: "includedDomains")

        let decoded = try decoder.decode(
            RecorderConfig.self,
            from: JSONSerialization.data(withJSONObject: object)
        ).validated()

        XCTAssertEqual(decoded.effectiveApplicationCaptureMode, .excludeListed)
        XCTAssertEqual(decoded.effectiveWebsiteCaptureMode, .excludeListed)
        XCTAssertTrue(decoded.effectiveIncludedBundleIdentifiers.isEmpty)
        XCTAssertTrue(decoded.effectiveIncludedDomains.isEmpty)
        XCTAssertTrue(decoded.allowsApplication(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertTrue(decoded.allowsWebsite(host: "example.com"))
    }

    func testApplicationAndWebsiteIncludeOnlyPoliciesAreIndependentAndFailClosed() {
        var config = RecorderConfig.default
        config.applicationCaptureMode = .includeOnly
        config.websiteCaptureMode = .includeOnly
        config.includedBundleIdentifiers = ["com.apple.Safari"]
        config.includedDomains = ["docs.example.com"]
        config.excludedBundleIdentifiers = []
        config.excludedDomains = []
        config = config.validated()

        XCTAssertTrue(config.allowsApplication(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(config.allowsApplication(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertFalse(config.allowsApplication(bundleIdentifier: nil))

        XCTAssertTrue(config.allowsWebsite(host: "docs.example.com"))
        XCTAssertTrue(config.allowsWebsite(host: "team.docs.example.com"))
        XCTAssertFalse(config.allowsWebsite(host: "mail.example.com"))
        XCTAssertFalse(config.allowsWebsite(host: nil))

        config.applicationCaptureMode = .excludeListed
        XCTAssertTrue(config.validated().allowsApplication(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertFalse(config.validated().allowsWebsite(host: "mail.example.com"))
    }

    func testNewInstallDefaultsDetailedEventsToFortyEightHours() {
        XCTAssertEqual(RecorderConfig.default.retentionDays, 2)
    }

    func testDelayedAfterSnapshotFromAnotherResourceInSameApplicationIsRejected() {
        let start = makeDate("2026-08-22T09:00:00Z")
        let safari = app("Safari", "com.apple.Safari")
        let interactionID = "click-before-resource-switch"
        let proposalURL = "https://docs.google.com/document/d/proposal/edit"
        let roadmapURL = "https://docs.google.com/document/d/roadmap/edit"
        let before = payload(
            id: "proposal-before",
            text: "Proposal before save",
            at: start,
            app: safari,
            URL: proposalURL
        )
        let wrongAfter = payload(
            id: "roadmap-after",
            text: "Roadmap from a newly focused document",
            at: start.addingTimeInterval(2),
            app: safari,
            URL: roadmapURL
        )
        let events = [
            event(
                id: "proposal-before-event",
                sequence: 1,
                at: start,
                kind: .semanticSnapshot,
                app: safari,
                title: "Proposal — Google Docs",
                URL: proposalURL,
                semanticContext: before.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.before,
                ]
            ),
            event(
                id: "proposal-click",
                sequence: 2,
                at: start.addingTimeInterval(1),
                kind: .mouseClick,
                app: safari,
                title: "Proposal — Google Docs",
                URL: proposalURL,
                pointer: PointerSnapshot(button: "left", x: 100, y: 80, clickCount: 1),
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionTrigger: "click",
                ]
            ),
            event(
                id: "roadmap-after-event",
                sequence: 3,
                at: start.addingTimeInterval(2),
                kind: .semanticSnapshot,
                app: safari,
                title: "Roadmap — Google Docs",
                URL: roadmapURL,
                semanticContext: wrongAfter.reference,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: ComputerHistoryMetadata.Phase.settled,
                ]
            ),
        ]

        let memory = ComputerHistoryEngine.analyze(
            events: events,
            semanticSnapshots: [
                before.id: before,
                wrongAfter.id: wrongAfter,
            ],
            day: start,
            calendar: utcCalendar
        )

        let interaction = try! XCTUnwrap(
            memory.episodes.flatMap(\.interactions)
                .first(where: { $0.provenance.sourceEventIDs.contains("proposal-click") })
        )
        XCTAssertTrue(interaction.beforeContext?.contains("Proposal before") == true)
        XCTAssertNil(interaction.afterContext)
        XCTAssertFalse(interaction.provenance.sourceEventIDs.contains("roadmap-after-event"))
        XCTAssertFalse(interaction.semanticDelta.joined().contains("Roadmap"))
        XCTAssertEqual(memory.coverage.interactionsWithBeforeAndAfterContext, 0)
    }

    func testNamedResourceQueryDoesNotFallbackToAnUnrelatedDocument() {
        let start = makeDate("2026-08-22T10:00:00Z")
        let safari = app("Safari", "com.apple.Safari")
        let memory = ComputerHistoryEngine.analyze(
            events: [
                event(
                    id: "budget",
                    sequence: 1,
                    at: start,
                    kind: .urlChanged,
                    app: safari,
                    title: "Budget 2027 — Google Sheets",
                    URL: "https://docs.google.com/spreadsheets/d/budget/edit"
                ),
                event(
                    id: "hiring",
                    sequence: 2,
                    at: start.addingTimeInterval(60),
                    kind: .urlChanged,
                    app: safari,
                    title: "Hiring Plan — Google Docs",
                    URL: "https://docs.google.com/document/d/hiring/edit"
                ),
            ],
            day: start,
            calendar: utcCalendar
        )
        let search = ComputerHistorySearchService(memories: [memory])

        let unrelated = search.findResources(
            "Find the strategic acquisition document",
            now: start.addingTimeInterval(120)
        )
        XCTAssertTrue(unrelated.hits.isEmpty)
        XCTAssertTrue(unrelated.answer.contains("No matching"))

        let generic = search.findResources(
            "most recent document",
            now: start.addingTimeInterval(120)
        )
        XCTAssertEqual(generic.hits.first?.resource?.title, "Hiring Plan — Google Docs")

        let exact = search.findResources(
            "Find the hiring document",
            now: start.addingTimeInterval(120)
        )
        let resource = try! XCTUnwrap(exact.hits.first?.resource)
        XCTAssertEqual(search.resource(identifier: resource.id)?.id, resource.id)
        XCTAssertFalse(search.episodes(referencing: resource.id).isEmpty)
    }

    func testApplicationSwitchOnlyHistoryDoesNotCreateWorkflowSuggestion() {
        let start = makeDate("2026-08-21T09:00:00Z")
        let first = switchOnlyEpisode(id: "switch-one", start: start)
        let second = switchOnlyEpisode(
            id: "switch-two",
            start: start.addingTimeInterval(86_400)
        )
        let prior = memory(day: start, episode: first)

        let result = ComputerHistoryWorkflowDetector.detect(
            currentEpisodes: [second],
            priorMemories: [prior]
        )

        XCTAssertTrue(result.patterns.isEmpty)
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    private func switchOnlyEpisode(
        id: String,
        start: Date
    ) -> ComputerHistoryEpisode {
        let interactions = ["ChatGPT", "Finder", "Safari"].enumerated().map {
            index, application in
            ComputerHistoryInteraction(
                id: "\(id)-\(index)",
                start: start.addingTimeInterval(TimeInterval(index * 10)),
                end: start.addingTimeInterval(TimeInterval(index * 10)),
                action: .applicationSwitch,
                label: "Switched to \(application)",
                application: application,
                bundleIdentifier: "test.\(application.lowercased())",
                host: nil,
                resourceIDs: ["application-\(application.lowercased())"],
                beforeContext: nil,
                afterContext: nil,
                semanticDelta: [],
                confidence: 0.66,
                provenance: ActivityProvenance(
                    sourceEventIDs: ["\(id)-event-\(index)"],
                    sourceSequences: [UInt64(index + 1)],
                    sourceEventHashes: []
                )
            )
        }
        return ComputerHistoryEpisode(
            id: id,
            start: start,
            end: start.addingTimeInterval(20),
            title: "Worked in ChatGPT",
            summary: "Only foreground application changes were observed.",
            status: .unknown,
            statusConfidence: 0.45,
            applications: ["ChatGPT", "Finder", "Safari"],
            sites: [],
            resourceIDs: interactions.flatMap(\.resourceIDs),
            requestsOrIntentions: [],
            observableOutcomes: ["Last observable action: Switched to Safari"],
            interactions: interactions,
            eventCount: 3,
            semanticSnapshotCount: 0,
            workflowFingerprint: "same-switch-only-fingerprint",
            provenance: ActivityProvenance(
                sourceEventIDs: interactions.flatMap(\.provenance.sourceEventIDs),
                sourceSequences: interactions.flatMap(\.provenance.sourceSequences),
                sourceEventHashes: []
            )
        )
    }

    private func memory(
        day: Date,
        episode: ComputerHistoryEpisode
    ) -> ComputerHistoryDayMemory {
        ComputerHistoryDayMemory(
            schemaVersion: 1,
            dayStart: day,
            dayEnd: day.addingTimeInterval(86_399),
            generatedAt: day,
            title: "Switch-only fixture",
            executiveSummary: "Switch-only fixture",
            episodes: [episode],
            resources: [],
            workflowPatterns: [],
            suggestions: [],
            coverage: ComputerHistoryCoverage(
                sourceEventCount: 3,
                actionEventCount: 3,
                semanticSnapshotCount: 0,
                linkedInteractionCount: 3,
                interactionsWithBeforeAndAfterContext: 0,
                resourceCount: 0,
                episodeCount: 1,
                suppressedEventCount: 0,
                firstSourceSequence: 1,
                lastSourceSequence: 3,
                lastSourceEventHash: nil
            ),
            markdown: ""
        )
    }

    private func event(
        id: String,
        sequence: UInt64,
        at date: Date,
        kind: EventKind,
        app: AppSnapshot,
        title: String,
        URL rawURL: String,
        semanticContext: SemanticContextReference? = nil,
        pointer: PointerSnapshot? = nil,
        metadata: [String: String]? = nil
    ) -> HistoryEvent {
        let parsed = Foundation.URL(string: rawURL)
        return HistoryEvent(
            schemaVersion: 4,
            id: id,
            sessionID: "computer-history-hardening-tests",
            timestamp: date,
            kind: kind,
            app: app,
            window: WindowSnapshot(title: title, role: "AXWindow", subrole: nil),
            element: ElementSnapshot(
                role: "AXButton",
                subrole: nil,
                title: "Save",
                label: "Save",
                identifier: "save",
                isSecure: false
            ),
            url: URLSnapshot(
                value: rawURL,
                host: parsed?.host,
                redactionApplied: false
            ),
            pointer: pointer,
            semanticContext: semanticContext,
            classification: LocalClassification(
                category: "work",
                isWork: true,
                confidence: 0.9,
                classifierVersion: "test"
            ),
            metadata: metadata,
            integrity: fixtureIntegrity(sequence)
        )
    }

    private func payload(
        id: String,
        text: String,
        at date: Date,
        app: AppSnapshot,
        URL rawURL: String
    ) -> SemanticContextPayload {
        let parsed = Foundation.URL(string: rawURL)
        return SemanticContextPayload(
            id: id,
            capturedAt: date,
            application: app,
            window: WindowSnapshot(title: "Context", role: "AXWindow", subrole: nil),
            url: URLSnapshot(
                value: rawURL,
                host: parsed?.host,
                redactionApplied: false
            ),
            focusedRole: "AXButton",
            source: .mixed,
            text: text,
            contentSHA256: SHA256Digest.hashHex(text),
            redacted: false,
            truncated: false
        )
    }

    private func app(_ name: String, _ bundle: String) -> AppSnapshot {
        AppSnapshot(name: name, bundleIdentifier: bundle, processIdentifier: 42)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
