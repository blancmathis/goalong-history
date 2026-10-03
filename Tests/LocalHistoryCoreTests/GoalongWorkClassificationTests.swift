import Foundation
import XCTest
@testable import LocalHistoryCore

/// Work is decided from the user's definition per context (app + site + window title),
/// never per application, and one task stays one focus across applications.
final class GoalongWorkClassificationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))! }

    private func event(_ seconds: Double, app: String = "Browser", host: String? = nil, title: String? = nil,
                       window: Bool = true, kind: EventKind = .heartbeat, work: Bool? = nil) -> HistoryEvent {
        HistoryEvent(id: UUID().uuidString, sessionID: "fixture", timestamp: day.addingTimeInterval(seconds), kind: kind,
            app: .init(name: app, bundleIdentifier: "fixture." + app, processIdentifier: 1),
            window: window ? WindowSnapshot(title: title, role: nil, subrole: nil) : nil,
            url: host.map { .init(value: "https://" + $0, host: $0, redactionApplied: true) },
            classification: .init(category: "fixture", isWork: work, confidence: 0.99, classifierVersion: "legacy"))
    }
    private func minutes(_ range: ClosedRange<Int>, from start: Double, app: String = "Browser", host: String? = nil,
                         title: String? = nil) -> [HistoryEvent] {
        range.map { event(start + Double($0 * 60), app: app, host: host, title: title) }
    }
    private func label(_ app: String, _ host: String? = nil, _ title: String? = nil) -> GoalongWorkContext.Label {
        GoalongWorkContext.Label(application: app, bundleIdentifier: "fixture." + app, host: host, title: title)
    }
    private func observe(_ events: [HistoryEvent]) -> GoalongWorkClassification.Observation {
        GoalongWorkClassification.observation(events: events, day: day, now: day.addingTimeInterval(86_400), calendar: calendar)
    }

    func testGoalongNeverDecidesFromTheApplicationItself() {
        let built = observe(minutes(0...30, from: 36_000, app: "Xcode", title: "App.swift")).day
        XCTAssertEqual(built.seconds(.work), 0, "A legacy or app-based verdict is never counted as work")
        XCTAssertEqual(built.seconds(.unclassified), 1_800)
        let fresh = LocalClassifier.classify(app: .init(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 1),
                                             url: nil, suppressionReason: nil)
        XCTAssertNil(fresh.isWork)
        XCTAssertEqual(fresh.category, "software_development")
    }

    func testOneApplicationCarriesSeveralContextsAndInputEventsKeepTheirWindow() {
        let events = minutes(0...10, from: 36_000, host: "docs.example.org", title: "Swift concurrency")
            + [event(36_000 + 11 * 60, host: "docs.example.org", window: false, kind: .typingBurst)]
            + minutes(12...20, from: 36_000, host: "video.example.org", title: "(3) Bêtisier")
        let observation = observe(events)
        let keys = Set(observation.day.segments.compactMap(\.contextKey))
        XCTAssertEqual(keys, [label("Browser", "docs.example.org", "Swift concurrency").key,
                              label("Browser", "video.example.org", "Bêtisier").key])
        XCTAssertEqual(observation.labels[label("Browser", "video.example.org", "Bêtisier").key]?.title, "Bêtisier",
                       "Unread counters do not split a page into several contexts")
    }

    func testOneTaskAcrossApplicationsStaysOneFocusAndOneSession() {
        let events = minutes(0...20, from: 36_000, app: "Xcode", title: "App.swift")
            + minutes(21...30, from: 36_000, host: "developer.apple.com", title: "SwiftUI")
            + [event(36_000 + 31 * 60, app: "Finder", title: "Projets")]         // 40 s detour
            + minutes(0...20, from: 36_000 + 31 * 60 + 40, app: "Xcode", title: "App.swift")
        let raw = observe(events).day
        let verdicts = GoalongWorkVerdicts([
            label("Xcode", nil, "App.swift").key: .init(verdict: .work, task: "Goalong"),
            label("Browser", "developer.apple.com", "SwiftUI").key: .init(verdict: .work, task: "Goalong"),
        ])
        let day = raw.applying(verdicts)
        XCTAssertEqual(day.activeSeconds, raw.activeSeconds)
        XCTAssertEqual(day.seconds(.work), raw.activeSeconds, accuracy: 1, "The short Finder detour belongs to the task")
        XCTAssertEqual(day.sequences.count, 1)
        XCTAssertEqual(day.sequences.first?.task, "Goalong")
        let blocks = day.workBlocks(minimumMinutes: 25)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.task, "Goalong")
        XCTAssertGreaterThan(day.contextChanges, 1)
        XCTAssertEqual(day.sameTaskChanges, day.contextChanges)
        XCTAssertEqual(GoalongLocalAnalytics.Period(days: [day]).tasks.map(\.name), ["Goalong"])
        XCTAssertEqual(Set(GoalongLocalAnalytics.Period(days: [day]).tasks.first?.mainApplications ?? []),
                       ["Xcode", "developer.apple.com", "Finder"])
    }

    func testDetoursAreBridgedOnlyWhenShortUnknownAndBetweenTheSameTask() {
        let events = minutes(0...10, from: 36_000, app: "Xcode", title: "A.swift")
            + minutes(11...14, from: 36_000, app: "Messages", title: "Chat")        // 4 min: too long
            + minutes(15...25, from: 36_000, app: "Xcode", title: "A.swift")
            + [event(36_000 + 26 * 60, app: "Music", title: "Radio")]              // judged "other"
            + minutes(27...30, from: 36_000, app: "Xcode", title: "A.swift")
        let verdicts = GoalongWorkVerdicts([
            label("Xcode", nil, "A.swift").key: .init(verdict: .work, task: "Goalong"),
            label("Music", nil, "Radio").key: .init(verdict: .other),
        ])
        let day = observe(events).day.applying(verdicts)
        XCTAssertEqual(day.seconds(.unclassified), 240, "A long unknown detour stays to classify")
        XCTAssertEqual(day.seconds(.other), 60, "An explicit verdict is never overridden")
        XCTAssertEqual(day.workBlocks(minimumMinutes: 1).count, 2, "Four minutes elsewhere end the session")
    }

    func testDifferentTasksStartNewSessions() {
        let events = minutes(0...30, from: 36_000, app: "Xcode", title: "A.swift")
            + minutes(31...60, from: 36_000, app: "Pages", title: "Devis Atlas")
        let day = observe(events).day.applying(GoalongWorkVerdicts([
            label("Xcode", nil, "A.swift").key: .init(verdict: .work, task: "Goalong"),
            label("Pages", nil, "Devis Atlas").key: .init(verdict: .work, task: "Atlas"),
        ]))
        XCTAssertEqual(day.workBlocks(minimumMinutes: 25).map(\.task), ["Goalong", "Atlas"])
        XCTAssertEqual(day.sameTaskChanges, 0)
    }

    func testPendingSkipsKnownShortAndWithheldContextsLongestFirst() {
        let events = minutes(0...20, from: 36_000, app: "Pages", title: "Rapport")
            + minutes(21...25, from: 36_000, app: "Mail", title: "Inbox")
            + [event(36_000 + 26 * 60, app: "Notes", title: "Courses"), event(36_000 + 26 * 60 + 10, app: "Pages", title: "Rapport")]
            + minutes(27...30, from: 36_000, app: "Secret", title: "Coffre")
        let observation = observe(events)
        let known = GoalongWorkVerdicts([label("Mail", nil, "Inbox").key: .init(verdict: .unclear)],
            retries: [label("Mail", nil, "Inbox").key: .init(attempts: 1, lastAskedDay: "2026-09-10")])
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels, verdicts: known,
                                                        permits: { $0.application != "Secret" })
        XCTAssertEqual(pending.keys, [label("Pages", nil, "Rapport").key],
                       "Already judged or asked today, shorter than 15 s or withheld contexts are not sent")
    }

    func testRequestCarriesDefinitionAndTimelineButNeverKeys() throws {
        let events = minutes(0...20, from: 36_000, app: "Pages", title: "Rapport client")
            + minutes(21...30, from: 36_000, app: "Xcode", title: "A.swift")
        let observation = observe(events)
        let xcode = label("Xcode", nil, "A.swift").key
        let verdicts = GoalongWorkVerdicts([xcode: .init(verdict: .work, task: "Goalong")])
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels, verdicts: verdicts)
        let definition = GoalongWorkDefinition(goals: "Goalong et les clients d’Atlas", notWork: "Vidéos de divertissement")
        let request = GoalongWorkClassification.request(date: "2026-09-10", definition: definition, pending: pending,
            batch: pending.keys, day: observation.day, verdicts: verdicts, knownTasks: ["Goalong"], examples: [], calendar: calendar)
        XCTAssertEqual(request.contexts.map(\.id), ["c1"])
        XCTAssertEqual(request.contexts.first?.title, "Rapport client")
        XCTAssertEqual(request.timeline, ["10:00 c1 21 min", "10:21 [travail: Goalong] 9 min"])
        let prompt = GoalongWorkClassification.prompt(request, definition: definition)
        XCTAssertTrue(prompt.contains("Goalong et les clients d’Atlas"))
        XCTAssertTrue(prompt.contains("Vidéos de divertissement"))
        XCTAssertTrue(prompt.contains(request.request_id))
        XCTAssertFalse(prompt.contains(xcode) || request.keys.keys.contains { prompt.contains(request.keys[$0]!) },
                       "Local cache keys never leave the Mac")
    }

    func testAgentAnswerIsStrictlyValidated() throws {
        let observation = observe(minutes(0...20, from: 36_000, app: "Pages", title: "Rapport")
            + minutes(21...40, from: 36_000, app: "Safari", host: "video.example.org", title: "Clip"))
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels, verdicts: .init())
        let request = GoalongWorkClassification.request(date: "2026-09-10", definition: .init(goals: "Rapport"), pending: pending,
            batch: pending.keys, day: observation.day, verdicts: .init(), knownTasks: [], examples: [], calendar: calendar)
        func answer(_ items: String, id: String? = nil) -> Data {
            Data(#"{"request_id":"\#(id ?? request.request_id)","items":[\#(items)]}"#.utf8)
        }
        let valid = try GoalongWorkClassification.parse(answer(#"{"id":"c1","verdict":"work","task":"  Rapport\n trimestriel "},{"id":"c2","verdict":"unknown","task":""}"#))
        let applied = try GoalongWorkClassification.apply(valid, to: request)
        XCTAssertEqual(applied[request.keys["c1"]!], GoalongWorkAssignment(verdict: .work, task: "Rapport trimestriel"))
        XCTAssertEqual(applied[request.keys["c2"]!]?.verdict, .unclear)

        for broken in [answer(#"{"id":"c1","verdict":"work","task":"x"}"#),
                       answer(#"{"id":"c1","verdict":"work","task":"x"},{"id":"c1","verdict":"other","task":""}"#),
                       answer(#"{"id":"c1","verdict":"work","task":"x"},{"id":"c9","verdict":"other","task":""}"#),
                       answer(#"{"id":"c1","verdict":"work","task":"x"},{"id":"c2","verdict":"other","task":""}"#, id: "other-request")] {
            XCTAssertThrowsError(try GoalongWorkClassification.apply(GoalongWorkClassification.parse(broken), to: request))
        }
        XCTAssertThrowsError(try GoalongWorkClassification.parse(Data(#"{"request_id":"x","items":[],"extra":1}"#.utf8)))
    }

    func testDefinitionRevisionFollowsItsMeaning() {
        let a = GoalongWorkDefinition(goals: "Goalong"), b = GoalongWorkDefinition(goals: "Goalong", notWork: "X")
        XCTAssertEqual(a.revision, GoalongWorkDefinition(goals: "Goalong").revision)
        XCTAssertNotEqual(a.revision, b.revision)
        XCTAssertTrue(GoalongWorkDefinition().isEmpty)
        XCTAssertFalse(GoalongWorkDefinition(notWork: "X").hasWorkCriteria)
    }

    func testAnalyticsProjectionKeepsBoundedTitlesForContexts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-context-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let long = String(repeating: "é", count: 400)
        let rows = minutes(0...10, from: 36_000, app: "Pages", title: long)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try rows.reduce(into: Data()) { data, row in data.append(try encoder.encode(row)); data.append(10) }
        try bytes.write(to: folder.appendingPathComponent("2026-09-10.jsonl"))
        let observation = try XCTUnwrap(GoalongWorkClassification.observe(root: root, day: day,
            now: day.addingTimeInterval(86_400), calendar: calendar))
        let title = try XCTUnwrap(observation.labels.values.first?.title)
        XCTAssertEqual(title.count, GoalongWorkContext.maximumTitleLength)
        XCTAssertEqual(GoalongLocalAnalytics.load(root: root, day: day, now: day.addingTimeInterval(86_400), calendar: calendar)
            .segments.compactMap(\.contextKey), observation.day.segments.compactMap(\.contextKey),
            "Activité and the agent see the very same contexts")
    }
}
