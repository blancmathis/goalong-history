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
        case .work: return LHTheme.workData
        case .other: return LHTheme.otherData
        case .unclassified: return LHTheme.unclassifiedData
        case .idle: return LHTheme.privateTint
        case .concealed: return LHTheme.teal.opacity(0.45)
        case .unobserved: return LHTheme.separator
        }
    }

    static var scale: KeyValuePairs<String, Color> {
        [label(.work): color(.work), label(.other): color(.other), label(.unclassified): color(.unclassified)]
    }
}

/// Always present next to a chart of classes: identity never rests on colour alone.
struct GoalongActivityClassLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(GoalongActivityClassStyle.order, id: \.rawValue) { kind in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(GoalongActivityClassStyle.color(kind))
                        .frame(width: 8, height: 8)
                    Text(GoalongActivityClassStyle.label(kind))
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
        .accessibilityElement(children: .combine)
    }
}

/// Stacks the classes of one bar with a hair of page between them instead of a stroke.
enum GoalongStackedBars {
    struct Piece: Identifiable {
        let id: String
        let kind: GoalongLocalAnalytics.Kind
        let lower: Double
        let upper: Double
        let seconds: Double
    }
    /// `gap` is in the chart's own unit: about two points of the plot height.
    static func pieces(_ values: [(GoalongLocalAnalytics.Kind, Double)], unit: Double, gap: Double, id: String) -> [Piece] {
        var result: [Piece] = [], cursor = 0.0
        for (kind, seconds) in values where seconds > 0 {
            let height = seconds / unit
            let lower = cursor + (result.isEmpty ? 0 : min(gap, height / 2))
            result.append(Piece(id: id + kind.rawValue, kind: kind, lower: lower, upper: cursor + height, seconds: seconds))
            cursor += height
        }
        return result
    }
}

/// Hour by hour, split into work, other and still-to-classify time.
struct GoalongHourlyClassChart: View {
    let day: GoalongLocalAnalytics.Day
    let dateRange: ClosedRange<Date>
    let hourStride: Int
    private let height: CGFloat = 180

    var body: some View {
        let hours = day.hours(minimumMinutes: 25).filter { $0.seconds > 0 }
        let scale = GoalongAnalyticsChartScale(maximumSeconds: hours.map(\.seconds).max() ?? 0, hourly: true)
        let span = dateRange.upperBound.timeIntervalSince(dateRange.lowerBound) / 3600
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(hours) { hour in
                    let pieces = GoalongStackedBars.pieces(
                        [(.work, hour.workSeconds), (.other, hour.otherSeconds), (.unclassified, hour.unclassifiedSeconds)],
                        unit: scale.unitSeconds, gap: scale.upperBound * 2 / Double(height - 30), id: "\(hour.start.timeIntervalSince1970)")
                    ForEach(pieces) { piece in
                        BarMark(x: .value("Heure", hour.start, unit: .hour),
                                yStart: .value("Début", piece.lower), yEnd: .value("Durée", piece.upper),
                                width: span <= 14 ? .fixed(24) : .ratio(0.6))
                            .foregroundStyle(by: .value("Type", GoalongActivityClassStyle.label(piece.kind)))
                            .cornerRadius(LHTheme.markRadius)
                            .accessibilityLabel("\(GoalongSummaryFormat.hour(hour.start)), \(GoalongActivityClassStyle.label(piece.kind))")
                            .accessibilityValue(GoalongAnalyticsFormatting.duration(piece.seconds))
                    }
                }
            }
            .chartForegroundStyleScale(GoalongActivityClassStyle.scale)
            .chartLegend(.hidden).chartXScale(domain: dateRange).chartYScale(domain: 0...scale.upperBound)
            .chartPlotStyle { $0.clipped() }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: hourStride)) { _ in
                    AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).hour())
                        .font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(LHTheme.separator)
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(scale.label(amount)) } }
                        .font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText)
                }
            }
            .frame(height: height)
            .accessibilityIdentifier("activity-hourly-class-chart")
            GoalongActivityClassLegend()
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
        VStack(alignment: .leading, spacing: 10) {
        Chart(bars) { bar in
            RectangleMark(xStart: .value("Début", bar.start), xEnd: .value("Fin", bar.end),
                          y: .value("Usage", bar.lane), height: .fixed(10))
                .foregroundStyle(by: .value("Type", GoalongActivityClassStyle.label(bar.kind)))
                .cornerRadius(LHTheme.markRadius)
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
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(LHTheme.separator)
                AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).hour())
                    .font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel { if let name = value.as(String.self) { Text(name).lineLimit(1).frame(maxWidth: 130, alignment: .leading) } }
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
        }
        .frame(height: CGFloat(max(3, order.count)) * 28 + 30)
        .accessibilityIdentifier("activity-usage-timeline")
        GoalongActivityClassLegend()
        }
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
    private let height: CGFloat = 200

    var body: some View {
        let observed = period.observedDays
        let average = observed.isEmpty ? 0 : period.activeSeconds / Double(observed.count)
        let scale = GoalongAnalyticsChartScale(maximumSeconds: period.days.map(\.activeSeconds).max() ?? 0)
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(period.days) { day in
                    if day.activeSeconds > 0 {
                        let pieces = GoalongStackedBars.pieces(
                            GoalongActivityClassStyle.order.map { ($0, day.seconds($0)) },
                            unit: scale.unitSeconds, gap: scale.upperBound * 2 / Double(height - 30), id: "\(day.date.timeIntervalSince1970)")
                        ForEach(pieces) { piece in
                            BarMark(x: .value("Jour", day.date, unit: .day),
                                    yStart: .value("Début", piece.lower), yEnd: .value("Durée", piece.upper),
                                    width: period.days.count <= 10 ? .fixed(24) : .ratio(0.6))
                                .foregroundStyle(by: .value("Type", GoalongActivityClassStyle.label(piece.kind)))
                                .cornerRadius(LHTheme.markRadius)
                                .accessibilityLabel("\(GoalongSummaryFormat.shortDate(day.date)), \(GoalongActivityClassStyle.label(piece.kind))")
                                .accessibilityValue(GoalongAnalyticsFormatting.duration(piece.seconds))
                        }
                    } else if day.observedSeconds > 0 && day.state == .ready {
                        PointMark(x: .value("Jour", day.date, unit: .day), y: .value("Durée", 0.0))
                            .foregroundStyle(LHTheme.secondaryText)
                            .accessibilityLabel("\(GoalongSummaryFormat.shortDate(day.date)), zéro minute active observée")
                    }
                }
                if observed.count >= 2 {
                    RuleMark(y: .value("Moyenne", average / scale.unitSeconds))
                        .foregroundStyle(LHTheme.text.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Moyenne \(GoalongAnalyticsFormatting.duration(average))")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                        }
                        .accessibilityLabel("Moyenne des jours observés")
                        .accessibilityValue(GoalongAnalyticsFormatting.duration(average))
                }
            }
            .chartForegroundStyleScale(GoalongActivityClassStyle.scale)
            .chartLegend(.hidden).chartYScale(domain: 0...scale.upperBound).chartXScale(domain: dateRange)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: period.days.count > 7 ? 4 : 1)) { _ in
                AxisValueLabel(format: .dateTime.locale(Locale(identifier: "fr_FR")).weekday(.abbreviated).day())
                    .font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText)
            } }
            .chartYAxis { AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(LHTheme.separator)
                AxisValueLabel { if let amount = value.as(Double.self) { Text(scale.label(amount)) } }
                    .font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText)
            } }
            .frame(height: height)
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
            GoalongActivityClassLegend()
        }
    }
}

/// A share of a total as a thin bar: the same mark in tasks, usages and details.
struct GoalongShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(LHTheme.separator)
                RoundedRectangle(cornerRadius: 2).fill(color)
                    .frame(width: max(3, geometry.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
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
