#if os(macOS)
import EventKit
import Foundation
import LocalHistoryCore

/// One event as the system store gives it: not yet clipped to the day, not yet checked for size.
struct GoalongRawCalendarEvent: Equatable, Sendable {
    var id: String?
    var start: Date
    var end: Date
    var allDay: Bool
    var availability: Int
    var title: String?
    var calendarName: String
    var attendeeCount: Int
}
struct GoalongRawReminder: Equatable, Sendable {
    var title: String?
    var completionDate: Date?
    var isCompleted: Bool
    var due: DateComponents?
}

/// Where the calendar source gets its events, reminders and permission states. The app uses EventKit;
/// tests and the gallery give it their own, so none of them reads the real calendar or asks for access.
protocol GoalongCalendarBackend: AnyObject, Sendable {
    func authorization(for entity: EKEntityType) -> GoalongSystemSourceStatus
    func requestAccess(for entity: EKEntityType) async
    /// Calls `visit` for each event that overlaps the span; `visit` returns false to stop.
    func enumerateEvents(start: Date, end: Date, _ visit: (GoalongRawCalendarEvent) -> Bool)
    func completedReminders(start: Date, end: Date) async -> (rows: [GoalongRawReminder], partial: Bool)
    func dueReminders(start: Date, end: Date) async -> (rows: [GoalongRawReminder], partial: Bool)
    /// Calls `handler` when the store changes; nil when it never does.
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol?
}

/// The backend in use. EventKit unless a DEBUG build (tests, gallery) installs another one.
enum GoalongCalendarBackends {
    static let eventKit = GoalongEventKitBackend()
    private static let lock = NSLock()
    private static var installed: (any GoalongCalendarBackend)?
    private static var installedRevision = 0
    static var current: any GoalongCalendarBackend { lock.lock(); defer { lock.unlock() }; return installed ?? eventKit }
    /// Changes each time another backend is installed. `GoalongCalendarSource` keys its cache and its observer on it,
    /// so a backend never reuses the answers of the one before it, even if both have the same address.
    static var revision: Int { lock.lock(); defer { lock.unlock() }; return installedRevision }
    #if DEBUG
    /// Nil gives EventKit back. Bumps `revision`, so `GoalongCalendarSource.shared` drops what the old backend gave.
    static func install(_ backend: (any GoalongCalendarBackend)?) {
        lock.lock(); installed = backend; installedRevision += 1; lock.unlock()
    }
    #endif
}

/// The store itself is created on first use: a process that never reaches the real calendar never creates it.
final class GoalongEventKitBackend: GoalongCalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var created: EKEventStore?
    private var store: EKEventStore {
        lock.lock(); defer { lock.unlock() }
        if let created { return created }
        let made = EKEventStore(); created = made; return made
    }

    static func status(_ auth: EKAuthorizationStatus) -> GoalongSystemSourceStatus {
        if #available(macOS 14, *), auth == .fullAccess { return .ready }
        switch auth {
        case .authorized: return .ready
        case .denied, .restricted: return .permissionDenied
        default: return .noData // permission not yet requested, or calendar write-only access
        }
    }
    func authorization(for entity: EKEntityType) -> GoalongSystemSourceStatus {
        Self.status(EKEventStore.authorizationStatus(for: entity))
    }
    func requestAccess(for entity: EKEntityType) async {
        let store = store
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let done: (Bool, Error?) -> Void = { granted, _ in continuation.resume(returning: granted) }
            if #available(macOS 14, *) {
                if entity == .event { store.requestFullAccessToEvents(completion: done) }
                else { store.requestFullAccessToReminders(completion: done) }
            } else { store.requestAccess(to: entity, completion: done) }
        }
    }
    func enumerateEvents(start: Date, end: Date, _ visit: (GoalongRawCalendarEvent) -> Bool) {
        let store = store
        withoutActuallyEscaping(visit) { (visit: @escaping (GoalongRawCalendarEvent) -> Bool) in // `enumerateEvents` is synchronous
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            store.enumerateEvents(matching: predicate) { (event: EKEvent, stop: UnsafeMutablePointer<ObjCBool>) in
                let raw = GoalongRawCalendarEvent(
                    id: event.eventIdentifier, start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                    availability: event.availability.rawValue, title: event.title,
                    calendarName: event.calendar.title, attendeeCount: event.attendees?.count ?? 0)
                if !visit(raw) { stop.pointee = true }
            }
        }
    }
    func completedReminders(start: Date, end: Date) async -> (rows: [GoalongRawReminder], partial: Bool) {
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: nil)
        return await fetch(predicate)
    }
    func dueReminders(start: Date, end: Date) async -> (rows: [GoalongRawReminder], partial: Bool) {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: nil)
        return await fetch(predicate)
    }
    func observeChanges(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol? {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { _ in handler() }
    }
    private func fetch(_ predicate: NSPredicate) async -> (rows: [GoalongRawReminder], partial: Bool) {
        let store = store
        // A system callback can fail to arrive. One timeout ends this on-demand read; it is not polling.
        return await withCheckedContinuation { continuation in
            let result = GoalongReminderReadCompletion(continuation)
            let token = store.fetchReminders(matching: predicate) { (reminders: [EKReminder]?) in
                let all: [EKReminder] = reminders ?? []
                var rows: [GoalongRawReminder] = []
                for reminder in all.prefix(GoalongCalendarSource.maximumItems) {
                    rows.append(GoalongRawReminder(title: reminder.title, completionDate: reminder.completionDate,
                                                   isCompleted: reminder.isCompleted, due: reminder.dueDateComponents))
                }
                result.finish(rows, partial: reminders == nil || all.count > GoalongCalendarSource.maximumItems)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [store] in
                if result.finish([], partial: true) { store.cancelFetchRequest(token) }
            }
        }
    }
}
private final class GoalongReminderReadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(rows: [GoalongRawReminder], partial: Bool), Never>?
    init(_ continuation: CheckedContinuation<(rows: [GoalongRawReminder], partial: Bool), Never>) { self.continuation = continuation }
    @discardableResult func finish(_ rows: [GoalongRawReminder], partial: Bool) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return false }
        pending.resume(returning: (rows, partial)); return true
    }
}
#endif
