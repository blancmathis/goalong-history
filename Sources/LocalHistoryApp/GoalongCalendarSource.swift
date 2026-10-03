#if os(macOS)
import EventKit
import Foundation
import LocalHistoryCore

struct GoalongCalendarEvent: Equatable, Sendable, Identifiable {
    let id: String
    let start: Date
    let end: Date
    let allDay: Bool
    let availability: Int
    let title: String
    let calendarName: String
    let attendeeCount: Int
    var isPlannedBusy: Bool { !allDay && availability != EKEventAvailability.free.rawValue }
}
struct GoalongCompletedReminder: Equatable, Sendable {
    let completedAt: Date
    let title: String
}
struct GoalongCalendarLane: Equatable, Sendable {
    var status: GoalongSystemSourceStatus
    var calendarStatus: GoalongSystemSourceStatus
    var remindersStatus: GoalongSystemSourceStatus
    var events: [GoalongCalendarEvent] = []
    var completedReminders: [GoalongCompletedReminder] = []
    var openDueReminderCount = 0
    var plannedBusySeconds: TimeInterval {
        GoalongSourceIntervals.unionSeconds(events.filter(\.isPlannedBusy).map { DateInterval(start: $0.start, end: $0.end) })
    }
    static let disabled = Self(status: .disabled, calendarStatus: .disabled, remindersStatus: .disabled)
}

/// EventKit objects and titles remain in this actor's memory. Nothing is persisted or changed.
actor GoalongCalendarSource {
    static let shared = GoalongCalendarSource()
    private let store = EKEventStore()
    private var generation = 0
    private var cache: [String: (Int, GoalongCalendarLane)] = [:]
    private var observer: NSObjectProtocol?
    private var observing = false
    static let maximumItems = 1000

    static func authorization(for entity: EKEntityType) -> GoalongSystemSourceStatus {
        let auth = EKEventStore.authorizationStatus(for: entity)
        if #available(macOS 14, *), auth == .fullAccess { return .ready }
        switch auth {
        case .authorized: return .ready
        case .denied, .restricted: return .permissionDenied
        default: return .noData // permission not yet requested, or calendar write-only access
        }
    }
    func invalidate() { generation += 1; cache.removeAll() }
    func disable() { invalidate() }
    func requestAccess(enabled: Bool) async -> (calendar: GoalongSystemSourceStatus, reminders: GoalongSystemSourceStatus) {
        guard enabled else { return (.disabled, .disabled) }
        let permissionGeneration = generation
        for entity in [EKEntityType.event, .reminder] {
            guard generation == permissionGeneration, !Task.isCancelled else { break }
            if EKEventStore.authorizationStatus(for: entity) == .denied || EKEventStore.authorizationStatus(for: entity) == .restricted { continue }
            if Self.authorization(for: entity) == .ready { continue }
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let done: (Bool, Error?) -> Void = { granted, _ in continuation.resume(returning: granted) }
                if #available(macOS 14, *) {
                    if entity == .event { store.requestFullAccessToEvents(completion: done) }
                    else { store.requestFullAccessToReminders(completion: done) }
                } else { store.requestAccess(to: entity, completion: done) }
            }
        }
        invalidate()
        return (Self.authorization(for: .event), Self.authorization(for: .reminder))
    }
    private func startObserving() {
        guard !observing else { return }; observing = true
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in
            Task { await self?.invalidate() }
        }
    }
    func read(day: Date, enabled: Bool) async -> GoalongCalendarLane {
        guard enabled else { disable(); return .disabled }
        startObserving()
        let calendarPermission = Self.authorization(for: .event), remindersPermission = Self.authorization(for: .reminder)
        guard let interval = Calendar.current.dateInterval(of: .day, for: day) else {
            return .init(status: .failed("Date invalide."), calendarStatus: .failed("Date invalide."), remindersStatus: .failed("Date invalide."))
        }
        let key = GoalongSystemSourceFiles.dayKey(day) + "|" + TimeZone.current.identifier + "|\(calendarPermission)|\(remindersPermission)"
        let initialGeneration = generation
        if let cached = cache[key], cached.0 == generation { return cached.1 }
        var lane = GoalongCalendarLane(status: .noData, calendarStatus: calendarPermission, remindersStatus: remindersPermission)
        if calendarPermission == .ready {
            let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
            var exhausted = false
            let deadline = Date().addingTimeInterval(2)
            store.enumerateEvents(matching: predicate) { event, stop in
                guard lane.events.count < Self.maximumItems, Date() < deadline, !Task.isCancelled else { exhausted = true; stop.pointee = true; return }
                let start = max(event.startDate, interval.start), end = min(event.endDate, interval.end)
                guard end > start else { return }
                lane.events.append(.init(id: event.eventIdentifier ?? UUID().uuidString, start: start, end: end,
                    allDay: event.isAllDay, availability: event.availability.rawValue,
                    title: (event.title?.count ?? 0) <= 16_000 ? event.title ?? "" : "", calendarName: event.calendar.title.count <= 16_000 ? event.calendar.title : "",
                    attendeeCount: min(10_000, event.attendees?.count ?? 0)))
            }
            lane.events.sort { $0.start < $1.start }
            lane.calendarStatus = exhausted ? .partial : lane.events.isEmpty ? .noData : .ready
        }
        if remindersPermission == .ready {
            let completed = store.predicateForCompletedReminders(withCompletionDateStarting: interval.start, ending: interval.end, calendars: nil)
            let due = store.predicateForIncompleteReminders(withDueDateStarting: interval.start, ending: interval.end, calendars: nil)
            let doneRows = await reminders(matching: completed)
            let dueRows = await reminders(matching: due)
            lane.completedReminders = doneRows.rows.compactMap { row in
                guard let date = row.completionDate, date >= interval.start, date < interval.end else { return nil }
                return .init(completedAt: date, title: (row.title?.count ?? 0) <= 16_000 ? row.title ?? "" : "")
            }.sorted { $0.completedAt < $1.completedAt }
            lane.openDueReminderCount = dueRows.rows.filter { row in
                guard !row.isCompleted, let components = row.dueDateComponents else { return false }
                var calendar = components.calendar ?? Calendar.current
                calendar.timeZone = components.timeZone ?? Calendar.current.timeZone
                guard let date = calendar.date(from: components) else { return false }
                return date >= interval.start && date < interval.end
            }.count
            lane.remindersStatus = doneRows.partial || dueRows.partial ? .partial : lane.completedReminders.isEmpty && lane.openDueReminderCount == 0 ? .noData : .ready
        }
        guard generation == initialGeneration, !Task.isCancelled else {
            return .init(status: .partial, calendarStatus: .partial, remindersStatus: .partial)
        }
        if Self.authorization(for: .event) != calendarPermission || Self.authorization(for: .reminder) != remindersPermission {
            invalidate(); return .init(status: .permissionDenied, calendarStatus: Self.authorization(for: .event), remindersStatus: Self.authorization(for: .reminder))
        }
        let statuses = [lane.calendarStatus, lane.remindersStatus]
        lane.status = statuses.contains(.partial) ? .partial : statuses.contains(.permissionDenied) && statuses.contains(.ready) ? .partial : statuses.contains(.ready) ? .ready : statuses.contains(.permissionDenied) ? .permissionDenied : .noData
        if cache.count >= 64 { cache.removeAll() }; cache[key] = (generation, lane)
        return lane
    }
    private func reminders(matching predicate: NSPredicate) async -> (rows: [EKReminder], partial: Bool) {
        // A system callback can fail to arrive. One timeout ends this on-demand read; it is not polling.
        await withCheckedContinuation { continuation in
            let result = GoalongReminderReadCompletion(continuation)
            let token = store.fetchReminders(matching: predicate) { reminders in result.finish(reminders, partial: reminders == nil) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [store] in
                if result.finish(nil, partial: true) { store.cancelFetchRequest(token) }
            }
        }
    }
}
private final class GoalongReminderReadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(rows: [EKReminder], partial: Bool), Never>?
    init(_ continuation: CheckedContinuation<(rows: [EKReminder], partial: Bool), Never>) { self.continuation = continuation }
    @discardableResult func finish(_ rows: [EKReminder]?, partial: Bool) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return false }
        pending.resume(returning: (Array((rows ?? []).prefix(GoalongCalendarSource.maximumItems)), partial || (rows?.count ?? 0) > GoalongCalendarSource.maximumItems)); return true
    }
}
#endif
