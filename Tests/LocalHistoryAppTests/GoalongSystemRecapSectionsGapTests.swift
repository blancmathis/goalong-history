#if os(macOS)
import XCTest
import Foundation
@testable import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongSystemRecapSectionsGapTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-recap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private let start = Calendar.current.startOfDay(for: Date())
    private var day: GoalongLocalAnalytics.Day {
        .init(date: start, end: start.addingTimeInterval(86_400), state: .ready, segments: [], eventCount: 0, classifierVersions: [])
    }
    private func consent(_ enabled: [GoalongCapability]) -> GoalongConsentDocument {
        var document = GoalongConsentDocument.disabledByDefault
        for capability in enabled { document.capabilities[capability.rawValue] = .init(enabled: true, changedAt: nil, surface: .settings) }
        return document
    }
    private func load(_ root: URL, _ selection: GoalongSystemRecapSelection, consent: GoalongConsentDocument,
                      privacy: GoalongPrivacyPolicy = .init()) -> GoalongSystemSourcesDay {
        GoalongSystemRecapSections.load(root: root, day: day, selection: selection, consent: consent, scope: .init(), privacy: privacy)
    }
    private func call(_ app: String, bundle: String?, offset: TimeInterval = 100) -> GoalongCallInterval {
        .init(start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 600), bundleIdentifier: bundle,
              application: app, microphone: true, camera: false)
    }
    private func emptySources(calls: GoalongCallLane = .init(status: .noData), note: String? = nil,
                              noteStatus: GoalongSystemSourceStatus = .disabled) -> GoalongSystemSourcesDay {
        .init(calls: calls, calendar: .disabled, otherDevices: .init(status: .disabled), health: .init(status: .disabled), note: note, noteStatus: noteStatus)
    }
    private func append(_ sources: GoalongSystemSourcesDay, _ selection: GoalongSystemRecapSelection, scope: GoalongAnalysisScope = .init(),
                        privacy: GoalongPrivacyPolicy = .init()) throws -> (Int, [String: Any]) {
        var document: [String: Any] = [:]
        let items = try GoalongSystemRecapSections.append(sources, selection: selection, scope: scope, privacy: privacy,
                                                          text: { value, limit in String(value.prefix(limit)) }, to: &document)
        return (items, document)
    }

    func testNothingIsReadByDefault() throws {
        let root = try root()
        try GoalongDayNoteStore.set("secret", root: root, day: start)
        XCTAssertFalse(GoalongSystemRecapSelection().hasSources)
        let result = load(root, .init(), consent: consent(GoalongCapability.allCases))
        XCTAssertEqual(result.calls.status, .disabled)
        XCTAssertEqual(result.calendar, .disabled)
        XCTAssertEqual(result.otherDevices.status, .disabled)
        XCTAssertEqual(result.health.status, .disabled)
        XCTAssertNil(result.note)
        XCTAssertEqual(result.noteStatus, .disabled)
    }

    func testEachSelectionAloneTurnsOnTheSourceFlag() {
        for keyPath in [\GoalongSystemRecapSelection.calls, \.calendar, \.otherDevices, \.health, \.dayNote] {
            var selection = GoalongSystemRecapSelection()
            selection[keyPath: keyPath] = true
            XCTAssertTrue(selection.hasSources)
        }
    }

    func testCallsAndNoteAreReadOnlyWithConsent() throws {
        let root = try root()
        try GoalongCallStore.save(call("Zoom", bundle: "us.zoom.xos"), root: root)
        try GoalongDayNoteStore.set("Réunion hors du Mac", root: root, day: start)
        var selection = GoalongSystemRecapSelection(); selection.calls = true; selection.dayNote = true

        let withConsent = load(root, selection, consent: consent([.localComputerHistory]))
        XCTAssertEqual(withConsent.calls.intervals.count, 1)
        XCTAssertEqual(withConsent.calls.intervals.first?.application, "Zoom")
        XCTAssertEqual(withConsent.note, "Réunion hors du Mac")
        XCTAssertEqual(withConsent.noteStatus, .ready)

        let withoutConsent = load(root, selection, consent: consent([]))
        XCTAssertEqual(withoutConsent.calls.status, .disabled, "a selection alone never reads calls")
        XCTAssertTrue(withoutConsent.calls.intervals.isEmpty)
        XCTAssertEqual(withoutConsent.note, "Réunion hors du Mac", "the note is the user's own text; only exclusions hide it")
    }

    func testRecorderConfigCanTurnCallCaptureOff() throws {
        let root = try root()
        try GoalongCallStore.save(call("Zoom", bundle: "us.zoom.xos"), root: root)
        var config = RecorderConfig.default
        config.captureCallPresence = false
        try JSONEncoder().encode(config).write(to: root.appendingPathComponent("config.json"))
        var selection = GoalongSystemRecapSelection(); selection.calls = true
        XCTAssertEqual(load(root, selection, consent: consent([.localComputerHistory])).calls.status, .disabled)
    }

    func testExclusionsHideTheNoteAndTheCalendarLane() throws {
        let root = try root()
        try GoalongDayNoteStore.set("privé", root: root, day: start)
        var privacy = GoalongPrivacyPolicy(); privacy.applications = ["com.secret.app": "Secret"]
        var selection = GoalongSystemRecapSelection(); selection.dayNote = true; selection.calendar = true
        let result = load(root, selection, consent: consent([.calendar]), privacy: privacy)
        XCTAssertNil(result.note)
        XCTAssertEqual(result.noteStatus, .noData)
        XCTAssertEqual(result.calendar, .disabled, "calendar titles have no provenance to filter, so they are not read")
    }

    func testCalendarOnTheMainThreadReturnsAnExplicitPartialAgendaInsteadOfBlocking() throws {
        let root = try root()
        var selection = GoalongSystemRecapSelection(); selection.calendar = true
        let result = load(root, selection, consent: consent([.calendar]))
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(result.calendar.status, .partial)
        XCTAssertEqual(result.calendar.calendarStatus, .partial)
        XCTAssertEqual(result.calendar.remindersStatus, .partial)
    }

    func testUnreadableNoteIsReportedAsFailedNotMissing() throws {
        let root = try root()
        let other = try self.root()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("notes"), withDestinationURL: other)
        var selection = GoalongSystemRecapSelection(); selection.dayNote = true
        let result = load(root, selection, consent: consent([]))
        XCTAssertNil(result.note)
        XCTAssertEqual(result.noteStatus, .failed("Note du jour illisible."))
    }

    func testAppendWritesOnlySelectedSectionsAndCountsItems() throws {
        let sources = emptySources(calls: .init(status: .ready, intervals: [call("Zoom", bundle: "us.zoom.xos")]),
                                   note: "À retenir", noteStatus: .ready)
        var selection = GoalongSystemRecapSelection(); selection.calls = true
        let (items, document) = try append(sources, selection)
        XCTAssertEqual(items, 1)
        XCTAssertEqual(Set(document.keys), ["usages_micro_camera"])
        let calls = try XCTUnwrap(document["usages_micro_camera"] as? [String: Any])
        XCTAssertEqual(calls["statut"] as? String, "ready")
        XCTAssertEqual(calls["partiel"] as? Bool, false)
        XCTAssertEqual((calls["intervalles"] as? [[String: Any]])?.first?["application"] as? String, "Zoom")

        selection.dayNote = true
        let (both, noteDocument) = try append(sources, selection)
        XCTAssertEqual(both, 2)
        XCTAssertEqual((noteDocument["note_du_jour"] as? [String: Any])?["texte"] as? String, "À retenir")
    }

    func testBlockedPrivacyWritesNothing() throws {
        var privacy = GoalongPrivacyPolicy(); privacy.blocked = true
        var selection = GoalongSystemRecapSelection(); selection.calls = true; selection.dayNote = true
        let (items, document) = try append(emptySources(note: "x", noteStatus: .ready), selection, privacy: privacy)
        XCTAssertEqual(items, 0)
        XCTAssertTrue(document.isEmpty)
    }

    func testCallRowsFollowScopeAndExclusionsAndMarkTheLaneAsPartial() throws {
        let rows = [call("Zoom", bundle: "us.zoom.xos", offset: 0), call("Secret", bundle: "com.secret.app", offset: 1_000),
                    call("Safari", bundle: "com.apple.Safari", offset: 2_000)]
        let sources = emptySources(calls: .init(status: .ready, intervals: rows))
        var selection = GoalongSystemRecapSelection(); selection.calls = true
        var privacy = GoalongPrivacyPolicy(); privacy.applications = ["com.secret.app": "Secret"]
        let (items, document) = try append(sources, selection, privacy: privacy)
        XCTAssertEqual(items, 2)
        let lane = try XCTUnwrap(document["usages_micro_camera"] as? [String: Any])
        XCTAssertEqual(lane["partiel"] as? Bool, true, "a removed row must say the list is incomplete")

        var scope = GoalongAnalysisScope(); scope.applicationIDs = ["us.zoom.xos"]
        XCTAssertEqual(try append(sources, selection, scope: scope).0, 1)

        privacy.domains = ["example.com"]
        let (withDomains, _) = try append(sources, selection, privacy: privacy)
        XCTAssertEqual(withDomains, 1, "with domain exclusions a browser call row has no provenance and is dropped")
    }

    func testCallRowsAreCappedAtSixtyFourAndFlaggedPartial() throws {
        let rows = (0..<70).map { call("Zoom", bundle: "us.zoom.xos", offset: Double($0) * 1_000) }
        var selection = GoalongSystemRecapSelection(); selection.calls = true
        let (items, document) = try append(emptySources(calls: .init(status: .ready, intervals: rows)), selection)
        XCTAssertEqual(items, 64)
        XCTAssertEqual((document["usages_micro_camera"] as? [String: Any])?["partiel"] as? Bool, true)
    }

    func testCalendarSectionIsReplacedByAPartialNoticeUnderExclusions() throws {
        var selection = GoalongSystemRecapSelection(); selection.calendar = true
        var privacy = GoalongPrivacyPolicy(); privacy.domains = ["example.com"]
        let (items, document) = try append(emptySources(), selection, privacy: privacy)
        XCTAssertEqual(items, 0)
        XCTAssertEqual((document["agenda_rappels"] as? [String: Any])?["statut"] as? String, "partial")

        let event = GoalongCalendarEvent(id: "1", start: start, end: start.addingTimeInterval(3_600), allDay: false, availability: 0,
                                         title: "Dentiste", calendarName: "Perso", attendeeCount: 1)
        var lane = GoalongCalendarLane(status: .ready, calendarStatus: .ready, remindersStatus: .ready)
        lane.events = [event]
        lane.completedReminders = [.init(completedAt: start, title: "Payer")]
        lane.openDueReminderCount = 2
        let sources = GoalongSystemSourcesDay(calls: .init(status: .disabled), calendar: lane, otherDevices: .init(status: .disabled),
                                              health: .init(status: .disabled), note: nil, noteStatus: .disabled)
        let (count, full) = try append(sources, selection)
        XCTAssertEqual(count, 1 + 1 + 2)
        let agenda = try XCTUnwrap(full["agenda_rappels"] as? [String: Any])
        XCTAssertEqual(agenda["secondes_prevues_occupees"] as? Double, 3_600)
        XCTAssertEqual(agenda["rappels_echus_ouverts"] as? Int, 2)
    }

    func testHealthSectionOmitsMissingValuesAndTextIsBoundedByTheCaller() throws {
        var health = GoalongHealthLane(status: .partial)
        health.steps = 1_200; health.workoutCount = 2; health.workoutSeconds = 3_000; health.timeZone = "Europe/Paris"
        let sources = GoalongSystemSourcesDay(calls: .init(status: .disabled), calendar: .disabled, otherDevices: .init(status: .disabled),
                                              health: health, note: String(repeating: "n", count: 400), noteStatus: .ready)
        var selection = GoalongSystemRecapSelection(); selection.health = true; selection.dayNote = true
        let (items, document) = try append(sources, selection)
        let row = try XCTUnwrap(document["contexte_sante_importe"] as? [String: Any])
        XCTAssertNil(row["secondes_sommeil"])
        XCTAssertEqual(row["pas"] as? Double, 1_200)
        XCTAssertEqual(row["fuseau_import"] as? String, "Europe/Paris")
        XCTAssertEqual(items, 1 + 2 + 1)
        XCTAssertEqual(((document["note_du_jour"] as? [String: Any])?["texte"] as? String)?.count, 280)
    }
}
#endif
