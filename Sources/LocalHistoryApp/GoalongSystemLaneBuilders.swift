#if os(macOS)
import Foundation
import LocalHistoryCore

// MARK: - From the system sources to the day's lanes

extension GoalongSourceRow.State {
    init(_ status: GoalongSystemSourceStatus) {
        switch status {
        case .disabled: self = .off
        case .permissionDenied: self = .needsPermission
        case .unsupported: self = .unavailable
        case .noData: self = .noData
        case .partial: self = .partial
        case .ready: self = .ready
        case .failed: self = .failed
        }
    }
}

extension GoalongAgendaDay {
    /// Calls and agenda of one day; nil when both sources are off. Titles stay in memory.
    init?(calls: GoalongCallLane, calendar: GoalongCalendarLane,
          calendarPermission: GoalongSystemSourceStatus, remindersPermission: GoalongSystemSourceStatus) {
        let callsOn = calls.status != .disabled, calendarOn = calendar.status != .disabled
        guard callsOn || calendarOn else { return nil }
        let spans = calls.intervals.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        let merged = GoalongIntervals.merged(spans)
        self.init()
        self.callsOn = callsOn
        self.calendarOn = calendarOn
        self.calls = spans
        events = calendar.events.filter(\.isPlannedBusy).sorted { $0.start < $1.start }.map { event in
            let span = DateInterval(start: event.start, end: max(event.start, event.end))
            return Event(id: event.id, start: event.start, end: event.end, title: event.title, attendees: event.attendeeCount,
                         callSeconds: merged.reduce(0) { $0 + ($1.intersection(with: span)?.duration ?? 0) })
        }
        var byApplication: [String: [DateInterval]] = [:]
        for (interval, span) in zip(calls.intervals, spans) { byApplication[Self.application(interval), default: []].append(span) }
        callApplications = byApplication
            .map { Share(id: $0.key, seconds: GoalongIntervals.merged($0.value).reduce(0) { $0 + $1.duration }) }
            .filter { $0.seconds >= 1 }
            .sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
        reminders = calendar.completedReminders.sorted { $0.completedAt < $1.completedAt }.enumerated().map { index, reminder in
            Reminder(id: "\(index)", completedAt: reminder.completedAt, title: reminder.title)
        }
        openDueReminders = calendar.openDueReminderCount
        let permissions = [calendarPermission, remindersPermission]
        calendarAccess = !calendarOn || permissions.allSatisfy { $0 == .ready } ? .granted
            : permissions.contains(.permissionDenied) ? .denied : .notAsked
        partial = [calls.status, calendar.status].contains { status in
            if case .failed = status { return true }
            return status == .partial
        }
    }

    /// The app behind a call; the camera is only known per device, never per app.
    static func application(_ interval: GoalongCallInterval) -> String {
        if let name = interval.application { return name }
        if let bundle = interval.bundleIdentifier { return bundle }
        switch (interval.microphone, interval.camera) {
        case (true, true): return "Micro et caméra (app inconnue)"
        case (false, true): return "Caméra (app inconnue)"
        default: return "Micro (app inconnue)"
        }
    }
}

extension GoalongSleepDay {
    /// Phases in the order of Apple Santé; the total itself is not a phase.
    static let phases: [(key: String, name: String)] = [
        ("sleepDeepSeconds", "Sommeil profond"), ("sleepCoreSeconds", "Sommeil essentiel"),
        ("sleepREMSeconds", "Sommeil paradoxal"), ("sleepUnspecifiedSeconds", "Sommeil sans phase"),
        ("sleepAwakeSeconds", "Éveillé"), ("sleepInBedSeconds", "Au lit"),
    ]

    /// An Apple Health import for this date; nil without an import. Every import is a snapshot,
    /// which the section already says, so it is not marked partial.
    init?(_ health: GoalongHealthLane) {
        guard health.status == .ready || health.status == .partial else { return nil }
        self.init(sleepSeconds: health.sleepSeconds,
                  stages: Self.phases.compactMap { phase in
                      health.sleepStages[phase.key].flatMap { $0 >= 60 ? GoalongAgendaDay.Share(id: phase.name, seconds: $0) : nil }
                  },
                  steps: health.steps.map { Int($0.rounded()) }, workouts: health.workoutCount,
                  workoutSeconds: health.workoutSeconds, label: health.sleepLabel)
    }
}

extension GoalongOtherDevicesDay {
    /// The other Apple devices seen by Screen Time; nil without a device.
    init?(_ lane: GoalongOtherDevicesLane) {
        guard lane.status == .ready || lane.status == .partial, !lane.devices.isEmpty else { return nil }
        self.init(devices: lane.devices.map {
            Device(id: $0.id, name: $0.device.displayName, screenOnSeconds: $0.screenOnSeconds,
                   duringGapsSeconds: $0.duringMacGapsSeconds, estimated: $0.estimated)
        }.sorted { $0.duringGapsSeconds == $1.duringGapsSeconds ? $0.name < $1.name : $0.duringGapsSeconds > $1.duringGapsSeconds },
                  partial: lane.status == .partial)
    }
}
#endif
