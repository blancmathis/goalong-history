#if os(macOS)
import EventKit
import Foundation
import LocalHistoryCore
@testable import LocalHistoryApp

/// A calendar the tests and the gallery fill by hand. It never reaches EventKit: no store, no request, no real calendar.
final class GoalongFakeCalendarBackend: GoalongCalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var state = (events: [GoalongRawCalendarEvent](), completed: [GoalongRawReminder](), due: [GoalongRawReminder](),
                         event: GoalongSystemSourceStatus.ready, reminder: GoalongSystemSourceStatus.ready,
                         completedPartial: false, duePartial: false, requests: [EKEntityType](),
                         granting: [EKEntityType: GoalongSystemSourceStatus](), enumerations: 0)
    var events: [GoalongRawCalendarEvent] { get { lock.withLock { state.events } } set { lock.withLock { state.events = newValue } } }
    var completed: [GoalongRawReminder] { get { lock.withLock { state.completed } } set { lock.withLock { state.completed = newValue } } }
    var due: [GoalongRawReminder] { get { lock.withLock { state.due } } set { lock.withLock { state.due = newValue } } }
    var eventPermission: GoalongSystemSourceStatus { get { lock.withLock { state.event } } set { lock.withLock { state.event = newValue } } }
    var reminderPermission: GoalongSystemSourceStatus { get { lock.withLock { state.reminder } } set { lock.withLock { state.reminder = newValue } } }
    var completedPartial: Bool { get { lock.withLock { state.completedPartial } } set { lock.withLock { state.completedPartial = newValue } } }
    var requests: [EKEntityType] { lock.withLock { state.requests } }
    var enumerations: Int { lock.withLock { state.enumerations } }
    /// What a request for this kind of access turns the permission into.
    func grant(_ entity: EKEntityType, as status: GoalongSystemSourceStatus) { lock.withLock { state.granting[entity] = status } }
    func setPermissions(events: GoalongSystemSourceStatus, reminders: GoalongSystemSourceStatus) {
        lock.withLock { state.event = events; state.reminder = reminders }
    }

    func authorization(for entity: EKEntityType) -> GoalongSystemSourceStatus { lock.withLock { entity == .event ? state.event : state.reminder } }
    func requestAccess(for entity: EKEntityType) async {
        lock.withLock {
            state.requests.append(entity)
            if let next = state.granting[entity] { if entity == .event { state.event = next } else { state.reminder = next } }
        }
    }
    func enumerateEvents(start: Date, end: Date, _ visit: (GoalongRawCalendarEvent) -> Bool) {
        let rows = lock.withLock { state.enumerations += 1; return state.events }
        for row in rows where row.end > start && row.start < end { if !visit(row) { return } }
    }
    func completedReminders(start: Date, end: Date) async -> (rows: [GoalongRawReminder], partial: Bool) {
        lock.withLock { (state.completed, state.completedPartial) }
    }
    func dueReminders(start: Date, end: Date) async -> (rows: [GoalongRawReminder], partial: Bool) {
        lock.withLock { (state.due, state.duePartial) }
    }
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol? { nil }
}
#endif
