#if os(macOS)
import SwiftUI
import Charts
import LocalHistoryCore

/// Focus is a subset of observed activity, not an additional stacked duration.
/// A narrower foreground bar is visible even when focus equals all active time.
struct GoalongFocusBar: ChartContent {
    let start: Date
    let seconds: Double
    let unitSeconds: Double
    var hourly = false

    var body: some ChartContent {
        if seconds > 0 {
            BarMark(x: .value(hourly ? "Heure" : "Jour", start, unit: hourly ? .hour : .day),
                    y: .value("Focus", seconds / unitSeconds),
                    width: .ratio(0.28), stacking: .unstacked)
                .foregroundStyle(LHTheme.teal)
                .cornerRadius(2)
                .accessibilityLabel("Focus observé, inclus dans le temps actif")
                .accessibilityValue(GoalongAnalyticsFormatting.duration(seconds))
        }
    }
}

struct GoalongHourlyFocusChart: View {
    let day: GoalongLocalAnalytics.Day
    let focusMinutes: Int
    let dateRange: ClosedRange<Date>
    let hourStride: Int

    var body: some View {
        let hours = day.hours(minimumMinutes: focusMinutes).filter { $0.seconds > 0 }
        let scale = GoalongAnalyticsChartScale(maximumSeconds: hours.map(\.seconds).max() ?? 0, hourly: true)
        Chart {
            ForEach(hours) { hour in
                BarMark(x: .value("Heure", hour.start, unit: .hour),
                        y: .value("Activité", hour.seconds / scale.unitSeconds), stacking: .unstacked)
                    .foregroundStyle(LHTheme.accent).cornerRadius(2)
                    .accessibilityLabel("Activité observée")
                    .accessibilityValue(GoalongAnalyticsFormatting.duration(hour.seconds))
            }
            // Render the subset last, above every activity bar; never add it to the total.
            ForEach(hours) { hour in
                GoalongFocusBar(start: hour.start, seconds: hour.focusSeconds,
                                unitSeconds: scale.unitSeconds, hourly: true)
            }
        }
        .chartLegend(.hidden).chartXScale(domain: dateRange).chartYScale(domain: 0...scale.upperBound)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hourStride)) { _ in
                AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).hour())
                AxisTick()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(scale.label(amount)) }
                }
            }
        }
        .frame(height: 200)
        .accessibilityIdentifier("activity-hourly-focus-chart")
    }
}

/// The definition and threshold are visible without opening a disclosure first.
struct GoalongFocusExplanation: View {
    let hasFocus: Bool
    @Binding var minimumMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Focus · séquence minimale").font(.system(size: 12, weight: .medium))
                Picker("Séquence minimale de focus", selection: $minimumMinutes) {
                    Text("10 min").tag(10)
                    Text("25 min").tag(25)
                    Text("50 min").tag(50)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 210)
                .accessibilityIdentifier("analytics-focus-threshold")
                Spacer(minLength: 0)
            }
            Text(hasFocus
                ? "Le focus correspond aux séquences continues dans une même application et sur un même site. Les barres turquoise sont incluses dans le temps actif, pas ajoutées."
                : "Aucune séquence continue d’au moins \(minimumMinutes) minutes dans une même application et sur un même site n’a été détectée. Cela ne signifie pas que vous n’avez pas travaillé ou été concentré.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Changer d’outil peut interrompre cette mesure, même pour le même projet. Elle ne mesure pas votre attention mentale.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("activity-focus-definition")
    }
}
#endif
