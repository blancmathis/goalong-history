#if os(macOS)
import SwiftUI

/// The week as seven threads, Monday to Sunday on one 0–24 h scale, like Activité's weave.
/// A program range thickens the thread: solid when its program is locked, quieter when free.
/// The present is the lime point on today's thread.
struct BlockingWeekView: View {
    let lists: [BlockList]
    let now: Date
    var compact = false

    private struct Span: Hashable { var start: Int; var end: Int; var locked: Bool; var names: String }

    private var today: Int { BlockingSchedule.isoWeekday(now) }
    private var nowMinute: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var spans: [Int: [Span]] {
        var result: [Int: [Span]] = [:]
        for list in lists {
            let locked = list.program.isLocked(at: now)
            for range in list.program.ranges {
                for day in range.weekdays {
                    if range.crossesMidnight {
                        result[day, default: []].append(Span(start: range.startMinute, end: 1_440, locked: locked, names: list.name))
                        let next = day % 7 + 1
                        if range.endMinute > 0 {
                            result[next, default: []].append(Span(start: 0, end: range.endMinute, locked: locked, names: list.name))
                        }
                    } else {
                        result[day, default: []].append(Span(start: range.startMinute, end: range.endMinute, locked: locked, names: list.name))
                    }
                }
            }
        }
        return result
    }

    var body: some View {
        let rowHeight: CGFloat = compact ? 14 : 22
        let thickness: CGFloat = compact ? 6 : 10
        let label: CGFloat = compact ? 16 : 34
        let spans = self.spans
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            ForEach(1...7, id: \.self) { day in
                HStack(spacing: 10) {
                    Text(compact ? BlockingFormat.weekdayLetters[day - 1] : BlockingFormat.weekdayShort[day - 1])
                        .font(.system(size: compact ? 10 : 12, weight: day == today ? .semibold : .regular))
                        .foregroundStyle(day == today ? LHTheme.text : LHTheme.secondaryText)
                        .frame(width: label, alignment: .leading)
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        ZStack(alignment: .leading) {
                            Rectangle().fill(LHTheme.tertiaryText.opacity(0.45)).frame(height: 1)
                            ForEach(spans[day] ?? [], id: \.self) { span in
                                Capsule()
                                    .fill(LHTheme.text.opacity(span.locked ? 1 : 0.42))
                                    .frame(width: max(thickness, width * CGFloat(span.end - span.start) / 1_440), height: thickness)
                                    .offset(x: width * CGFloat(span.start) / 1_440)
                                    .help("\(span.names) · \(BlockingFormat.minuteOfDay(span.start)) → \(span.end == 1_440 ? "24:00" : BlockingFormat.minuteOfDay(span.end))")
                            }
                            if day == today {
                                Circle().fill(LHTheme.accent)
                                    .overlay(Circle().strokeBorder(LHTheme.pageBackground, lineWidth: 2))
                                    .frame(width: thickness + 4, height: thickness + 4)
                                    .offset(x: width * CGFloat(nowMinute) / 1_440 - (thickness + 4) / 2)
                            }
                        }
                        .frame(height: rowHeight)
                    }
                    .frame(height: rowHeight)
                }
            }
            if !compact {
                HStack(spacing: 10) {
                    Color.clear.frame(width: label, height: 1)
                    GeometryReader { proxy in
                        ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                            Text("\(hour) h").font(.system(size: 11).monospacedDigit()).foregroundStyle(LHTheme.tertiaryText)
                                .fixedSize()
                                .position(x: min(max(10, proxy.size.width * CGFloat(hour) / 24), proxy.size.width - 12), y: 7)
                        }
                    }
                    .frame(height: 14)
                }
                HStack(spacing: 16) {
                    legend(opacity: 1, "Verrouillé")
                    legend(opacity: 0.42, "Libre")
                    HStack(spacing: 6) {
                        Circle().fill(LHTheme.accent).frame(width: 8, height: 8)
                        Text("Maintenant")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                .padding(.leading, label + 10).padding(.top, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func legend(opacity: Double, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(LHTheme.text.opacity(opacity)).frame(width: 18, height: 6)
            Text(text)
        }
    }

    private var accessibilitySummary: String {
        let parts = lists.flatMap { list in
            list.program.ranges.map { "\(list.name) : \(BlockingFormat.weekdays($0.weekdays)), \(BlockingFormat.range($0))" }
        }
        return parts.isEmpty ? "Aucun programme" : parts.joined(separator: " ; ")
    }
}
#endif
