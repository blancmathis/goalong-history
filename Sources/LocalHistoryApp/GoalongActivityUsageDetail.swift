#if os(macOS)
import Foundation
import SwiftUI
import Charts
import LocalHistoryCore

/// One application or website over the selected period: how much, when, which tasks it
/// served and how it evolves. Every figure comes from the same intervals as the list.
struct GoalongActivityUsageDetail: View {
    let item: GoalongActivityUsageItem
    let period: GoalongLocalAnalytics.Period
    let grouping: GoalongActivityUsageGrouping
    let isPreview: Bool
    let onHistoryDay: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    private var visibleDays: [GoalongLocalAnalytics.Day] {
        period.days.filter { GoalongActivityProjection.seconds(for: item, in: $0, grouping: grouping) > 0 }
    }
    private var sessions: [GoalongActivityProjection.Session] {
        GoalongActivityProjection.sessions(for: item, in: period, grouping: grouping)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GoalongActivityUsageIcon(item: item, size: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(.system(size: 20, weight: .semibold)).textSelection(.enabled)
                        .lineLimit(2).help(item.displayName)
                    Text((item.isWebsite ? "Site web" : "Application") + (isPreview ? " · exemple fictif" : ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            statistics
            if !item.mainTasks.isEmpty { tasks }
            hourChart
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(visibleDays, id: \.date) { day in dayRow(day) }
                }.font(.system(size: 13))
            }.frame(maxHeight: 300)
            Text("Observations sur ce Mac uniquement. Un site n’est jamais ajouté une seconde fois au temps de son navigateur.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 600).frame(maxHeight: 760)
        .tint(LHTheme.accent)
    }

    /// The same application can serve several tasks: each one is listed with its time.
    private var tasks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tâches servies").font(.system(size: 12, weight: .semibold))
            ForEach(item.mainTasks.prefix(5), id: \.name) { task in
                HStack {
                    Text(task.name).lineLimit(1)
                    Spacer()
                    Text(duration(task.seconds)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.system(size: 12)).accessibilityElement(children: .combine)
            }
        }.accessibilityIdentifier("activity-usage-detail-tasks")
    }

    private var statistics: some View {
        let share = item.seconds / max(1, period.activeSeconds)
        let longest = sessions.map(\.seconds).max() ?? 0
        let average = sessions.isEmpty ? 0 : item.seconds / Double(sessions.count)
        let columns = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading),
                       GridItem(.flexible(), alignment: .topLeading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            stat("Temps total", duration(item.seconds), "\(Int((share * 100).rounded()))\u{00A0}% du temps actif")
            if period.days.count > 1 {
                stat("Jours d’utilisation", "\(visibleDays.count)", "sur \(period.days.count) jours")
            } else if let first = sessions.first, let last = sessions.last {
                stat("Utilisé", "\(GoalongActivitySummary.time(first.start)) – \(GoalongActivitySummary.time(last.end))", "première et dernière fois")
            }
            stat("Séances", "\(sessions.count)", "séparées par plus de 2 min")
            stat("Durée moyenne", duration(average), "par séance")
            stat("Plus longue séance", duration(longest), longestLabel)
            if let before = item.previousSeconds {
                let delta = item.seconds - before
                stat("Évolution", (delta >= 0 ? "+" : "−") + duration(abs(delta)), "vs période précédente (\(duration(before)))")
            }
            if item.workSeconds + item.otherSeconds > 0 {
                stat("Travail", duration(item.workSeconds), item.otherSeconds > 0 ? "\(duration(item.otherSeconds)) hors travail" : "selon votre définition")
            }
        }
    }

    private var longestLabel: String {
        guard let session = sessions.max(by: { $0.seconds < $1.seconds }) else { return "" }
        return period.days.count > 1
            ? GoalongActivitySummary.weekdayDate(session.start) + " à " + GoalongActivitySummary.time(session.start)
            : "à partir de " + GoalongActivitySummary.time(session.start)
    }

    private var hourChart: some View {
        let hours = GoalongActivityProjection.secondsByHour(for: item, in: period, grouping: grouping)
        let days = max(1, visibleDays.count)
        let maximum = (hours.max() ?? 0) / Double(days)
        let unit: Double = maximum >= 3600 ? 3600 : 60
        return VStack(alignment: .leading, spacing: 8) {
            Text(period.days.count > 1 ? "À quelles heures · moyenne par jour d’utilisation" : "À quelles heures")
                .font(.system(size: 12, weight: .semibold))
            Chart {
                ForEach(0..<24, id: \.self) { hour in
                    BarMark(x: .value("Heure", hour), y: .value("Durée", hours[hour] / Double(days) / unit))
                        .foregroundStyle(LHTheme.accent.opacity(0.85)).cornerRadius(2)
                        .accessibilityLabel("\(hour) h").accessibilityValue(duration(hours[hour] / Double(days)))
                }
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel { if let hour = value.as(Int.self) { Text("\(hour) h") } }
            } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { Text(unit == 3600 ? "\(amount.formatted()) h" : "\(Int(amount)) min") } }
            } }
            .frame(height: 110)
        }.accessibilityIdentifier("activity-usage-detail-hours")
    }

    private func stat(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            if !caption.isEmpty { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
        }.accessibilityElement(children: .combine)
    }

    private func dayRow(_ day: GoalongLocalAnalytics.Day) -> some View {
        let seconds = GoalongActivityProjection.seconds(for: item, in: day, grouping: grouping)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(GoalongUIFormat.day(day.date)).fontWeight(.medium)
                Spacer()
                Text(duration(seconds)).monospacedDigit()
            }
            if period.days.count == 1 { segmentRows(day) }
            Button("Voir cette journée dans l’historique") { onHistoryDay(day.date) }
                .buttonStyle(.borderless).disabled(isPreview)
            Divider()
        }
    }

    private func segmentRows(_ day: GoalongLocalAnalytics.Day) -> some View {
        let daySessions = GoalongActivityProjection.sessions(for: item, in: .init(days: [day]), grouping: grouping)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(daySessions.prefix(50))) { session in
                HStack {
                    Text("\(GoalongActivitySummary.time(session.start))–\(GoalongActivitySummary.time(session.end))")
                    Spacer()
                    Text(duration(session.seconds))
                }.foregroundStyle(.secondary).accessibilityElement(children: .combine)
            }
            if daySessions.count > 50 {
                Text("50 séances affichées. L’historique contient le détail complet.").foregroundStyle(.secondary)
            }
        }
    }

    private func duration(_ value: TimeInterval) -> String { GoalongAnalyticsFormatting.duration(value) }
}

extension GoalongActivityProjection {
    struct Session: Identifiable, Equatable {
        let start: Date
        var end: Date
        var seconds: TimeInterval
        var id: Date { start }
    }

    /// Consecutive intervals of one usage separated by at most `toleranceSeconds`.
    static func sessions(for item: GoalongActivityUsageItem, in period: GoalongLocalAnalytics.Period,
                         grouping: GoalongActivityUsageGrouping, toleranceSeconds: TimeInterval = 120) -> [Session] {
        var result: [Session] = []
        for day in period.days {
            for segment in day.segments where usageID(segment, grouping: grouping) == item.id && segment.seconds > 0 {
                if let last = result.last, segment.start.timeIntervalSince(last.end) <= toleranceSeconds {
                    result[result.count - 1].end = segment.end
                    result[result.count - 1].seconds += segment.seconds
                } else {
                    result.append(Session(start: segment.start, end: segment.end, seconds: segment.seconds))
                }
            }
        }
        return result
    }

    /// Seconds of one usage per clock hour (0–23), summed over the period.
    static func secondsByHour(for item: GoalongActivityUsageItem, in period: GoalongLocalAnalytics.Period,
                              grouping: GoalongActivityUsageGrouping, calendar: Calendar = .current) -> [TimeInterval] {
        var totals = Array(repeating: 0.0, count: 24)
        for day in period.days {
            for segment in day.segments where usageID(segment, grouping: grouping) == item.id && segment.seconds > 0 {
                var cursor = segment.start
                while cursor < segment.end {
                    guard let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end, hourEnd > cursor else { break }
                    let stop = min(segment.end, hourEnd)
                    totals[calendar.component(.hour, from: cursor)] += stop.timeIntervalSince(cursor)
                    cursor = stop
                }
            }
        }
        return totals
    }
}
#endif
