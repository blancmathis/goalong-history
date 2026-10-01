import Foundation

/// Continuous work on one task that tolerates brief detours (a message, a lookup, a
/// short pause) and application switches. Only intervals classified as work count
/// towards `workSeconds`; the detours are part of the span, not of the work time.
public struct GoalongWorkBlock: Identifiable, Equatable, Sendable {
    public let start: Date
    public var end: Date
    public var workSeconds: TimeInterval
    public var task: String? = nil
    public var id: Date { start }
    public var spanSeconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

extension GoalongLocalAnalytics.Day {
    public var firstActiveStart: Date? { segments.first { $0.kind.isActive && $0.seconds > 0 }?.start }
    public var lastActiveEnd: Date? { segments.last { $0.kind.isActive && $0.seconds > 0 }?.end }

    /// Work on one task separated by at most `toleranceSeconds` of anything else stays in
    /// one block, whichever applications it used. Changing task starts a new block.
    public func workBlocks(minimumMinutes: Int, toleranceSeconds: TimeInterval = 120) -> [GoalongWorkBlock] {
        var blocks: [GoalongWorkBlock] = []
        for segment in segments where segment.kind == .work && segment.seconds > 0 {
            if let last = blocks.last, segment.start.timeIntervalSince(last.end) <= toleranceSeconds,
               last.task == nil || segment.task == nil || last.task == segment.task {
                blocks[blocks.count - 1].end = segment.end
                blocks[blocks.count - 1].workSeconds += segment.seconds
                if blocks[blocks.count - 1].task == nil { blocks[blocks.count - 1].task = segment.task }
            } else {
                blocks.append(GoalongWorkBlock(start: segment.start, end: segment.end, workSeconds: segment.seconds,
                                               task: segment.task))
            }
        }
        let minimum = Double(max(1, minimumMinutes)) * 60
        return blocks.filter { $0.workSeconds >= minimum }
    }
}

extension GoalongLocalAnalytics.Period {
    public var otherSeconds: TimeInterval { days.reduce(0) { $0 + $1.seconds(.other) } }
    public var unclassifiedSeconds: TimeInterval { days.reduce(0) { $0 + $1.seconds(.unclassified) } }
    public var observedDays: [GoalongLocalAnalytics.Day] { days.filter { $0.state == .ready && $0.activeSeconds > 0 } }

    public func workBlocks(minimumMinutes: Int, toleranceSeconds: TimeInterval = 120) -> [GoalongWorkBlock] {
        days.flatMap { $0.workBlocks(minimumMinutes: minimumMinutes, toleranceSeconds: toleranceSeconds) }
    }

    /// Mean active time between two switches of application or site; nil without switches.
    public var secondsPerContextChange: TimeInterval? {
        let changes = contextChanges
        guard changes > 0, activeSeconds > 0 else { return nil }
        return activeSeconds / Double(changes)
    }

    /// Active seconds per clock hour (0–23) summed over the period.
    public func activeSecondsByHourOfDay(calendar: Calendar = .current) -> [TimeInterval] {
        var totals = Array(repeating: 0.0, count: 24)
        for day in days where day.state == .ready {
            for segment in day.segments where segment.kind.isActive && segment.seconds > 0 {
                Self.distribute(segment, calendar: calendar) { hour, seconds in totals[hour] += seconds }
            }
        }
        return totals
    }

    /// Seconds classified as work per clock hour (0–23) summed over the period.
    public func workSecondsByHourOfDay(calendar: Calendar = .current) -> [TimeInterval] {
        var totals = Array(repeating: 0.0, count: 24)
        for day in days where day.state == .ready {
            for segment in day.segments where segment.kind == .work && segment.seconds > 0 {
                Self.distribute(segment, calendar: calendar) { hour, seconds in totals[hour] += seconds }
            }
        }
        return totals
    }

    /// Average active seconds for each weekday × clock hour, over the days of that weekday
    /// that have observations. Rows follow `calendar.weekdaySymbols` order (index 0 = Sunday
    /// in the Gregorian calendar). A weekday without observed days stays nil, never zero.
    public func averageActiveSecondsByWeekdayAndHour(calendar: Calendar = .current) -> [[TimeInterval]?] {
        var totals = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var dayCounts = Array(repeating: 0, count: 7)
        for day in observedDays {
            let weekday = calendar.component(.weekday, from: day.date) - 1
            guard (0..<7).contains(weekday) else { continue }
            dayCounts[weekday] += 1
            for segment in day.segments where segment.kind.isActive && segment.seconds > 0 {
                Self.distribute(segment, calendar: calendar) { hour, seconds in totals[weekday][hour] += seconds }
            }
        }
        return (0..<7).map { index in
            dayCounts[index] == 0 ? nil : totals[index].map { $0 / Double(dayCounts[index]) }
        }
    }

    private static func distribute(_ segment: GoalongLocalAnalytics.Segment, calendar: Calendar,
                                   _ add: (Int, TimeInterval) -> Void) {
        var cursor = segment.start
        var guardCount = 0
        while cursor < segment.end, guardCount < 48 {
            guardCount += 1
            guard let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end, hourEnd > cursor else { return }
            let stop = min(segment.end, hourEnd)
            let hour = calendar.component(.hour, from: cursor)
            if (0..<24).contains(hour) { add(hour, stop.timeIntervalSince(cursor)) }
            cursor = stop
        }
    }
}
