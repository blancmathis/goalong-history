#if os(macOS)
import Foundation
import SwiftUI
import LocalHistoryCore

/// Typed rows keep day and interval result builders small and independently checked.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(item.name).font(.system(size: 20, weight: .semibold)).textSelection(.enabled)
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(GoalongAnalyticsFormatting.duration(item.seconds)) sur la période sélectionnée\(isPreview ? " · exemple fictif" : "")")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(visibleDays, id: \.date) { day in dayRow(day) }
                }.font(.system(size: 13))
            }.frame(maxHeight: 460)
            Text("Observations sur ce Mac uniquement. Les sites ne sont pas ajoutés une seconde fois au navigateur.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 540)
    }

    private func dayRow(_ day: GoalongLocalAnalytics.Day) -> some View {
        let seconds = GoalongActivityProjection.seconds(for: item, in: day, grouping: grouping)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(GoalongUIFormat.day(day.date)).fontWeight(.medium)
                Spacer()
                Text(GoalongAnalyticsFormatting.duration(seconds)).monospacedDigit()
            }
            if period.days.count == 1 { segmentRows(day) }
            Button("Voir cette journée dans l’historique") { onHistoryDay(day.date) }
                .buttonStyle(.borderless).disabled(isPreview)
            Divider()
        }
    }

    private func segmentRows(_ day: GoalongLocalAnalytics.Day) -> some View {
        let segments = day.segments.filter { GoalongActivityProjection.usageID($0, grouping: grouping) == item.id }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.prefix(50)), id: \.start) { segment in segmentRow(segment) }
            if segments.count > 50 {
                Text("50 plages affichées. L’historique contient le détail complet.").foregroundStyle(.secondary)
            }
        }
    }

    private func segmentRow(_ segment: GoalongLocalAnalytics.Segment) -> some View {
        HStack {
            Text("\(timeLabel(segment.start))–\(timeLabel(segment.end))")
            Spacer()
            Text(GoalongAnalyticsFormatting.duration(segment.seconds))
        }.foregroundStyle(.secondary).accessibilityElement(children: .combine)
    }

    private func timeLabel(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour().minute())
    }
}
#endif
