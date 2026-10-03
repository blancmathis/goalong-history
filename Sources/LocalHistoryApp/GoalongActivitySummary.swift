#if os(macOS)
import Foundation
import LocalHistoryCore

/// Everything the top of Activité says, computed once from the same intervals as the
/// charts and lists. No value is extrapolated: averages use observed days only, an
/// in-progress day is compared with the previous day at the same clock time, and a
/// missing measurement stays nil instead of becoming zero.
struct GoalongActivitySummary {
    struct Comparison: Equatable {
        let current: TimeInterval
        let previous: TimeInterval
        let label: String
        var delta: TimeInterval { current - previous }
    }

    struct Insight: Identifiable, Equatable {
        enum Tone { case neutral, positive, attention }
        let id: String
        let symbol: String
        let text: String
        var tone: Tone = .neutral
    }

    let period: GoalongLocalAnalytics.Period
    let previous: GoalongLocalAnalytics.Period
    let calendar: Calendar
    let now: Date

    init(period: GoalongLocalAnalytics.Period, previous: GoalongLocalAnalytics.Period,
         calendar: Calendar = .current, now: Date = Date()) {
        self.period = period; self.previous = previous; self.calendar = calendar; self.now = now
    }

    var isDay: Bool { period.days.count == 1 }
    var observedDays: [GoalongLocalAnalytics.Day] { period.observedDays }
    var activeSeconds: TimeInterval { period.activeSeconds }
    var workSeconds: TimeInterval { period.workSeconds }
    var otherSeconds: TimeInterval { period.otherSeconds }
    var unclassifiedSeconds: TimeInterval { period.unclassifiedSeconds }

    /// Days used for daily averages: observed days, without today while it is still in
    /// progress (a partial day would pull every average down), unless it is the only one.
    var averagedDays: [GoalongLocalAnalytics.Day] {
        let completed = observedDays.filter { !calendar.isDate($0.date, inSameDayAs: now) }
        return completed.isEmpty ? observedDays : completed
    }
    var averageExcludesToday: Bool { averagedDays.count < observedDays.count }

    /// Average over days that actually have observations; nil when there are none.
    var averageActivePerDay: TimeInterval? {
        averagedDays.isEmpty ? nil : averagedDays.reduce(0) { $0 + $1.activeSeconds } / Double(averagedDays.count)
    }
    var averageWorkPerDay: TimeInterval? { averagePerDay(.work) }
    func averagePerDay(_ kind: GoalongLocalAnalytics.Kind) -> TimeInterval? {
        averagedDays.isEmpty ? nil : averagedDays.reduce(0) { $0 + $1.seconds(kind) } / Double(averagedDays.count)
    }

    var classifiedShare: Double { activeSeconds > 0 ? (workSeconds + otherSeconds) / activeSeconds : 0 }
    var workShare: Double { activeSeconds > 0 ? workSeconds / activeSeconds : 0 }
    var unclassifiedShare: Double { activeSeconds > 0 ? unclassifiedSeconds / activeSeconds : 0 }
    /// Work time is meaningful once most of the active time carries a class.
    var workIsMeasurable: Bool { activeSeconds > 0 && classifiedShare >= 0.5 }

    var workBlocks: [GoalongWorkBlock] { period.workBlocks(minimumMinutes: 25) }
    var longestWorkBlock: GoalongWorkBlock? {
        period.workBlocks(minimumMinutes: 1).max { $0.workSeconds < $1.workSeconds }
    }
    var longestSequence: GoalongLocalAnalytics.Focus? {
        period.days.flatMap(\.sequences).max { $0.seconds < $1.seconds }
    }

    var contextChanges: Int { period.contextChanges }
    var secondsPerChange: TimeInterval? { period.secondsPerContextChange }
    var changesPerActiveHour: Double? {
        activeSeconds >= 600 && contextChanges > 0 ? Double(contextChanges) / (activeSeconds / 3600) : nil
    }

    // MARK: - Day bounds

    /// Activity carried over from the previous night is not the start of the day.
    private static let dayStartHour = 4

    func firstActivity(_ day: GoalongLocalAnalytics.Day) -> Date? {
        guard let morning = calendar.date(bySettingHour: Self.dayStartHour, minute: 0, second: 0, of: day.date) else {
            return day.firstActiveStart
        }
        return day.segments.first { $0.kind.isActive && $0.seconds > 0 && $0.end > morning }
            .map { max($0.start, morning) } ?? day.firstActiveStart
    }

    var dayBounds: (start: Date, end: Date)? {
        guard isDay, let day = period.days.first, let start = firstActivity(day), let end = day.lastActiveEnd else { return nil }
        return (start, end)
    }

    /// Median clock time of first and last activity across observed days, in seconds after midnight.
    var typicalBounds: (start: TimeInterval, end: TimeInterval)? {
        let complete = observedDays.filter { !calendar.isDate($0.date, inSameDayAs: now) }
        let days = complete.count >= 2 ? complete : observedDays
        let starts = days.compactMap { day in firstActivity(day).map { $0.timeIntervalSince(day.date) } }
        let ends = days.compactMap { day in day.lastActiveEnd.map { $0.timeIntervalSince(day.date) } }
        guard starts.count >= 2, ends.count >= 2 else { return nil }
        return (Self.median(starts), Self.median(ends))
    }

    // MARK: - Hours

    /// The busiest clock window (one hour for a day, two for a period), averaged per observed day.
    var peakWindow: (hour: Int, length: Int, averageSeconds: TimeInterval)? {
        let totals = period.activeSecondsByHourOfDay(calendar: calendar)
        let length = isDay ? 1 : 2
        var best: (Int, TimeInterval)?
        for hour in 0...(24 - length) {
            let value = totals[hour..<(hour + length)].reduce(0, +)
            if value > (best?.1 ?? 0) { best = (hour, value) }
        }
        guard let best, best.1 >= 300 else { return nil }
        return (best.0, length, best.1 / Double(max(1, observedDays.count)))
    }

    /// Where classified work concentrates (one hour for a day, two for a period), averaged
    /// per observed day. Only meaningful once work is measurable.
    var workPeakWindow: (hour: Int, length: Int, averageSeconds: TimeInterval)? {
        guard workIsMeasurable else { return nil }
        let totals = period.workSecondsByHourOfDay(calendar: calendar)
        let length = isDay ? 1 : 2
        var best: (Int, TimeInterval)?
        for hour in 0...(24 - length) {
            let value = totals[hour..<(hour + length)].reduce(0, +)
            if value > (best?.1 ?? 0) { best = (hour, value) }
        }
        guard let best, best.1 >= 600 else { return nil }
        return (best.0, length, best.1 / Double(max(1, observedDays.count)))
    }

    // MARK: - Comparison

    /// Honest reference: the previous day at the same clock time for today, the previous
    /// day for a past day, the previous period's daily average for 7/28 days.
    var comparison: Comparison? {
        if isDay {
            guard let day = period.days.first, day.state == .ready, day.activeSeconds > 0,
                  let before = previous.days.last, before.state == .ready, before.activeSeconds > 0 else { return nil }
            if calendar.isDate(day.date, inSameDayAs: now) {
                let elapsed = now.timeIntervalSince(day.date)
                let cutoff = before.date.addingTimeInterval(elapsed)
                let earlier = before.segments.filter(\.kind.isActive).reduce(0.0) {
                    $0 + max(0, min($1.end, cutoff).timeIntervalSince($1.start))
                }
                return Comparison(current: day.activeSeconds, previous: earlier, label: "hier à la même heure")
            }
            return Comparison(current: day.activeSeconds, previous: before.activeSeconds, label: "la veille")
        }
        let beforeDays = previous.observedDays
        guard let current = averageActivePerDay, !beforeDays.isEmpty else { return nil }
        let average = previous.activeSeconds / Double(beforeDays.count)
        return Comparison(current: current, previous: average, label: "les \(period.days.count) jours précédents")
    }

    var bestDay: GoalongLocalAnalytics.Day? {
        guard !isDay else { return nil }
        return observedDays.max { $0.activeSeconds < $1.activeSeconds }
    }

    // MARK: - Insights

    func insights(topUsage: GoalongActivityUsageItem?, biggestChange: GoalongActivityUsageItem?) -> [Insight] {
        var result: [Insight] = []
        if isDay, let bounds = dayBounds {
            let span = bounds.end.timeIntervalSince(bounds.start)
            result.append(Insight(id: "bounds", symbol: "sunrise",
                text: "Première activité à \(Self.time(bounds.start)), dernière à \(Self.time(bounds.end)) · amplitude de \(Self.duration(span))."))
        } else if let bounds = typicalBounds {
            result.append(Insight(id: "bounds", symbol: "sunrise",
                text: "En général, vous commencez vers \(Self.clock(bounds.start)) et terminez vers \(Self.clock(bounds.end))."))
        }
        if let best = bestDay, observedDays.count >= 2 {
            result.append(Insight(id: "best-day", symbol: "star",
                text: "Journée la plus active : \(Self.weekdayDate(best.date)) · \(Self.duration(best.activeSeconds))."))
        }
        let workPeak = workPeakWindow
        // When work peaks in the same window, the work sentence says more with the same words.
        if let peak = peakWindow, workPeak.map({ $0.hour != peak.hour || $0.length != peak.length }) ?? true {
            let label = "\(peak.hour) h – \(peak.hour + peak.length) h"
            result.append(Insight(id: "peak", symbol: "chart.bar.fill",
                text: isDay ? "Heure la plus active : \(label), avec \(Self.duration(peak.averageSeconds)) d’activité."
                    : "Créneau le plus actif : \(label), avec \(Self.duration(peak.averageSeconds)) d’activité par jour en moyenne."))
        }
        if let work = workPeak {
            let label = "\(work.hour) h et \(work.hour + work.length) h"
            result.append(Insight(id: "work-peak", symbol: "briefcase",
                text: isDay ? "Votre travail se concentre entre \(label) (\(Self.duration(work.averageSeconds)))."
                    : "Vous travaillez surtout entre \(label), \(Self.duration(work.averageSeconds)) par jour en moyenne.",
                tone: .positive))
        }
        if let top = topUsage, activeSeconds > 0 {
            let share = Int((top.seconds / activeSeconds * 100).rounded())
            result.append(Insight(id: "top", symbol: top.isWebsite ? "globe" : "app",
                text: "Usage principal : \(top.displayName) · \(Self.duration(top.seconds)) (\(share) % du temps actif)."))
        }
        if let every = secondsPerChange, let perHour = changesPerActiveHour {
            result.append(Insight(id: "switches", symbol: "arrow.left.arrow.right",
                text: "Vous changez d’app ou de site toutes les \(Self.shortInterval(every)) en moyenne (\(Int(perHour.rounded())) fois par heure active).",
                tone: every < 60 ? .attention : .neutral))
        }
        if let comparison, abs(comparison.delta) >= 300 {
            let sign = comparison.delta > 0 ? "+" : "−"
            result.append(Insight(id: "comparison", symbol: comparison.delta > 0 ? "arrow.up.right" : "arrow.down.right",
                text: "\(sign)\(Self.duration(abs(comparison.delta))) d’activité \(isDay ? "" : "par jour ")par rapport à \(comparison.label)."))
        }
        if let change = biggestChange, let before = change.previousSeconds {
            let delta = change.seconds - before
            let sign = delta > 0 ? "+" : "−"
            result.append(Insight(id: "mover", symbol: "arrow.up.arrow.down",
                text: "Plus forte variation : \(change.displayName) (\(sign)\(Self.duration(abs(delta))))."))
        }
        if workIsMeasurable {
            var text = "Travail : \(Self.duration(workSeconds)) (\(Int((workShare * 100).rounded())) % du temps actif)"
            if let block = longestWorkBlock, block.workSeconds >= 600 {
                text += " · plus longue session sur une même tâche \(Self.duration(block.workSeconds))"
            }
            result.append(Insight(id: "work", symbol: "briefcase", text: text + ".", tone: .positive))
        } else if unclassifiedShare >= 0.3 {
            result.append(Insight(id: "classify", symbol: "tag",
                text: "\(Int((unclassifiedShare * 100).rounded())) % de votre temps n’est pas encore classé. Décrivez votre travail dans Mon travail pour le mesurer.",
                tone: .attention))
        }
        return result
    }

    /// The usage whose time changed the most against the previous period (≥ 10 min).
    static func biggestChange(_ items: [GoalongActivityUsageItem]) -> GoalongActivityUsageItem? {
        items.filter { $0.previousSeconds != nil }
            .max { abs($0.seconds - ($0.previousSeconds ?? 0)) < abs($1.seconds - ($1.previousSeconds ?? 0)) }
            .flatMap { abs($0.seconds - ($0.previousSeconds ?? 0)) >= 600 ? $0 : nil }
    }

    // MARK: - Formatting

    static func duration(_ seconds: TimeInterval) -> String { GoalongAnalyticsFormatting.duration(seconds) }
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
    static func clock(_ secondsAfterMidnight: TimeInterval) -> String {
        let minutes = Int((secondsAfterMidnight / 60).rounded()) % (24 * 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
    static func weekdayDate(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).weekday(.abbreviated).day().month(.abbreviated))
    }
    static func shortInterval(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        return "\(Int((seconds / 60).rounded())) min"
    }
    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
#endif
