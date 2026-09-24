#if os(macOS)
import AppleScreenTime
import Foundation

/// Apple-only rows. This type deliberately has no input for Goalong's recorder:
/// a different date, device or missing Apple read cannot leak local usage into this page.
enum GoalongAppleUsageFilter: String, CaseIterable, Identifiable {
    case applications, websites
    var id: String { rawValue }
    var title: String { self == .applications ? "Applications" : "Sites Apple" }
}

struct GoalongAppleUsageRow: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let host: String?
    let seconds: TimeInterval
    var isWebsite: Bool { host != nil }
}

enum GoalongAppleUsageProjection {
    static func rows(_ summary: AppleScreenTimeDaySummary?) -> [GoalongAppleUsageRow] {
        guard let summary else { return [] }
        return OverviewUsageProjection.appleApplications(summary).compactMap { app in
            guard app.duration.isFinite, app.duration > 0 else { return nil }
            let bundle = app.bundleIdentifier
            let host = bundle?.lowercased().hasPrefix("website:") == true
                ? String(bundle!.dropFirst("website:".count)) : nil
            return GoalongAppleUsageRow(id: app.id, name: host ?? app.resolvedName,
                bundleIdentifier: host == nil ? bundle : nil, host: host, seconds: app.duration)
        }.sorted { left, right in
            if left.seconds != right.seconds { return left.seconds > right.seconds }
            return left.id < right.id
        }
    }

    static func visibleRows(_ rows: [GoalongAppleUsageRow], filter: GoalongAppleUsageFilter,
                            search: String) -> [GoalongAppleUsageRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            row.isWebsite == (filter == .websites)
                && (query.isEmpty || row.name.localizedStandardContains(query)
                    || row.bundleIdentifier?.localizedStandardContains(query) == true)
        }
    }
}
#endif
