#if os(macOS)
import Foundation
import LocalHistoryCore

/// Window-local navigation. Preview uses a separate value; nothing is persisted.
struct GoalongActivityNavigation: Equatable {
    struct Context: Equatable {
        let day: Date
        let period: Int
    }

    private(set) var day: Date
    private(set) var period: Int
    private(set) var returnContext: Context?

    init(day: Date = Date(), period: Int = 1, calendar: Calendar = .current) {
        self.day = calendar.startOfDay(for: day)
        self.period = [1, 7, 28].contains(period) ? period : 1
    }

    func interval(calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: 1 - period, to: day) ?? day
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return DateInterval(start: start, end: end)
    }

    mutating func selectDay(_ value: Date, now: Date = Date(), calendar: Calendar = .current) {
        day = min(calendar.startOfDay(for: value), calendar.startOfDay(for: now))
        returnContext = nil
    }

    mutating func selectPeriod(_ value: Int) {
        guard [1, 7, 28].contains(value) else { return }
        period = value
        returnContext = nil
    }

    mutating func step(_ direction: Int, now: Date = Date(), calendar: Calendar = .current) {
        guard direction == -1 || direction == 1,
              let next = calendar.date(byAdding: .day, value: direction * period, to: day) else { return }
        selectDay(next, now: now, calendar: calendar)
    }

    mutating func today(now: Date = Date(), calendar: Calendar = .current) {
        day = calendar.startOfDay(for: now)
        period = 1
        returnContext = nil
    }

    mutating func openDay(_ value: Date, now: Date = Date(), calendar: Calendar = .current) {
        if period > 1 { returnContext = Context(day: day, period: period) }
        day = min(calendar.startOfDay(for: value), calendar.startOfDay(for: now))
        period = 1
    }

    mutating func restorePeriod() {
        guard let previous = returnContext else { return }
        day = previous.day
        period = previous.period
        returnContext = nil
    }

    /// Also guards the frame before the asynchronous task has cleared its old payload.
    func matches(_ payload: GoalongAnalyticsPayload, preview: Bool, calendar: Calendar = .current) -> Bool {
        payload.isPreview == preview && payload.current.days.count == period
            && payload.current.days.last.map { calendar.isDate($0.date, inSameDayAs: day) } == true
    }
}

enum GoalongActivityUsageGrouping: String, CaseIterable, Identifiable {
    case sites, applications
    var id: String { rawValue }
    var title: String { self == .sites ? "Apps et sites" : "Par application" }
}

struct GoalongActivityUsageItem: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let isWebsite: Bool
    var seconds: TimeInterval
}

/// Both groupings partition the very same foreground intervals. A website replaces
/// its browser interval; it never adds another copy of those seconds.
enum GoalongActivityProjection {
    static func usageID(_ segment: GoalongLocalAnalytics.Segment,
                        grouping: GoalongActivityUsageGrouping) -> String? {
        guard segment.kind.isActive else { return nil }
        if grouping == .sites, let host = segment.host, !host.isEmpty { return "site:" + host }
        return "app:" + (segment.bundleIdentifier ?? segment.application ?? "unattributed")
    }

    static func usage(_ period: GoalongLocalAnalytics.Period,
                      grouping: GoalongActivityUsageGrouping) -> [GoalongActivityUsageItem] {
        var result: [String: GoalongActivityUsageItem] = [:]
        for day in period.days {
            for segment in day.segments {
                guard let id = usageID(segment, grouping: grouping) else { continue }
                let website = id.hasPrefix("site:")
                var item = result[id] ?? GoalongActivityUsageItem(
                    id: id,
                    name: website ? (segment.host ?? "Site") : (segment.application ?? "Activité non attribuée"),
                    bundleIdentifier: website ? nil : segment.bundleIdentifier,
                    isWebsite: website,
                    seconds: 0
                )
                item.seconds += segment.seconds
                result[id] = item
            }
        }
        return result.values.sorted { a, b in
            a.seconds == b.seconds ? a.id < b.id : a.seconds > b.seconds
        }
    }

    static func seconds(for item: GoalongActivityUsageItem, in day: GoalongLocalAnalytics.Day,
                        grouping: GoalongActivityUsageGrouping) -> TimeInterval {
        day.segments.filter { usageID($0, grouping: grouping) == item.id }
            .reduce(0) { $0 + $1.seconds }
    }

    static func hasClassification(_ period: GoalongLocalAnalytics.Period) -> Bool {
        period.days.contains { $0.seconds(.work) + $0.seconds(.other) > 0 }
    }

    static func canCompare(_ current: GoalongLocalAnalytics.Period,
                           to previous: GoalongLocalAnalytics.Period,
                           calendar: Calendar = .current) -> Bool {
        guard !current.days.isEmpty, current.days.count == previous.days.count,
              current.classifierVersions == previous.classifierVersions else { return false }
        return (current.days + previous.days).allSatisfy { day in
            guard day.state == .ready, day.activeSeconds > 0,
                  let end = calendar.date(byAdding: .day, value: 1, to: day.date) else { return false }
            return day.end >= end
        }
    }

    static func dayLabel(_ day: GoalongLocalAnalytics.Day) -> String {
        if day.state == .incomplete { return "Lecture incomplète" }
        if day.activeSeconds > 0 { return GoalongAnalyticsFormatting.duration(day.activeSeconds) + " actives" }
        if day.observedSeconds > 0 { return "0 min actives observées" }
        return day.eventCount > 0 ? "Premières traces · durée non mesurable" : "Sans enregistrement"
    }
}
#endif
