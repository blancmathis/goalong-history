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

/// Titles remain in this actor's memory. Nothing is persisted or changed. The backend is EventKit unless a test gives another.
actor GoalongCalendarSource {
    static let shared = GoalongCalendarSource()
    private let fixedBackend: (any GoalongCalendarBackend)?
    private var generation = 0
    private var cache: [String: (Int, GoalongCalendarLane)] = [:]
    private var observer: NSObjectProtocol?
    private var observedRevision: Int?
    static let maximumItems = 1000
    static let maximumTextLength = 16_000

    /// `backend` nil follows `GoalongCalendarBackends.current`.
    init(backend: (any GoalongCalendarBackend)? = nil) { fixedBackend = backend }
    private var backend: any GoalongCalendarBackend { fixedBackend ?? GoalongCalendarBackends.current }
    /// A source made for one backend never sees it change.
    private var backendRevision: Int { fixedBackend == nil ? GoalongCalendarBackends.revision : 0 }

    static func authorization(for entity: EKEntityType) -> GoalongSystemSourceStatus {
        GoalongCalendarBackends.current.authorization(for: entity)
    }
    func invalidate() { generation += 1; cache.removeAll() }
    func disable() { invalidate() }
    func requestAccess(enabled: Bool) async -> (calendar: GoalongSystemSourceStatus, reminders: GoalongSystemSourceStatus) {
        guard enabled else { return (.disabled, .disabled) }
        let permissionGeneration = generation
        let backend = backend
        for entity in [EKEntityType.event, .reminder] {
            guard generation == permissionGeneration, !Task.isCancelled else { break }
            let status = backend.authorization(for: entity)
            if status == .permissionDenied || status == .ready { continue }
            await backend.requestAccess(for: entity)
        }
        invalidate()
        return (backend.authorization(for: .event), backend.authorization(for: .reminder))
    }
    private func startObserving(_ backend: any GoalongCalendarBackend, revision: Int) {
        guard observedRevision != revision else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observedRevision = revision
        observer = backend.observeChanges { [weak self] in Task { await self?.invalidate() } }
    }
    private static func bounded(_ text: String?) -> String { (text?.count ?? 0) <= maximumTextLength ? text ?? "" : "" }
    func read(day: Date, enabled: Bool, calendar: Calendar = .current) async -> GoalongCalendarLane {
        guard enabled else { disable(); return .disabled }
        let backend = backend, revision = backendRevision
        startObserving(backend, revision: revision)
        let calendarPermission = backend.authorization(for: .event), remindersPermission = backend.authorization(for: .reminder)
        guard let interval = calendar.dateInterval(of: .day, for: day) else {
            return .init(status: .failed("Date invalide."), calendarStatus: .failed("Date invalide."), remindersStatus: .failed("Date invalide."))
        }
        let key = GoalongSystemSourceFiles.dayKey(day) + "|" + calendar.timeZone.identifier + "|\(calendarPermission)|\(remindersPermission)|\(revision)"
        let initialGeneration = generation
        if let cached = cache[key], cached.0 == generation { return cached.1 }
        var lane = GoalongCalendarLane(status: .noData, calendarStatus: calendarPermission, remindersStatus: remindersPermission)
        if calendarPermission == .ready {
            var exhausted = false
            let deadline = Date().addingTimeInterval(2)
            backend.enumerateEvents(start: interval.start, end: interval.end) { event in
                guard lane.events.count < Self.maximumItems, Date() < deadline, !Task.isCancelled else { exhausted = true; return false }
                let start = max(event.start, interval.start), end = min(event.end, interval.end)
                guard end > start else { return true }
                lane.events.append(.init(id: event.id ?? UUID().uuidString, start: start, end: end,
                    allDay: event.allDay, availability: event.availability,
                    title: Self.bounded(event.title), calendarName: Self.bounded(event.calendarName),
                    attendeeCount: min(10_000, event.attendeeCount)))
                return true
            }
            lane.events.sort { $0.start < $1.start }
            lane.calendarStatus = exhausted ? .partial : lane.events.isEmpty ? .noData : .ready
        }
        if remindersPermission == .ready {
            let doneRows = await backend.completedReminders(start: interval.start, end: interval.end)
            let dueRows = await backend.dueReminders(start: interval.start, end: interval.end)
            lane.completedReminders = doneRows.rows.compactMap { row in
                guard let date = row.completionDate, date >= interval.start, date < interval.end else { return nil }
                return .init(completedAt: date, title: Self.bounded(row.title))
            }.sorted { $0.completedAt < $1.completedAt }
            lane.openDueReminderCount = dueRows.rows.filter { row in
                guard !row.isCompleted, let components = row.due else { return false }
                var zoned = components.calendar ?? calendar
                zoned.timeZone = components.timeZone ?? calendar.timeZone
                guard let date = zoned.date(from: components) else { return false }
                return date >= interval.start && date < interval.end
            }.count
            lane.remindersStatus = doneRows.partial || dueRows.partial ? .partial : lane.completedReminders.isEmpty && lane.openDueReminderCount == 0 ? .noData : .ready
        }
        guard generation == initialGeneration, !Task.isCancelled else {
            return .init(status: .partial, calendarStatus: .partial, remindersStatus: .partial)
        }
        if backend.authorization(for: .event) != calendarPermission || backend.authorization(for: .reminder) != remindersPermission {
            invalidate(); return .init(status: .permissionDenied, calendarStatus: backend.authorization(for: .event), remindersStatus: backend.authorization(for: .reminder))
        }
        let statuses = [lane.calendarStatus, lane.remindersStatus]
        lane.status = statuses.contains(.partial) ? .partial : statuses.contains(.permissionDenied) && statuses.contains(.ready) ? .partial : statuses.contains(.ready) ? .ready : statuses.contains(.permissionDenied) ? .permissionDenied : .noData
        if cache.count >= 64 { cache.removeAll() }; cache[key] = (generation, lane)
        return lane
    }
}
#endif
