#if os(macOS)
import SwiftUI
import Charts
import LocalHistoryCore

/// Shared vocabulary for the three active states, used by every chart and list.
enum GoalongActivityClassStyle {
    static let order: [GoalongLocalAnalytics.Kind] = [.work, .other, .unclassified]

    static func label(_ kind: GoalongLocalAnalytics.Kind) -> String {
        switch kind {
        case .work: return "Travail"
        case .other: return "Hors travail"
        case .unclassified: return "À classer"
        case .idle: return "Sans interaction"
        case .concealed: return "Privé / suspendu"
        case .unobserved: return "Non observé"
        }
    }

    static func color(_ kind: GoalongLocalAnalytics.Kind) -> Color {
        switch kind {
        case .work: return LHTheme.accent
        case .other: return LHTheme.warning
        case .unclassified: return LHTheme.secondaryText.opacity(0.55)
        case .idle: return LHTheme.privateTint
        case .concealed: return LHTheme.teal.opacity(0.45)
        case .unobserved: return LHTheme.separator
        }
    }

    static var scale: KeyValuePairs<String, Color> {
        [label(.work): color(.work), label(.other): color(.other), label(.unclassified): color(.unclassified)]
    }
}

struct GoalongActivityClassLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            ForEach(GoalongActivityClassStyle.order, id: \.rawValue) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(GoalongActivityClassStyle.color(kind)).frame(width: 10, height: 10)
                    Text(GoalongActivityClassStyle.label(kind))
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Hour by hour, split into work, other and still-to-classify time.
struct GoalongHourlyClassChart: View {
    let day: GoalongLocalAnalytics.Day
    let dateRange: ClosedRange<Date>
    let hourStride: Int

    /// Bars rise once when the chart first appears: the page's single entrance moment.
    @State private var grow: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hours = day.hours(minimumMinutes: 25).filter { $0.seconds > 0 }
        let scale = GoalongAnalyticsChartScale(maximumSeconds: hours.map(\.seconds).max() ?? 0, hourly: true)
        Chart {
            ForEach(hours) { hour in
                ForEach(GoalongActivityClassStyle.order, id: \.rawValue) { kind in
                    let seconds = value(hour, kind)
                    if seconds > 0 {
                        BarMark(x: .value("Heure", hour.start, unit: .hour), y: .value("Durée", seconds / scale.unitSeconds * grow), width: .ratio(0.62))
                            .foregroundStyle(by: .value("Type", GoalongActivityClassStyle.label(kind)))
                            .cornerRadius(4)
                            .accessibilityLabel("\(GoalongSummaryFormat.hour(hour.start)), \(GoalongActivityClassStyle.label(kind))")
                            .accessibilityValue(GoalongAnalyticsFormatting.duration(seconds))
                    }
                }
            }
        }
        .onAppear {
            guard grow == 0 else { return }
            if reduceMotion { grow = 1 } else { withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { grow = 1 } }
        }
        .chartForegroundStyleScale(GoalongActivityClassStyle.scale)
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
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                AxisValueLabel { if let amount = value.as(Double.self) { Text(scale.label(amount)) } }
            }
        }
        .frame(height: 200)
        .accessibilityIdentifier("activity-hourly-class-chart")
    }

    private func value(_ hour: GoalongLocalAnalytics.Hour, _ kind: GoalongLocalAnalytics.Kind) -> Double {
        switch kind {
        case .work: return hour.workSeconds
        case .other: return hour.otherSeconds
        default: return hour.unclassifiedSeconds
        }
    }
}

/// One lane per main application or website: what, when, and whether it was work.
struct GoalongUsageTimelineChart: View {
    let day: GoalongLocalAnalytics.Day
    let grouping: GoalongActivityUsageGrouping
    let dateRange: ClosedRange<Date>
    let hourStride: Int
    var laneCount = 6

    private struct Bar: Identifiable {
        let id: Int
        let lane: String
        let start: Date
        var end: Date
        let kind: GoalongLocalAnalytics.Kind
    }

    var body: some View {
        let lanes = laneNames
        let bars = self.bars(lanes: lanes)
        let order = lanes.map(\.1) + (bars.contains { $0.lane == Self.otherLane } ? [Self.otherLane] : [])
        Chart(bars) { bar in
            RectangleMark(xStart: .value("Début", bar.start), xEnd: .value("Fin", bar.end),
                          y: .value("Usage", bar.lane), height: .ratio(0.62))
                .foregroundStyle(by: .value("Type", GoalongActivityClassStyle.label(bar.kind)))
                .accessibilityLabel("\(bar.lane), \(GoalongSummaryFormat.time(bar.start))–\(GoalongSummaryFormat.time(bar.end))")
                .accessibilityValue(GoalongAnalyticsFormatting.duration(bar.end.timeIntervalSince(bar.start)))
        }
        .chartForegroundStyleScale(GoalongActivityClassStyle.scale)
        .chartLegend(.hidden)
        .chartXScale(domain: dateRange)
        .chartYScale(domain: order)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hourStride)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4])); AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel { if let name = value.as(String.self) { Text(name).lineLimit(1).frame(maxWidth: 130, alignment: .leading) } }
            }
        }
        .frame(height: CGFloat(max(3, order.count)) * 30 + 30)
        .accessibilityIdentifier("activity-usage-timeline")
    }

    private static let otherLane = "Autres"

    /// Main usages of the day as (id, display name), by decreasing time.
    private var laneNames: [(String, String)] {
        let usage = GoalongActivityProjection.usage(.init(days: [day]), grouping: grouping)
        var seen = Set<String>()
        return usage.prefix(laneCount).compactMap { item in
            let name = item.displayName
            guard seen.insert(name).inserted else { return nil }
            return (item.id, name)
        }
    }

    /// Adjacent intervals of the same lane and class closer than a minute merge visually;
    /// totals elsewhere are unaffected.
    private func bars(lanes: [(String, String)]) -> [Bar] {
        let names = Dictionary(uniqueKeysWithValues: lanes)
        var result: [Bar] = []
        var lastIndex: [String: Int] = [:]
        for segment in day.segments where segment.kind.isActive && segment.seconds > 0 {
            guard let id = GoalongActivityProjection.usageID(segment, grouping: grouping) else { continue }
            let lane = names[id] ?? Self.otherLane
            if let index = lastIndex[lane], result[index].kind == segment.kind,
               segment.start.timeIntervalSince(result[index].end) <= 60 {
                result[index].end = max(result[index].end, segment.end)
                continue
            }
            result.append(Bar(id: result.count, lane: lane, start: segment.start, end: segment.end, kind: segment.kind))
            lastIndex[lane] = result.count - 1
        }
        return result
    }
}

/// Days of a period, stacked by class, with the average of observed days.
struct GoalongDailyClassChart: View {
    let period: GoalongLocalAnalytics.Period
    let dateRange: ClosedRange<Date>
    var onDay: (Date) -> Void = { _ in }

    /// Bars rise once when the chart first appears: the page's single entrance moment.
    @State private var grow: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let observed = period.observedDays
        let average = observed.isEmpty ? 0 : period.activeSeconds / Double(observed.count)
        let scale = GoalongAnalyticsChartScale(maximumSeconds: period.days.map(\.activeSeconds).max() ?? 0)
        Chart {
            ForEach(period.days) { day in
                if day.activeSeconds > 0 {
                    ForEach(GoalongActivityClassStyle.order, id: \.rawValue) { kind in
                        let seconds = day.seconds(kind)
                        if seconds > 0 {
                            BarMark(x: .value("Jour", day.date, unit: .day), y: .value("Durée", seconds / scale.unitSeconds * grow), width: .ratio(0.62))
                                .foregroundStyle(by: .value("Type", GoalongActivityClassStyle.label(kind)))
                                .cornerRadius(4)
                                .accessibilityLabel("\(GoalongSummaryFormat.shortDate(day.date)), \(GoalongActivityClassStyle.label(kind))")
                                .accessibilityValue(GoalongAnalyticsFormatting.duration(seconds))
                        }
                    }
                } else if day.observedSeconds > 0 && day.state == .ready {
                    PointMark(x: .value("Jour", day.date, unit: .day), y: .value("Durée", 0.0))
                        .foregroundStyle(LHTheme.secondaryText)
                        .accessibilityLabel("\(GoalongSummaryFormat.shortDate(day.date)), zéro minute active observée")
                }
            }
            if observed.count >= 2 {
                RuleMark(y: .value("Moyenne", average / scale.unitSeconds))
                    .foregroundStyle(LHTheme.text.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Moyenne \(GoalongAnalyticsFormatting.duration(average))")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Moyenne des jours observés")
                    .accessibilityValue(GoalongAnalyticsFormatting.duration(average))
            }
        }
        .onAppear {
            guard grow == 0 else { return }
            if reduceMotion { grow = 1 } else { withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { grow = 1 } }
        }
        .chartForegroundStyleScale(GoalongActivityClassStyle.scale)
        .chartLegend(.hidden).chartYScale(domain: 0...scale.upperBound).chartXScale(domain: dateRange)
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: period.days.count > 7 ? 4 : 1)) { _ in
            AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).weekday(.abbreviated).day()); AxisTick()
        } }
        .chartYAxis { AxisMarks(position: .leading) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4])); AxisValueLabel { if let amount = value.as(Double.self) { Text(scale.label(amount)) } }
        } }
        .frame(height: 220)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let x = value.location.x - geometry[proxy.plotAreaFrame].origin.x
                        guard x >= 0, x <= geometry[proxy.plotAreaFrame].width,
                              let date: Date = proxy.value(atX: x),
                              let day = period.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) else { return }
                        onDay(day.date)
                    })
            }
        }
        .accessibilityIdentifier("activity-daily-class-chart")
    }
}

/// When the user is usually active: average minutes per weekday and clock hour.
struct GoalongWeekHourHeatmap: View {
    let period: GoalongLocalAnalytics.Period
    var calendar: Calendar = .current

    private struct Cell: Identifiable {
        let id: String
        let weekday: String
        let hour: Int
        let seconds: TimeInterval
    }

    var body: some View {
        let grid = period.averageActiveSecondsByWeekdayAndHour(calendar: calendar)
        let rows = weekdayRows(grid)
        let cells = rows.flatMap { row in
            (0..<24).map { Cell(id: "\(row.label)-\($0)", weekday: row.label, hour: $0, seconds: row.values[$0]) }
        }
        let maximum = max(60, cells.map(\.seconds).max() ?? 0)
        VStack(alignment: .leading, spacing: 10) {
            Chart(cells) { cell in
                RectangleMark(xStart: .value("Début", Double(cell.hour) + 0.06), xEnd: .value("Fin", Double(cell.hour) + 0.94),
                              y: .value("Jour", cell.weekday), height: .ratio(0.82))
                    .foregroundStyle(cell.seconds <= 0 ? LHTheme.separator.opacity(0.35)
                        : LHTheme.accent.opacity(0.18 + 0.82 * min(1, cell.seconds / maximum)))
                    .cornerRadius(3)
                    .accessibilityLabel("\(cell.weekday), \(cell.hour) h")
                    .accessibilityValue(GoalongAnalyticsFormatting.duration(cell.seconds))
            }
            .chartXScale(domain: 0.0...24.0)
            .chartYScale(domain: rows.map(\.label))
            .chartXAxis { AxisMarks(values: [0.0, 3, 6, 9, 12, 15, 18, 21, 24]) { value in
                AxisValueLabel { if let hour = value.as(Double.self) { Text("\(Int(hour)) h") } }
            } }
            .chartYAxis { AxisMarks(position: .leading) { value in
                AxisValueLabel { if let day = value.as(String.self) { Text(day) } }
            } }
            .frame(height: CGFloat(rows.count) * 26 + 26)
            HStack(spacing: 8) {
                Text("Moins").foregroundStyle(.secondary)
                ForEach([0.18, 0.4, 0.6, 0.8, 1.0], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2).fill(LHTheme.accent.opacity(opacity)).frame(width: 14, height: 10)
                }
                Text("Plus · jusqu’à \(GoalongAnalyticsFormatting.duration(maximum)) par heure").foregroundStyle(.secondary)
            }.font(.system(size: 11)).accessibilityHidden(true)
        }
        .accessibilityIdentifier("activity-week-heatmap")
    }

    /// Monday first, as in France. Weekdays without any observed day are omitted.
    private func weekdayRows(_ grid: [[TimeInterval]?]) -> [(label: String, values: [TimeInterval])] {
        var french = Calendar(identifier: .gregorian); french.locale = Locale(identifier: "fr_FR")
        let symbols = french.shortWeekdaySymbols
        let mondayFirst = [1, 2, 3, 4, 5, 6, 0]
        return mondayFirst.compactMap { index in
            guard let values = grid[index] else { return nil }
            let label = symbols[index].replacingOccurrences(of: ".", with: "").capitalized
            return (label, values)
        }
    }
}

enum GoalongSummaryFormat {
    static func time(_ date: Date) -> String { GoalongActivitySummary.time(date) }
    static func hour(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour())
    }
    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated))
    }
}
#endif
