#if os(macOS)
import Foundation
import LocalHistoryCore

enum GoalongActivityUsageSort: String, CaseIterable, Identifiable {
    case duration, name
    var id: String { rawValue }
    var title: String { self == .duration ? "Durée décroissante" : "Nom A–Z" }
}

extension GoalongActivityUsageItem {
    var displayName: String { GoalongActivityPresentation.displayName(name) }
}

enum GoalongActivityPresentation {
    static func displayName(_ value: String) -> String {
        let invisible = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter { !invisible.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Activité non attribuée" : cleaned
    }

    static func usage(_ items: [GoalongActivityUsageItem], search: String,
                      sort: GoalongActivityUsageSort) -> [GoalongActivityUsageItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { query.isEmpty || $0.displayName.localizedStandardContains(query)
            || $0.bundleIdentifier?.localizedStandardContains(query) == true }
            .sorted { a, b in
                if sort == .duration && a.seconds != b.seconds { return a.seconds > b.seconds }
                let comparison = a.displayName.localizedStandardCompare(b.displayName)
                return comparison == .orderedSame ? a.id < b.id : comparison == .orderedAscending
            }
    }

    /// Only the chart viewport is cropped; totals and the complete history are untouched.
    /// Calendar hour boundaries preserve 23/25-hour days and half-hour time zones.
    static func chartRange(_ day: GoalongLocalAnalytics.Day, fullDay: Bool,
                           calendar: Calendar = .current) -> ClosedRange<Date> {
        let dayStart = calendar.startOfDay(for: day.date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let observed = day.segments.filter { $0.kind != .unobserved && $0.end > $0.start }
        guard !fullDay, let first = observed.map(\.start).min(), let last = observed.map(\.end).max() else {
            return dayStart...dayEnd
        }
        let start = max(dayStart, calendar.dateInterval(of: .hour, for: first)?.start ?? first)
        let lastHour = calendar.dateInterval(of: .hour, for: last.addingTimeInterval(-0.001))
        let minimumEnd = calendar.date(byAdding: .hour, value: 3, to: start) ?? start.addingTimeInterval(10800)
        let end = min(dayEnd, max(lastHour?.end ?? last, minimumEnd))
        return start...max(start.addingTimeInterval(1), end)
    }
}
#endif
