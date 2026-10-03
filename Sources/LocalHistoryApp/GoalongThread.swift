#if os(macOS)
    import LocalHistoryCore
    import SwiftUI

    // Goalong's signature: the thread. A day is one continuous line, from the first trace to
    // the last. It thickens while the person is active, in the colour of what that time was,
    // and goes back to a hairline when nothing is observed. It never breaks.

    /// Pure geometry: testable without a window.
    enum GoalongThreadGeometry {
        /// A stretch of the thread, in bins: `lower` included, `upper` excluded.
        struct Run: Equatable {
            var lower: Int
            var upper: Int
            var kind: GoalongLocalAnalytics.Kind
        }

        /// Consecutive active time of one class, for the hover readout.
        struct Stretch: Equatable {
            let start: Date
            var end: Date
            let kind: GoalongLocalAnalytics.Kind
            var task: String?
            var seconds: TimeInterval
        }

        private static let order: [GoalongLocalAnalytics.Kind] = [.work, .other, .unclassified]

        /// Splits `lower...upper` into `bins` equal slots and gives each the class that fills
        /// most of it. A slot shows as active only when at least a quarter of it is, so a few
        /// seconds never paint minutes; a day with hardly any activity still shows where it was.
        static func runs(_ segments: [GoalongLocalAnalytics.Segment], from lower: Date, to upper: Date,
                         bins: Int) -> [Run] {
            let span = upper.timeIntervalSince(lower)
            guard bins > 0, span > 0 else { return [] }
            let perBin = span / Double(bins)
            var seconds = [[Double]](repeating: [0, 0, 0], count: bins)
            for segment in segments where segment.kind.isActive {
                guard let slot = order.firstIndex(of: segment.kind) else { continue }
                let start = max(0, segment.start.timeIntervalSince(lower))
                let end = min(span, segment.end.timeIntervalSince(lower))
                guard end > start else { continue }
                var bin = min(bins - 1, Int(start / perBin))
                while bin < bins, Double(bin) * perBin < end {
                    let overlap = min(end, Double(bin + 1) * perBin) - max(start, Double(bin) * perBin)
                    if overlap > 0 { seconds[bin][slot] += overlap }
                    bin += 1
                }
            }
            func encode(threshold: Double) -> [Run] {
                var result: [Run] = []
                for bin in 0..<bins {
                    let total = seconds[bin].reduce(0, +)
                    guard total > 0, total >= threshold else { continue }
                    let slot = seconds[bin].indices.max { seconds[bin][$0] < seconds[bin][$1] } ?? 0
                    if let last = result.last, last.upper == bin, last.kind == order[slot] {
                        result[result.count - 1].upper = bin + 1
                    } else {
                        result.append(Run(lower: bin, upper: bin + 1, kind: order[slot]))
                    }
                }
                return result
            }
            let filtered = encode(threshold: perBin * 0.25)
            return filtered.isEmpty ? encode(threshold: 0) : filtered
        }

        /// Active segments of the same class less than a minute apart read as one stretch.
        static func stretches(_ segments: [GoalongLocalAnalytics.Segment]) -> [Stretch] {
            var result: [Stretch] = []
            for segment in segments where segment.kind.isActive && segment.seconds > 0 {
                if let last = result.last, last.kind == segment.kind, last.task == segment.task,
                   segment.start.timeIntervalSince(last.end) <= 60 {
                    result[result.count - 1].end = max(last.end, segment.end)
                    result[result.count - 1].seconds += segment.seconds
                } else {
                    result.append(Stretch(start: segment.start, end: segment.end, kind: segment.kind,
                                          task: segment.kind == .work ? segment.task : nil, seconds: segment.seconds))
                }
            }
            return result
        }

        /// The hours every thread of a period shares: from the earliest first trace to the
        /// latest last one, on whole hours, at least six hours wide.
        static func sharedHours(_ days: [GoalongLocalAnalytics.Day], calendar: Calendar = .current) -> ClosedRange<Int> {
            var first = 24.0, last = 0.0
            for day in days {
                let start = calendar.startOfDay(for: day.date)
                for segment in day.segments where segment.kind.isActive && segment.seconds > 0 {
                    first = min(first, segment.start.timeIntervalSince(start) / 3600)
                    last = max(last, segment.end.timeIntervalSince(start) / 3600)
                }
            }
            guard last > first else { return 0...24 }
            var lower = max(0, Int(first.rounded(.down))), upper = min(24, Int(last.rounded(.up)))
            while upper - lower < 6 {
                if upper < 24 { upper += 1 }
                if upper - lower < 6, lower > 0 { lower -= 1 }
            }
            return lower...upper
        }
    }

    /// The thick parts of a thread. The resting hairline is drawn by the caller, underneath,
    /// so it stays put while this layer is traced.
    struct GoalongThreadBand: View, Equatable {
        let segments: [GoalongLocalAnalytics.Segment]
        let lower: Date
        let upper: Date
        var thickness: CGFloat = 14

        var body: some View {
            Canvas { context, size in
                let bins = max(1, Int(size.width / 2))
                let runs = GoalongThreadGeometry.runs(segments, from: lower, to: upper, bins: bins)
                let width = size.width / CGFloat(bins)
                let radius = min(LHTheme.markRadius, thickness / 2)
                for (index, run) in runs.enumerated() {
                    var x0 = CGFloat(run.lower) * width, x1 = CGFloat(run.upper) * width
                    // A hair of page between two touching classes separates them without a stroke.
                    if index > 0, runs[index - 1].upper == run.lower { x0 += 0.75 }
                    if index < runs.count - 1, runs[index + 1].lower == run.upper { x1 -= 0.75 }
                    let rect = CGRect(x: x0, y: (size.height - thickness) / 2, width: max(1.5, x1 - x0), height: thickness)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(radius, rect.width / 2), style: .continuous),
                                 with: .color(GoalongActivityClassStyle.color(run.kind)))
                }
            }
        }
    }

    /// Whole-hour marks under a thread: a tick and a label, drawn once.
    struct GoalongThreadAxis: View {
        /// Hours since the start of the day shown, and their position between 0 and 1.
        let marks: [(label: String, position: CGFloat)]

        var body: some View {
            Canvas { context, size in
                for mark in marks {
                    let x = min(size.width - 0.5, max(0.5, mark.position * size.width))
                    context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: 4)), with: .color(LHTheme.separator))
                    let text = context.resolve(Text(mark.label).font(.system(size: 11)).foregroundColor(LHTheme.tertiaryText))
                    let width = text.measure(in: size).width
                    // The first and last labels stay inside the thread's width.
                    let anchorX = min(size.width - width, max(0, x - (mark.position <= 0.001 ? 0 : width / 2)))
                    context.draw(text, at: CGPoint(x: anchorX, y: 8), anchor: .topLeading)
                }
            }
            .frame(height: 22)
            .accessibilityHidden(true)
        }
    }

    /// Reveals a thread from left to right, once. Reduce Motion shows it complete at once.
    private struct GoalongThreadTrace: ViewModifier {
        @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
        @Environment(\.goalongReduceMotion) private var localReduceMotion
        @State private var traced: CGFloat = 0

        func body(content: Content) -> some View {
            let still = systemReduceMotion || localReduceMotion
            content
                .mask(alignment: .leading) { Rectangle().scaleEffect(x: still ? 1 : traced, anchor: .leading) }
                .onAppear {
                    guard traced == 0, !still else { traced = 1; return }
                    withAnimation(LHTheme.draw.delay(0.08)) { traced = 1 }
                }
        }
    }

    /// One day as one line. Hovering reads the stretch under the pointer.
    struct GoalongDayThread: View {
        let day: GoalongLocalAnalytics.Day
        let range: ClosedRange<Date>
        var hourStride = 2
        @State private var pointer: CGFloat?
        @State private var width: CGFloat = 1

        private var stretches: [GoalongThreadGeometry.Stretch] { GoalongThreadGeometry.stretches(day.segments) }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    GoalongActivityClassLegend()
                    Spacer(minLength: 8)
                    readout
                }
                .frame(minHeight: 16)
                VStack(spacing: 4) {
                    ZStack {
                        Rectangle().fill(LHTheme.tertiaryText.opacity(0.5)).frame(height: 1)
                        GoalongThreadBand(segments: day.segments, lower: range.lowerBound, upper: range.upperBound)
                            .equatable()
                            .modifier(GoalongThreadTrace())
                        if let pointer {
                            Rectangle().fill(LHTheme.text).frame(width: 1)
                                .position(x: pointer, y: 13)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 26)
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { width = proxy.size.width }
                            .onChange(of: proxy.size.width) { width = $0 }
                    })
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): pointer = min(max(0, location.x), width)
                        case .ended: pointer = nil
                        }
                    }
                    GoalongThreadAxis(marks: marks)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fil de la journée")
            .accessibilityValue(summary)
            .accessibilityIdentifier("activity-day-thread")
        }

        @ViewBuilder private var readout: some View {
            if let pointer {
                let moment = range.lowerBound.addingTimeInterval(
                    Double(pointer / max(1, width)) * range.upperBound.timeIntervalSince(range.lowerBound))
                if let stretch = stretches.first(where: { $0.start <= moment && moment <= $0.end }) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(GoalongSummaryFormat.time(stretch.start)) – \(GoalongSummaryFormat.time(stretch.end))")
                            .foregroundStyle(LHTheme.secondaryText).monospacedDigit()
                        Text(stretch.task ?? GoalongActivityClassStyle.label(stretch.kind)).fontWeight(.medium).lineLimit(1)
                        Text(GoalongAnalyticsFormatting.duration(stretch.seconds))
                            .foregroundStyle(LHTheme.secondaryText).monospacedDigit()
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(GoalongSummaryFormat.time(moment)).monospacedDigit()
                        Text("rien d’observé")
                    }.foregroundStyle(LHTheme.secondaryText)
                }
            }
        }

        private var marks: [(label: String, position: CGFloat)] {
            let span = range.upperBound.timeIntervalSince(range.lowerBound)
            guard span > 0 else { return [] }
            var result: [(String, CGFloat)] = []
            var cursor = range.lowerBound
            while cursor <= range.upperBound, result.count < 26 {
                result.append((GoalongSummaryFormat.hour(cursor), CGFloat(cursor.timeIntervalSince(range.lowerBound) / span)))
                guard let next = Calendar.current.date(byAdding: .hour, value: max(1, hourStride), to: cursor) else { break }
                cursor = next
            }
            return result
        }

        private var summary: String {
            let parts = GoalongActivityClassStyle.order.compactMap { kind -> String? in
                let seconds = day.seconds(kind)
                return seconds >= 60 ? "\(GoalongActivityClassStyle.label(kind)) \(GoalongAnalyticsFormatting.duration(seconds))" : nil
            }
            guard let first = stretches.first, let last = stretches.last else { return "Aucune activité observée" }
            return "Actif de \(GoalongSummaryFormat.time(first.start)) à \(GoalongSummaryFormat.time(last.end)). "
                + parts.joined(separator: ", ")
        }
    }

    /// A period as a weave: one thread per day on shared hours. A click opens the day.
    struct GoalongThreadWeave: View {
        let period: GoalongLocalAnalytics.Period
        var onDay: (Date) -> Void = { _ in }
        var calendar: Calendar = .current

        private var dense: Bool { period.days.count > 10 }
        private let labelWidth: CGFloat = 64
        private let totalWidth: CGFloat = 56

        var body: some View {
            let hours = GoalongThreadGeometry.sharedHours(period.days, calendar: calendar)
            VStack(alignment: .leading, spacing: 10) {
                GoalongActivityClassLegend()
                VStack(spacing: 0) {
                    ForEach(period.days) { day in
                        GoalongWeaveRow(day: day, hours: hours, dense: dense, labelWidth: labelWidth, totalWidth: totalWidth,
                                        label: label(day), calendar: calendar) { onDay(day.date) }
                    }
                }
                .modifier(GoalongThreadTrace())
                GoalongThreadAxis(marks: marks(hours))
                    .padding(.leading, labelWidth + 12).padding(.trailing, totalWidth + 12)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Un fil par jour")
            .accessibilityIdentifier("activity-thread-weave")
        }

        /// A month names its Mondays only; a week names every day.
        private func label(_ day: GoalongLocalAnalytics.Day) -> String {
            if dense, calendar.component(.weekday, from: day.date) != 2, day.id != period.days.first?.id { return "" }
            return day.date.formatted(.dateTime.locale(GoalongUIFormat.locale).weekday(.abbreviated).day())
        }

        private func marks(_ hours: ClosedRange<Int>) -> [(label: String, position: CGFloat)] {
            let span = hours.upperBound - hours.lowerBound
            let stride = span > 16 ? 4 : span > 8 ? 2 : 1
            return Swift.stride(from: hours.lowerBound, through: hours.upperBound, by: stride).map {
                ("\($0) h", CGFloat($0 - hours.lowerBound) / CGFloat(max(1, span)))
            }
        }
    }

    private struct GoalongWeaveRow: View {
        let day: GoalongLocalAnalytics.Day
        let hours: ClosedRange<Int>
        let dense: Bool
        let labelWidth: CGFloat
        let totalWidth: CGFloat
        let label: String
        let calendar: Calendar
        let open: () -> Void
        @State private var hovered = false

        var body: some View {
            let start = calendar.startOfDay(for: day.date)
            let observed = day.observedSeconds > 0 && day.state == .ready
            Button(action: open) {
                HStack(spacing: 12) {
                    Text(label).font(.system(size: 11)).foregroundStyle(hovered ? LHTheme.text : LHTheme.secondaryText)
                        .lineLimit(1).frame(width: labelWidth, alignment: .leading)
                    ZStack {
                        Rectangle().fill(LHTheme.tertiaryText.opacity(observed ? 0.5 : 0.2)).frame(height: 1)
                        GoalongThreadBand(segments: day.segments, lower: start.addingTimeInterval(Double(hours.lowerBound) * 3600),
                                          upper: start.addingTimeInterval(Double(hours.upperBound) * 3600),
                                          thickness: dense ? 6 : 10)
                            .equatable()
                    }
                    Text(day.activeSeconds >= 60 ? GoalongAnalyticsFormatting.duration(day.activeSeconds) : "—")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(hovered ? LHTheme.text : LHTheme.secondaryText)
                        .frame(width: totalWidth, alignment: .trailing)
                }
                .frame(height: dense ? 15 : 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(hovered ? LHTheme.hoverBackground : .clear, in: RoundedRectangle(cornerRadius: 4).inset(by: -4))
            .onHover { hovered = $0 }
            .help("Ouvrir le \(GoalongActivitySummary.weekdayDate(day.date))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GoalongActivitySummary.weekdayDate(day.date))
            .accessibilityValue(observed
                ? "\(GoalongAnalyticsFormatting.duration(day.activeSeconds)) actives, dont \(GoalongAnalyticsFormatting.duration(day.seconds(.work))) de travail"
                : "Aucune donnée")
            .accessibilityHint("Ouvrir cette journée")
            .accessibilityAddTraits(.isButton)
        }
    }

    /// The thread before it starts: what an empty screen shows instead of a picture.
    struct GoalongThreadPlaceholder: View {
        var width: CGFloat = 96

        var body: some View {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(LHTheme.accent).frame(width: 7, height: 7)
                Rectangle().fill(LHTheme.tertiaryText.opacity(0.7))
                    .frame(height: 1)
                    .mask(HStack(spacing: 4) { ForEach(0..<24, id: \.self) { _ in Rectangle().frame(width: 3) } })
            }
            .frame(width: width, height: 7, alignment: .leading)
            .accessibilityHidden(true)
        }
    }
#endif
