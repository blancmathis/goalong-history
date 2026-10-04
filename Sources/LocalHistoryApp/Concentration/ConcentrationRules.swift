#if os(macOS)
import Foundation
import LocalHistoryCore

enum FocusPhases {
    private static func duration(_ index: Int, mode: FocusMode) -> Double {
        if index % 2 == 0 { return Double(mode.workMinutes * 60) }
        return Double(((index / 2 + 1) % mode.longBreakEvery == 0 ? mode.longBreakMinutes : mode.shortBreakMinutes) * 60)
    }
    /// Elapsed durations, independent of DST. Skip starts the next phase at the event time.
    static func phase(_ session: FocusSession, at now: Date) -> FocusPhase {
        if let end = session.endedAt, end <= now { return FocusPhase(kind: .ended, cycle: 0, startedAt: end) }
        guard session.mode.kind == .pomodoro else {
            let end = session.mode.minutes.map { session.startedAt.addingTimeInterval(Double($0 * 60)) }
            return FocusPhase(kind: end.map { now >= $0 } == true ? .ended : .work, cycle: 1,
                              startedAt: end.map { now >= $0 ? $0 : session.startedAt } ?? session.startedAt, endsAt: end)
        }
        let mode = session.mode
        var index = 0, start = session.startedAt
        func advance(to date: Date) {
            let groupPhases = mode.longBreakEvery * 2
            let groupSeconds = Double((mode.workMinutes * mode.longBreakEvery + mode.shortBreakMinutes * (mode.longBreakEvery - 1) + mode.longBreakMinutes) * 60)
            if let cycles = mode.cycles, index >= cycles * 2 - 1 { return }
            let groups = mode.cycles == nil ? max(0, Int(date.timeIntervalSince(start) / groupSeconds) - 1) : 0
            if groups > 0 { index += groups * groupPhases; start = start.addingTimeInterval(Double(groups) * groupSeconds) }
            while start.addingTimeInterval(duration(index, mode: mode)) <= date {
                if let cycles = mode.cycles, index >= cycles * 2 - 2 { start = start.addingTimeInterval(duration(index, mode: mode)); index = cycles * 2 - 1; return }
                start = start.addingTimeInterval(duration(index, mode: mode)); index += 1
            }
        }
        for event in session.events where event.kind == .skip && event.at <= now {
            advance(to: event.at)
            if let cycles = mode.cycles, index >= cycles * 2 - 1 { break }
            index += 1; start = event.at
        }
        advance(to: now)
        if let cycles = mode.cycles, index >= cycles * 2 - 1 { return FocusPhase(kind: .ended, cycle: cycles, startedAt: start) }
        let kind: FocusPhase.Kind = index % 2 == 0 ? .work : ((index / 2 + 1) % mode.longBreakEvery == 0 ? .longBreak : .shortBreak)
        return FocusPhase(kind: kind, cycle: index / 2 + 1, startedAt: start, endsAt: start.addingTimeInterval(duration(index, mode: mode)))
    }
    static func plannedEnd(_ session: FocusSession) -> Date? {
        if session.mode.kind == .free { return session.mode.minutes.map { session.startedAt.addingTimeInterval(Double($0 * 60)) } }
        guard let cycles = session.mode.cycles else { return nil }
        let mode = session.mode
        let breaks = cycles - 1, longs = breaks / mode.longBreakEvery
        let seconds = Double((cycles * mode.workMinutes + longs * mode.longBreakMinutes + (breaks - longs) * mode.shortBreakMinutes) * 60)
        // A far-future evaluation computes the actual end, including any skips.
        return phase(session, at: session.startedAt.addingTimeInterval(seconds + 1)).startedAt
    }
}

struct FocusDetectionRule: Equatable {
    var windowSeconds: Double = 1200
    var inputSeconds: Double = 960
    var maximumSwitches = 20
    var minimumStaySeconds: Double = 300
    var otherSeconds: Double = 60
    var switchesPerMinute = 3
    var noisyMinutes = 3
    var idleSeconds: Double = 120
    var maximumSampleGap: Double = 30
    var evaluationSeconds: Double = 0.75
}
struct FocusObservation {
    var at: Date
    var observing = true
    var available = true
    var idleSeconds: Double = 0
    var input = false
    /// Foreground app/domain/window key; only the bounded hash is kept in memory.
    var context: String = ""
    var verdict: GoalongWorkVerdict?
    var task: String?
}
struct FocusDetection {
    private struct Slice { var start: Date; var end: Date; var inputSeconds: Double; var other: Bool; var switches: Int }
    var rule = FocusDetectionRule()
    private var slices: [Slice] = []
    var retainedSliceCount: Int { slices.count }
    private var previous: FocusObservation?
    private(set) var enteredAt: Date?
    private var otherSince: Date?
    private var evaluatedAt = Date.distantPast
    mutating func reset() { slices.removeAll(keepingCapacity: true); previous = nil; enteredAt = nil; otherSince = nil; evaluatedAt = .distantPast }
    mutating func observe(_ value: FocusObservation) -> Bool {
        guard value.observing, value.available, value.idleSeconds < rule.idleSeconds else { reset(); return false }
        if let previous, value.at < previous.at { reset() }
        if let previous, value.at > previous.at {
            let elapsed = value.at.timeIntervalSince(previous.at)
            if elapsed <= rule.maximumSampleGap {
                let input = previous.input ? elapsed : 0, switches = previous.context != value.context ? 1 : 0
                if let last = slices.last, value.at.timeIntervalSince(last.start) <= rule.evaluationSeconds {
                    let i = slices.count - 1
                    slices[i].end = value.at; slices[i].inputSeconds += input
                    slices[i].other = slices[i].other || previous.verdict == .other; slices[i].switches += switches
                } else {
                    slices.append(Slice(start: previous.at, end: value.at, inputSeconds: input, other: previous.verdict == .other, switches: switches))
                }
            } else { slices.removeAll(keepingCapacity: true); enteredAt = nil }
        }
        previous = value
        let cutoff = value.at.addingTimeInterval(-rule.windowSeconds)
        slices.removeAll { $0.end <= cutoff }
        if value.verdict == .other { otherSince = otherSince ?? value.at } else { otherSince = nil }
        guard value.at.timeIntervalSince(evaluatedAt) >= rule.evaluationSeconds else { return enteredAt != nil }
        evaluatedAt = value.at
        let noisy = (0..<rule.noisyMinutes).allSatisfy { minute in
            let end = value.at.addingTimeInterval(-Double(minute * 60))
            return slices.filter { $0.end > end.addingTimeInterval(-60) && $0.end <= end }.reduce(0) { $0 + $1.switches } > rule.switchesPerMinute
        }
        if let enteredAt {
            let stay = value.at.timeIntervalSince(enteredAt) >= rule.minimumStaySeconds
            let other = otherSince.map { value.at.timeIntervalSince($0) >= rule.otherSeconds } ?? false
            if stay && (other || noisy) { self.enteredAt = nil }
        } else {
            let input = slices.reduce(0.0) { total, slice in total + slice.inputSeconds * max(0, slice.end.timeIntervalSince(max(slice.start, cutoff))) / max(0.001, slice.end.timeIntervalSince(slice.start)) }
            if slices.first.map({ $0.start <= cutoff }) == true && input >= rule.inputSeconds && !noisy && !slices.contains(where: \.other) && slices.reduce(0, { $0 + $1.switches }) <= rule.maximumSwitches && value.verdict != .other {
                enteredAt = value.at
            }
        }
        return enteredAt != nil
    }
}
struct FocusFacts: Codable, Equatable {
    var activeSeconds: Double = 0
    var workSeconds: Double = 0
    var otherSeconds: Double = 0
    var unclassifiedSeconds: Double = 0
    var appSwitches = 0
    var longestStretchSeconds: Double = 0
    var available = false
}
struct FocusItemMeasure: Codable, Equatable {
    var id: UUID
    var sessionMinutes: Double
    var projectWorkMinutes: Double?
    /// Union of linked work-phase intervals and measured project work; never their overlapping sum.
    var measuredMinutes: Double?
    var estimateMinutes: Int?
}
enum FocusMeasurement {
    static func workIntervals(_ session: FocusSession, from lower: Date? = nil, until now: Date) -> [DateInterval] {
        let end = min(now, session.endedAt ?? now)
        var cursor = max(session.startedAt, lower ?? session.startedAt), intervals: [DateInterval] = []
        while cursor < end, intervals.count < 4096 {
            let phase = FocusPhases.phase(session, at: cursor)
            guard phase.kind != .ended else { break }
            let skip = session.events.first { $0.kind == .skip && $0.at > cursor }?.at
            let next = min(end, min(phase.endsAt ?? end, skip ?? end))
            guard next > cursor else { break }
            if phase.isWork { intervals.append(DateInterval(start: cursor, end: next)) }
            cursor = next
        }
        return intervals
    }
    static func unionSeconds(_ intervals: [DateInterval]) -> Double {
        var end = Date.distantPast, seconds = 0.0
        for i in intervals.sorted(by: { $0.start < $1.start }) {
            seconds += max(0, i.end.timeIntervalSince(max(i.start, end))); end = max(end, i.end)
        }
        return seconds
    }
    static func item(_ item: FocusPlanItem, sessions: [FocusSession], day: GoalongLocalAnalytics.Day?, now: Date) -> FocusItemMeasure {
        let bounds = day.map { DateInterval(start: $0.date, end: $0.end) }
        let linked = sessions.filter { $0.planItemId == item.id }.flatMap { workIntervals($0, from: bounds?.start, until: now) }.compactMap { bounds?.intersection(with: $0) ?? (bounds == nil ? $0 : nil) }
        let project = item.project.flatMap { name in day.map { $0.segments.filter { $0.kind == .work && $0.task?.localizedCaseInsensitiveCompare(name) == .orderedSame }.map { DateInterval(start: $0.start, end: $0.end) } } }
        return FocusItemMeasure(id: item.id, sessionMinutes: unionSeconds(linked) / 60, projectWorkMinutes: project.map { unionSeconds($0) / 60 },
                                measuredMinutes: (day == nil || day?.state == .noSource) && linked.isEmpty ? nil : unionSeconds(linked + (project ?? [])) / 60, estimateMinutes: item.estimateMinutes)
    }
    static func estimateRatio(_ measures: [FocusItemMeasure]) -> Double? {
        let values = measures.filter { $0.estimateMinutes.map({ $0 > 0 }) == true && $0.measuredMinutes.map({ $0.isFinite && $0 >= 0 }) == true }.suffix(20)
            .map { $0.measuredMinutes! / Double($0.estimateMinutes!) }.sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count % 2 == 0 ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }
    static func facts(day: GoalongLocalAnalytics.Day?, from start: Date, to end: Date) -> FocusFacts {
        guard let day else { return FocusFacts() }
        let interval = DateInterval(start: start, end: max(start, end))
        var facts = FocusFacts(available: day.state != .noSource), previous: GoalongLocalAnalytics.Segment?, stretch = 0.0
        for segment in day.segments {
            guard let clip = interval.intersection(with: DateInterval(start: segment.start, end: segment.end)) else { continue }
            if segment.kind.isActive {
                facts.activeSeconds += clip.duration
                if segment.kind == .work { facts.workSeconds += clip.duration }
                else if segment.kind == .other { facts.otherSeconds += clip.duration }
                else { facts.unclassifiedSeconds += clip.duration }
                if let p = previous, p.end == segment.start, p.kind.isActive {
                    if p.bundleIdentifier != segment.bundleIdentifier { facts.appSwitches += 1 }
                    stretch = p.focusKey == segment.focusKey ? stretch + clip.duration : clip.duration
                } else { stretch = clip.duration }
                facts.longestStretchSeconds = max(facts.longestStretchSeconds, stretch)
            } else { stretch = 0 }
            previous = segment
        }
        return facts
    }
}
struct FocusLimitMark: Codable, Equatable { var kind: String; var period: String; var at: Date; var usesActiveTime: Bool }
enum FocusLimitRules {
    static func crossings(limits: FocusLimits, dailySeconds: Double, weeklySeconds: Double, hasDefinition: Bool,
                          at now: Date, calendar: Calendar = .current, marks: [FocusLimitMark]) -> [FocusLimitMark] {
        let day = FocusCalendar.dayKey(now, calendar: calendar)
        let week = FocusCalendar.weekKey(now, calendar: calendar)
        var candidates: [FocusLimitMark] = []
        if let hours = limits.dailyHours, dailySeconds >= Double(hours * 3600) { candidates.append(.init(kind: "daily", period: day, at: now, usesActiveTime: !hasDefinition)) }
        if let hours = limits.weeklyHours, weeklySeconds >= Double(hours * 3600) { candidates.append(.init(kind: "weekly", period: week, at: now, usesActiveTime: !hasDefinition)) }
        if let minute = limits.endMinute, limits.weekdays.contains(BlockingSchedule.isoWeekday(now, calendar: calendar)),
           calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now) >= minute {
            candidates.append(.init(kind: "endOfDay", period: day, at: now, usesActiveTime: !hasDefinition))
        }
        return candidates.filter { candidate in !marks.contains { $0.kind == candidate.kind && $0.period == candidate.period } }
    }
}

enum FocusCommitRule {
    enum Check: Equatable { case free, harderOnly, locked(String) }
    static func check(old: FocusCommitment, new: FocusCommitment?, now: Date, calendar: Calendar = .current) -> Check {
        guard old.result == nil else { return .locked("Cet engagement est déjà réglé.") }
        guard let interval = old.period.interval(calendar: calendar) else { return .locked("Période invalide.") }
        if now < max(old.createdAt.addingTimeInterval(600), interval.start) { return .free }
        guard let new else { return .locked("La fenêtre de modification est terminée.") }
        guard new.id == old.id, new.period == old.period, new.kind == old.kind, new.task == old.task,
              new.createdAt == old.createdAt, new.target >= old.target else { return .locked("L’engagement peut seulement devenir plus exigeant.") }
        if let stake = old.stake {
            guard let next = new.stake, Set(stake.listIds).isSubset(of: Set(next.listIds)),
                  (next.minute ?? -1) >= (stake.minute ?? 1440) else { return .locked("L’enjeu ne peut pas être réduit.") }
        }
        return .harderOnly
    }
}

enum FocusCommitmentRules {
    static func mayCreate(_ period: FocusCommitmentPeriod, at now: Date, calendar: Calendar = .current) -> Bool {
        guard let interval = period.interval(calendar: calendar) else { return false }
        let c = FocusCalendar.civil(calendar)
        let start = period.kind == .day ? c.startOfDay(for: now) : FocusCalendar.weekInterval(now, calendar: calendar).start
        let last = c.date(byAdding: .day, value: 7, to: start)!
        return interval.start >= start && interval.start <= last
    }
    static func progress(_ commitment: FocusCommitment, days: [GoalongLocalAnalytics.Day], sessions: [FocusSession],
                         plans: [FocusPlan], at now: Date, hasDefinition: Bool, calendar: Calendar = .current) -> FocusCommitmentProgress {
        var result = FocusCommitmentProgress(usesActiveTime: commitment.kind == .work && !hasDefinition)
        guard let period = commitment.period.interval(calendar: calendar), now > period.start else { return result }
        let bounds = DateInterval(start: period.start, end: min(now, period.end))
        switch commitment.kind {
        case .work, .task:
            var measured: [DateInterval] = [], classified: [DateInterval] = []
            for day in days where day.state != .noSource {
                for s in day.segments where s.end > s.start {
                    guard let clip = bounds.intersection(with: DateInterval(start: s.start, end: s.end)), clip.duration > 0 else { continue }
                    if s.kind != .unobserved && s.kind != .concealed && s.kind != .unclassified { classified.append(clip) }
                    let matches = commitment.kind == .work ? (hasDefinition ? s.kind == .work : s.kind.isActive)
                        : s.kind == .work && s.task?.localizedCaseInsensitiveCompare(commitment.task ?? "") == .orderedSame
                    if matches { measured.append(clip) }
                }
            }
            result.measured = FocusMeasurement.unionSeconds(measured) / 60
            // Missing days/gaps, concealed contexts and unclassified time stay explicit uncertainty.
            result.unmeasuredMinutes = max(0, bounds.duration - FocusMeasurement.unionSeconds(classified)) / 60
        case .sessions:
            var seen = Set<UUID>()
            result.measured = Double(sessions.filter { session in
                seen.insert(session.id).inserted && FocusMeasurement.unionSeconds(FocusMeasurement.workIntervals(session, from: bounds.start, until: bounds.end)) >= 900
            }.count)
        case .plan:
            result.measured = Double(plans.filter { plan in
                guard let day = FocusCalendar.dayInterval(plan.day, calendar: calendar) else { return false }
                return day.start >= bounds.start && day.start < bounds.end
            }.reduce(0) { $0 + $1.items.filter { $0.status == .done }.count })
        }
        return result
    }
    static func stakeEnd(_ stake: FocusStake, settledAt: Date, calendar: Calendar = .current) -> Date? {
        guard let minute = stake.minute else { return nil }
        return FocusCalendar.civil(calendar).date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: settledAt,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    static func settle(_ commitment: FocusCommitment, progress: FocusCommitmentProgress, at now: Date,
                       blockingOn: Bool, listIDs: Set<UUID>, calendar: Calendar = .current) -> FocusCommitmentResult? {
        guard commitment.result == nil, let period = commitment.period.interval(calendar: calendar), now >= period.end else { return nil }
        var result = FocusCommitmentResult(settledAt: now, measured: progress.measured, unmeasuredMinutes: progress.unmeasuredMinutes,
                                          outcome: progress.measured >= Double(commitment.target) ? .held : .missed)
        result.usesActiveTime = progress.usesActiveTime
        if result.outcome == .missed, let stake = commitment.stake {
            if stakeEnd(stake, settledAt: now, calendar: calendar).map({ $0 <= now }) != false { result.stake = .init(state: .skipped, reason: .late) }
            else if !blockingOn { result.stake = .init(state: .skipped, reason: .blockingOff) }
            else if Set(stake.listIds).intersection(listIDs).isEmpty { result.stake = .init(state: .skipped, reason: .noList) }
            else { result.stake = .init(state: .applied, blockId: commitment.id) }
        }
        return result
    }
    /// Month of the last civil day in the period, not the exclusive midnight end or settle month.
    static func jokerMonth(_ period: FocusCommitmentPeriod, calendar: Calendar = .current) -> String? {
        period.interval(calendar: calendar).map { String(FocusCalendar.dayKey($0.end.addingTimeInterval(-1), calendar: calendar).prefix(7)) }
    }
    static func jokersLeft(period: FocusCommitmentPeriod, commitments: [FocusCommitment], settings: FocusJokerSettings,
                           calendar: Calendar = .current) -> Int {
        let month = jokerMonth(period, calendar: calendar)
        let used = commitments.filter { $0.period.kind == period.kind && $0.result?.jokerAt != nil && jokerMonth($0.period, calendar: calendar) == month }.count
        return max(0, (period.kind == .day ? settings.day : settings.week) - used)
    }
    static func series(_ commitments: [FocusCommitment], kind: FocusCommitmentPeriod.Kind, calendar: Calendar = .current) -> Int {
        let settled = commitments.filter { $0.period.kind == kind && $0.result != nil }.sorted { $0.period.key < $1.period.key }
        var count = 0
        for commitment in settled {
            if commitment.result?.outcome == .held || commitment.result?.jokerAt != nil { count += 1 } else { count = 0 }
        }
        return count
    }
    static func stakeWindow(_ commitment: FocusCommitment, blockEnd: Date? = nil, calendar: Calendar = .current) -> Date? {
        guard let result = commitment.result, result.outcome == .missed, result.jokerAt == nil, !result.declared else { return nil }
        if result.stake.state == .applied, let stake = commitment.stake {
            return blockEnd ?? stakeEnd(stake, settledAt: result.settledAt, calendar: calendar)
        }
        return FocusCalendar.civil(calendar).date(byAdding: .day, value: 1, to: FocusCalendar.civil(calendar).startOfDay(for: result.settledAt))
    }
}
#endif
