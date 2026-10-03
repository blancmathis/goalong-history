#if os(macOS)
import XCTest
import EventKit
import AppleScreenTime
import Foundation
import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongSystemLaneBuilderTests: XCTestCase {
    private let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }
    private func event(_ id: String, _ start: Double, _ end: Double, _ availability: EKEventAvailability = .busy, allDay: Bool = false) -> GoalongCalendarEvent {
        GoalongCalendarEvent(id: id, start: at(start), end: at(end), allDay: allDay, availability: availability.rawValue,
                             title: "Fixture \(id)", calendarName: "Fixture", attendeeCount: 3)
    }

    func testAgendaKeepsPlannedEventsAndMeasuresCallsInsideAndOutsideThem() throws {
        let calls = GoalongCallLane(status: .ready, intervals: [
            GoalongCallInterval(start: at(10), end: at(10.5), bundleIdentifier: "us.zoom.xos", application: "Zoom", microphone: true, camera: true),
            GoalongCallInterval(start: at(14), end: at(14 + 1.0 / 6), bundleIdentifier: nil, application: nil, microphone: false, camera: true),
        ])
        var calendar = GoalongCalendarLane(status: .ready, calendarStatus: .ready, remindersStatus: .ready)
        calendar.events = [event("free", 12, 13, .free), event("busy", 10, 11), event("all-day", 0, 24, allDay: true)]
        calendar.completedReminders = [.init(completedAt: at(17), title: "Second"), .init(completedAt: at(9), title: "First")]
        calendar.openDueReminderCount = 1
        let agenda = try XCTUnwrap(GoalongAgendaDay(calls: calls, calendar: calendar, calendarPermission: .ready, remindersPermission: .ready))
        XCTAssertEqual(agenda.events.map(\.id), ["busy"])
        XCTAssertEqual(agenda.events.first?.callSeconds, 1800)
        XCTAssertEqual(agenda.callApplications.map(\.id), ["Zoom", "Caméra (app inconnue)"])
        XCTAssertEqual(agenda.callApplications.map(\.seconds), [1800, 600])
        XCTAssertEqual(agenda.unplannedCallSeconds, 600)
        XCTAssertEqual(agenda.reminders.map(\.title), ["First", "Second"])
        XCTAssertEqual(agenda.openDueReminders, 1)
        XCTAssertEqual(agenda.calendarAccess, .granted)
        XCTAssertFalse(agenda.partial)
    }

    func testAgendaIsAbsentWhenBothSourcesAreOffAndNamesTheMissingAccess() {
        let off = GoalongCallLane(status: .disabled)
        XCTAssertNil(GoalongAgendaDay(calls: off, calendar: .disabled, calendarPermission: .ready, remindersPermission: .ready))
        let waiting = GoalongCalendarLane(status: .permissionDenied, calendarStatus: .noData, remindersStatus: .noData)
        XCTAssertEqual(GoalongAgendaDay(calls: off, calendar: waiting, calendarPermission: .noData, remindersPermission: .ready)?.calendarAccess, .notAsked)
        XCTAssertEqual(GoalongAgendaDay(calls: off, calendar: waiting, calendarPermission: .ready, remindersPermission: .permissionDenied)?.calendarAccess, .denied)
        let callsOnly = GoalongAgendaDay(calls: GoalongCallLane(status: .partial), calendar: .disabled, calendarPermission: .noData, remindersPermission: .noData)
        XCTAssertEqual(callsOnly?.calendarAccess, .granted, "Access is not asked while « Agenda et rappels » is off")
        XCTAssertEqual(callsOnly?.calendarOn, false)
        XCTAssertEqual(callsOnly?.partial, true)
    }

    func testSleepNamesPhasesInOrderAndRoundsSteps() throws {
        var health = GoalongHealthLane(status: .partial)
        health.sleepStages = ["sleepSeconds": 23_400, "sleepCoreSeconds": 14_400, "sleepDeepSeconds": 3600, "sleepREMSeconds": 5400, "sleepAwakeSeconds": 30]
        health.sleepSeconds = 23_400; health.steps = 8123.6; health.workoutCount = 1; health.workoutSeconds = 1800
        let sleep = try XCTUnwrap(GoalongSleepDay(health))
        XCTAssertEqual(sleep.stages.map(\.id), ["Sommeil profond", "Sommeil essentiel", "Sommeil paradoxal"])
        XCTAssertEqual(sleep.steps, 8124)
        XCTAssertEqual(sleep.sleepSeconds, 23_400)
        XCTAssertFalse(sleep.partial, "Every import is a snapshot; the section says so once")
        XCTAssertNil(GoalongSleepDay(GoalongHealthLane(status: .noData)))
    }

    func testOtherDevicesListMostTimeDuringMacGapsFirst() throws {
        let usage = { (name: String, kind: AppleScreenTimeDeviceKind, gaps: TimeInterval) in
            GoalongOtherDeviceUsage(device: AppleScreenTimeDevice(id: name, name: name, kind: kind), screenOnSeconds: gaps * 2,
                                    duringMacGapsSeconds: gaps, duringMacActivitySeconds: gaps, lastUpdatedAt: self.day, estimated: kind == .iPhone)
        }
        let lane = GoalongOtherDevicesLane(status: .ready, devices: [usage("iPad", .iPad, 600), usage("iPhone", .iPhone, 2700)])
        let value = try XCTUnwrap(GoalongOtherDevicesDay(lane))
        XCTAssertEqual(value.devices.map(\.name), ["iPhone", "iPad"])
        XCTAssertEqual(value.duringGapsSeconds, 3300)
        XCTAssertEqual(value.devices.first?.estimated, true)
        XCTAssertNil(GoalongOtherDevicesDay(GoalongOtherDevicesLane(status: .ready)))
        XCTAssertNil(GoalongOtherDevicesDay(GoalongOtherDevicesLane(status: .disabled, devices: lane.devices)))
    }

    func testSourceStatesFollowTheSystemStatus() {
        XCTAssertEqual(GoalongSourceRow.State(GoalongSystemSourceStatus.disabled), .off)
        XCTAssertEqual(GoalongSourceRow.State(GoalongSystemSourceStatus.permissionDenied), .needsPermission)
        XCTAssertEqual(GoalongSourceRow.State(GoalongSystemSourceStatus.failed("x")), .failed)
    }

    @MainActor func testWorkAgentReceivesTheNoteOnlyWhenTheReviewedRecapSharesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-note-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try GoalongDayNoteStore.set("Deux rendez-vous", root: root, day: day)
        let policy = GoalongPrivacyPolicy.load(in: root)
        var selection = GoalongAnalysisSelection()
        selection.reviewed = true; selection.scope = GoalongAnalysisScope(); selection.privacyRevision = policy.revision
        selection.systemSources = GoalongSystemRecapSelection(dayNote: false)
        XCTAssertNil(GoalongWorkAgent.sharedDayNote(root: root, day: day, selection: selection, policy: policy))
        selection.systemSources?.dayNote = true
        XCTAssertEqual(GoalongWorkAgent.sharedDayNote(root: root, day: day, selection: selection, policy: policy), "Deux rendez-vous")
        selection.reviewed = false
        XCTAssertNil(GoalongWorkAgent.sharedDayNote(root: root, day: day, selection: selection, policy: policy))
    }
}
#endif
