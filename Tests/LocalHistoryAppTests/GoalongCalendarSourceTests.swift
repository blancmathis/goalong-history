#if os(macOS)
import XCTest
import AppKit
import EventKit
import Foundation
import LocalHistoryCore
@testable import LocalHistoryApp

/// The calendar source over a fake backend: filters, order, day edges, time zones and permission states.
final class GoalongCalendarSourceTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!; return calendar
    }
    private func make(_ zone: String = "Europe/Paris") -> (GoalongFakeCalendarBackend, GoalongCalendarSource, Calendar, Date) {
        let backend = GoalongFakeCalendarBackend(), zoned = calendar(zone)
        let noon = zoned.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        return (backend, GoalongCalendarSource(backend: backend), zoned, noon)
    }
    private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false, free: Bool = false,
                       title: String? = "Réunion") -> GoalongRawCalendarEvent {
        .init(id: id, start: start, end: end, allDay: allDay,
              availability: (free ? EKEventAvailability.free : .busy).rawValue, title: title, calendarName: "Travail", attendeeCount: 2)
    }

    func testEventsAreSortedClippedToTheDayAndDropOtherDays() async {
        let (backend, source, zoned, noon) = make()
        let day = zoned.dateInterval(of: .day, for: noon)!
        backend.events = [
            event("late", noon.addingTimeInterval(7_200), noon.addingTimeInterval(9_000)),
            event("early", noon.addingTimeInterval(-7_200), noon.addingTimeInterval(-3_600)),
            event("yesterday", day.start.addingTimeInterval(-7_200), day.start.addingTimeInterval(-60)),
            event("tomorrow", day.end, day.end.addingTimeInterval(3_600)),
            event("night", day.start.addingTimeInterval(-3_600), day.start.addingTimeInterval(1_800)),
        ]
        let lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.events.map(\.id), ["night", "early", "late"])
        XCTAssertEqual(lane.events.first?.start, day.start, "an event that began yesterday starts at midnight")
        XCTAssertEqual(lane.events.first?.end, day.start.addingTimeInterval(1_800))
        XCTAssertEqual(lane.calendarStatus, .ready)
    }
    func testMultiDayEventFillsTheWholeDay() async {
        let (backend, source, zoned, noon) = make()
        let day = zoned.dateInterval(of: .day, for: noon)!
        backend.events = [event("trip", day.start.addingTimeInterval(-86_400), day.end.addingTimeInterval(86_400))]
        let lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.events.count, 1)
        XCTAssertEqual(lane.events[0].start, day.start)
        XCTAssertEqual(lane.events[0].end, day.end)
        XCTAssertEqual(lane.plannedBusySeconds, day.duration)
    }
    func testAllDayAndFreeEventsStayListedButAreNotPlannedBusy() async {
        let (backend, source, zoned, noon) = make()
        let day = zoned.dateInterval(of: .day, for: noon)!
        backend.events = [event("holiday", day.start, day.end, allDay: true),
                          event("free", noon, noon.addingTimeInterval(3_600), free: true),
                          event("busy", noon, noon.addingTimeInterval(1_800))]
        let lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.events.count, 3)
        XCTAssertEqual(lane.events.filter(\.isPlannedBusy).map(\.id), ["busy"])
        XCTAssertEqual(lane.plannedBusySeconds, 1_800)
    }
    func testEmptyAndZeroLengthEventsGiveNoData() async {
        let (backend, source, zoned, noon) = make()
        var lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.status, .noData); XCTAssertEqual(lane.calendarStatus, .noData); XCTAssertEqual(lane.remindersStatus, .noData)
        backend.events = [event("point", noon, noon)]
        await source.invalidate()
        lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertTrue(lane.events.isEmpty, "an event with no length is not shown")
    }
    func testOversizedTitlesAndAttendeeCountsAreBounded() async {
        let (backend, source, zoned, noon) = make()
        backend.events = [event("big", noon, noon.addingTimeInterval(60), title: String(repeating: "x", count: 16_001))]
        backend.events[0].attendeeCount = 50_000
        let lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.events[0].title, "")
        XCTAssertEqual(lane.events[0].attendeeCount, 10_000)
    }
    func testNoMoreThanTheMaximumIsReadAndTheLaneSaysPartial() async {
        let (backend, source, zoned, noon) = make()
        backend.events = (0..<(GoalongCalendarSource.maximumItems + 5)).map { event("e\($0)", noon.addingTimeInterval(Double($0)), noon.addingTimeInterval(Double($0) + 1)) }
        let lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.events.count, GoalongCalendarSource.maximumItems)
        XCTAssertEqual(lane.calendarStatus, .partial); XCTAssertEqual(lane.status, .partial)
    }
    func testTheDayFollowsTheTimeZone() async {
        let backend = GoalongFakeCalendarBackend(), source = GoalongCalendarSource(backend: backend)
        let paris = calendar("Europe/Paris"), tokyo = calendar("Asia/Tokyo")
        // 23:30 in Paris on 23 October is 06:30 in Tokyo on 24 October.
        let moment = paris.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 30))!
        backend.events = [event("late", moment, moment.addingTimeInterval(1_800))]
        let inParis = await source.read(day: moment, enabled: true, calendar: paris)
        let inTokyo = await source.read(day: moment, enabled: true, calendar: tokyo)
        XCTAssertEqual(inParis.events.count, 1)
        XCTAssertEqual(inTokyo.events.count, 1)
        let otherDay = tokyo.date(byAdding: .day, value: -1, to: moment)!
        let before = await source.read(day: otherDay, enabled: true, calendar: tokyo)
        XCTAssertTrue(before.events.isEmpty, "the Tokyo day before does not hold the event")
        XCTAssertEqual(inTokyo.events[0].start, moment)
    }
    func testRemindersCompletedInTheDayAreSortedAndOthersDropped() async {
        let (backend, source, zoned, noon) = make()
        let day = zoned.dateInterval(of: .day, for: noon)!
        backend.completed = [.init(title: "Après", completionDate: noon.addingTimeInterval(600), isCompleted: true, due: nil),
                             .init(title: "Avant", completionDate: noon.addingTimeInterval(-600), isCompleted: true, due: nil),
                             .init(title: "Hier", completionDate: day.start.addingTimeInterval(-1), isCompleted: true, due: nil),
                             .init(title: "Demain", completionDate: day.end, isCompleted: true, due: nil),
                             .init(title: "Sans date", completionDate: nil, isCompleted: true, due: nil)]
        let lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.completedReminders.map(\.title), ["Avant", "Après"])
        XCTAssertEqual(lane.remindersStatus, .ready)
    }
    func testOpenDueRemindersAreCountedInTheirOwnTimeZone() async {
        let (backend, source, zoned, noon) = make("Europe/Paris")
        func due(_ zone: String, hour: Int, day: Int = 23) -> GoalongRawReminder {
            var parts = DateComponents(year: 2026, month: 10, day: day, hour: hour); parts.timeZone = TimeZone(identifier: zone)
            return .init(title: "R", completionDate: nil, isCompleted: false, due: parts)
        }
        var floating = DateComponents(year: 2026, month: 10, day: 23, hour: 9)
        floating.calendar = nil; floating.timeZone = nil
        backend.due = [due("Europe/Paris", hour: 8),                // in the day
                       due("Europe/Paris", hour: 8, day: 24),       // tomorrow
                       due("Pacific/Auckland", hour: 8),            // 23 Oct 08:00 NZDT = 22 Oct 22:00 Paris: before the day
                       due("America/Los_Angeles", hour: 20),        // 23 Oct 20:00 PDT = 24 Oct 05:00 Paris: after the day
                       .init(title: "Fait", completionDate: nil, isCompleted: true, due: floating),
                       .init(title: "Floating", completionDate: nil, isCompleted: false, due: floating),   // follows the reader's zone
                       .init(title: "Sans échéance", completionDate: nil, isCompleted: false, due: nil)]
        let lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.openDueReminderCount, 2)
        XCTAssertEqual(lane.remindersStatus, .ready)
    }
    func testPartialReminderReadMakesTheLanePartial() async {
        let (backend, source, zoned, noon) = make()
        backend.completedPartial = true
        let lane = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.remindersStatus, .partial); XCTAssertEqual(lane.status, .partial)
    }
    func testDisabledReadsNothing() async {
        let (backend, source, zoned, noon) = make()
        backend.events = [event("a", noon, noon.addingTimeInterval(60))]
        let lane = await source.read(day: noon, enabled: false, calendar: zoned)
        XCTAssertEqual(lane, .disabled)
        XCTAssertEqual(backend.enumerations, 0)
    }
    func testCachedDayIsReusedUntilInvalidated() async {
        let (backend, source, zoned, noon) = make()
        backend.events = [event("a", noon, noon.addingTimeInterval(60))]
        _ = await source.read(day: noon, enabled: true, calendar: zoned)
        _ = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(backend.enumerations, 1)
        await source.invalidate()
        _ = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(backend.enumerations, 2)
    }

    // MARK: Permissions

    func testPermissionStatesOfBothKinds() async {
        let (backend, source, zoned, noon) = make()
        backend.events = [event("a", noon, noon.addingTimeInterval(60))]
        backend.completed = [GoalongRawReminder(title: "Appeler le garage", completionDate: noon, isCompleted: true, due: nil)]
        let cases: [(String, GoalongSystemSourceStatus, GoalongSystemSourceStatus, GoalongSystemSourceStatus)] = [
            ("both granted", .ready, .ready, .ready),
            ("both denied or restricted", .permissionDenied, .permissionDenied, .permissionDenied),
            ("not asked or write-only", .noData, .noData, .noData),
            ("calendar only", .ready, .permissionDenied, .partial),
            ("reminders only", .permissionDenied, .ready, .partial),
        ]
        for (name, events, reminders, expected) in cases {
            backend.setPermissions(events: events, reminders: reminders)
            await source.invalidate()
            let lane = await source.read(day: noon, enabled: true, calendar: zoned)
            XCTAssertEqual(lane.calendarStatus, events == .ready ? .ready : events, name)
            XCTAssertEqual(lane.status, expected, name)
            if events != .ready { XCTAssertTrue(lane.events.isEmpty, "\(name): nothing is read without access") }
        }
    }
    func testSystemStatusMapsEveryAuthorizationState() {
        typealias Backend = GoalongEventKitBackend
        XCTAssertEqual(Backend.status(.notDetermined), .noData)
        XCTAssertEqual(Backend.status(.restricted), .permissionDenied)
        XCTAssertEqual(Backend.status(.denied), .permissionDenied)
        XCTAssertEqual(Backend.status(.authorized), .ready)
        if #available(macOS 14, *) {
            XCTAssertEqual(Backend.status(.fullAccess), .ready)
            XCTAssertEqual(Backend.status(.writeOnly), .noData, "write-only cannot read events")
        }
    }
    func testRequestAccessAsksOnlyForWhatIsMissingAndNeverAfterARefusal() async {
        let (backend, source, _, _) = make()
        backend.setPermissions(events: .noData, reminders: .permissionDenied)
        backend.grant(.event, as: .ready)
        let result = await source.requestAccess(enabled: true)
        XCTAssertEqual(backend.requests, [.event])
        XCTAssertEqual(result.calendar, .ready); XCTAssertEqual(result.reminders, .permissionDenied)
        let off = await source.requestAccess(enabled: false)
        XCTAssertEqual(off.calendar, .disabled); XCTAssertEqual(backend.requests, [.event])
    }
    func testAccessLostDuringTheReadGivesPermissionDeniedAndIsNotCached() async {
        let (backend, source, zoned, noon) = make()
        let flipping = FlippingBackend(inner: backend)
        let flipped = GoalongCalendarSource(backend: flipping)
        _ = source
        let lane = await flipped.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(lane.status, .permissionDenied)
        XCTAssertEqual(lane.calendarStatus, .permissionDenied)
    }
    /// Takes the access away after the first events read, like the member does in System Settings mid-read.
    private final class FlippingBackend: GoalongCalendarBackend, @unchecked Sendable {
        let inner: GoalongFakeCalendarBackend
        init(inner: GoalongFakeCalendarBackend) { self.inner = inner }
        func authorization(for entity: EKEntityType) -> GoalongSystemSourceStatus { inner.authorization(for: entity) }
        func requestAccess(for entity: EKEntityType) async { await inner.requestAccess(for: entity) }
        func enumerateEvents(start: Date, end: Date, _ visit: (GoalongRawCalendarEvent) -> Bool) {
            inner.enumerateEvents(start: start, end: end, visit); inner.eventPermission = .permissionDenied
        }
        func completedReminders(start: Date, end: Date) async -> (rows: [GoalongRawReminder], partial: Bool) { await inner.completedReminders(start: start, end: end) }
        func dueReminders(start: Date, end: Date) async -> (rows: [GoalongRawReminder], partial: Bool) { await inner.dueReminders(start: start, end: end) }
        func observeChanges(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol? { nil }
    }

    // MARK: Seam

    func testTheSharedSourceFollowsTheInstalledBackendAndGivesEventKitBack() async {
        let backend = GoalongFakeCalendarBackend()
        backend.setPermissions(events: .permissionDenied, reminders: .noData)
        GoalongCalendarBackends.install(backend)
        addTeardownBlock { GoalongCalendarBackends.install(nil) }
        XCTAssertEqual(GoalongCalendarSource.authorization(for: .event), .permissionDenied)
        XCTAssertEqual(GoalongCalendarSource.authorization(for: .reminder), .noData)
        GoalongCalendarBackends.install(nil)
        XCTAssertTrue(GoalongCalendarBackends.current === GoalongCalendarBackends.eventKit)
    }
    /// The cache answers for one installed backend. Installing another one (or the same one again) starts a new revision,
    /// so nothing the earlier backend gave is served again, whatever its address.
    func testInstallingABackendDropsTheAnswersOfTheOneBefore() async {
        let backend = GoalongFakeCalendarBackend(), zoned = calendar("Europe/Paris")
        let noon = zoned.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        backend.events = [event("first", noon, noon.addingTimeInterval(60))]
        GoalongCalendarBackends.install(backend)
        addTeardownBlock { GoalongCalendarBackends.install(nil) }
        let source = GoalongCalendarSource()
        let before = GoalongCalendarBackends.revision
        let first = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(first.events.map(\.id), ["first"])
        backend.events = [event("second", noon, noon.addingTimeInterval(60))]
        GoalongCalendarBackends.install(backend)
        XCTAssertNotEqual(GoalongCalendarBackends.revision, before)
        let second = await source.read(day: noon, enabled: true, calendar: zoned)
        XCTAssertEqual(second.events.map(\.id), ["second"])
    }

    // MARK: R14c-N4: the kept EventKit status, over an injected status source

    /// The daemon's answer, how often it was asked, and the background re-reads not yet run.
    private final class StatusSource: @unchecked Sendable {
        private let lock = NSLock()
        private var value: EKAuthorizationStatus = .authorized, asked = 0, waiting: [@Sendable () -> Void] = []
        var onRead: (@Sendable () -> Void)?
        func set(_ status: EKAuthorizationStatus) { lock.lock(); value = status; lock.unlock() }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return asked }
        /// Answers what the daemon held when the read began, then runs `onRead` (once) while the read is still out.
        func read() -> EKAuthorizationStatus {
            lock.lock(); asked += 1; let answer = value, hook = onRead; onRead = nil; lock.unlock()
            hook?()
            return answer
        }
        func later(_ work: @escaping @Sendable () -> Void) { lock.lock(); waiting.append(work); lock.unlock() }
        func runLater() { lock.lock(); let all = waiting; waiting = []; lock.unlock(); all.forEach { $0() } }
        var pending: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
    }
    private func keptBackend(ask: (@Sendable (EKEntityType) async -> Void)? = nil)
        -> (GoalongEventKitBackend, StatusSource, NotificationCenter) {
        let source = StatusSource(), center = NotificationCenter()
        let backend = GoalongEventKitBackend(readStatus: { _ in source.read() }, center: center,
                                             refresh: { source.later($0) }, ask: ask)
        return (backend, source, center)
    }

    func testKeptStatusAsksTheDaemonOnceUntilSomethingCanChangeIt() {
        let (backend, source, _) = keptBackend()
        XCTAssertEqual(backend.authorization(for: .event), .ready)
        XCTAssertEqual(backend.authorization(for: .event), .ready)
        XCTAssertEqual(source.reads, 1, "the second read is the kept answer")
        source.set(.denied)
        XCTAssertEqual(backend.authorization(for: .event), .ready, "nothing told it: still the kept answer")
    }

    /// Each of the 3 triggers forgets at once (the next read asks again and sees the new answer), then queues one
    /// background re-read of both entities that fills the cache again.
    func testKeptStatusIsForgottenOnReturnStoreChangeAndOwnRequest() async {
        let triggers: [(String, (GoalongEventKitBackend, NotificationCenter) async -> Void)] = [
            ("return to the app", { _, center in center.post(name: NSApplication.didBecomeActiveNotification, object: nil) }),
            ("store change", { _, center in center.post(name: .EKEventStoreChanged, object: nil) }),
            ("own request", { backend, _ in await backend.requestAccess(for: .event) }),
        ]
        for (name, trigger) in triggers {
            let asked = AsyncFlag()
            let (backend, source, center) = keptBackend(ask: { _ in asked.set() })
            XCTAssertEqual(backend.authorization(for: .event), .ready, name)
            source.set(.denied)
            await trigger(backend, center)
            XCTAssertEqual(source.pending, 1, "\(name): one background re-read queued")
            let before = source.reads
            XCTAssertEqual(backend.authorization(for: .event), .permissionDenied, "\(name): forgotten at once, no old answer")
            XCTAssertEqual(source.reads, before + 1, name)
            source.set(.notDetermined)
            source.runLater()
            let filled = source.reads
            XCTAssertEqual(backend.authorization(for: .reminder), .noData, "\(name): the re-read read the new answer")
            XCTAssertEqual(source.reads, filled, "\(name): the background re-read filled the cache, no wait")
            if name == "own request" { XCTAssertTrue(asked.value, "the injected request ran, not EventKit") }
        }
    }

    /// A read that started before a forget answers its caller, but its answer is not kept: the next read asks again.
    func testReadStartedBeforeAForgetIsNotKept() {
        let (backend, source, center) = keptBackend()
        XCTAssertEqual(backend.authorization(for: .event), .ready) // first read: kept, observers registered
        center.post(name: .EKEventStoreChanged, object: nil) // the next read goes to the source
        source.onRead = { source.set(.denied); center.post(name: .EKEventStoreChanged, object: nil) } // changes while out
        XCTAssertEqual(backend.authorization(for: .event), .ready, "the started read answers with what it read")
        XCTAssertEqual(backend.authorization(for: .event), .permissionDenied, "but it was not kept over the forget")
    }
}

/// A Sendable boolean set from an injected closure.
private final class AsyncFlag: @unchecked Sendable {
    private let lock = NSLock(); private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}
#endif
