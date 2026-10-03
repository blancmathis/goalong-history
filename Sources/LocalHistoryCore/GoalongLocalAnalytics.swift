import Foundation

/// A read-only projection of foreground observations, not a productivity or attention score.
/// Every elapsed second belongs to one state; missing evidence is never inferred as rest.
public enum GoalongLocalAnalytics {
    public static let method = "local-observed-rhythm-v4"
    public static let maximumGap: TimeInterval = 120
    public static let idleThreshold = ForegroundActivityEvidence.inputIdleThreshold

    public enum Kind: String, CaseIterable, Codable, Sendable {
        case work, other, unclassified, idle, concealed, unobserved
        public var isActive: Bool { self == .work || self == .other || self == .unclassified }
    }
    public enum State: String, Codable, Sendable { case ready, noSource, incomplete }
    public struct Segment: Identifiable, Equatable, Sendable {
        public let start: Date
        public var end: Date
        /// Active time is `.unclassified` until the user's work definition labels its context.
        public var kind: Kind
        public let application: String?
        public let bundleIdentifier: String?
        public let host: String?
        /// What was on screen (application + site + window title), see `GoalongWorkContext`.
        public var contextKey: String? = nil
        /// The task this work served, as named by the agent or the user.
        public var task: String? = nil
        public var coverageReason: GoalongCoverageReason? = nil
        public var id: Date { start }
        public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
        /// Application + domain: what an app switch changes.
        public var context: String? {
            guard let application else { return nil }
            return (bundleIdentifier ?? application) + "|" + (host ?? "")
        }
        /// One task stays one focus across applications; otherwise application + domain.
        public var focusKey: String? {
            if kind == .work, let task { return "task|" + task }
            return context
        }
    }
    public struct Focus: Identifiable, Equatable, Sendable {
        public let start: Date
        public var end: Date
        public let application: String
        public let host: String?
        public let context: String
        public var task: String? = nil
        public var id: Date { start }
        public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }
    public struct Usage: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let bundleIdentifier: String?
        public var seconds: TimeInterval
    }
    public struct Hour: Identifiable, Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let seconds: TimeInterval
        public let focusSeconds: TimeInterval
        /// Parts of `seconds`; the remainder is still to be classified.
        public var workSeconds: TimeInterval = 0
        public var otherSeconds: TimeInterval = 0
        public var id: Date { start }
        public var unclassifiedSeconds: TimeInterval { max(0, seconds - workSeconds - otherSeconds) }
    }
    public struct Day: Identifiable, Equatable, Sendable {
        public let date: Date
        public let end: Date
        public let state: State
        public let segments: [Segment]
        public let eventCount: Int
        public let classifierVersions: Set<String>
        public var origin: GoalongDayOrigin = .journal
        public var hasDetailedSource: Bool = true
        public var dayReason: GoalongCoverageReason? = nil
        public var firstObservation: Date? = nil
        public var lastObservation: Date? = nil
        public var recordedBreakdown: GoalongActivityBreakdown? = nil
        public var id: Date { date }
        public var activeSeconds: TimeInterval { seconds(.work) + seconds(.other) + seconds(.unclassified) }
        public var observedSeconds: TimeInterval { segments.filter { $0.kind != .unobserved }.reduce(0) { $0 + $1.seconds } }
        public func seconds(_ kind: Kind) -> TimeInterval { segments.filter { $0.kind == kind }.reduce(0) { $0 + $1.seconds } }
        public var contextChanges: Int {
            zip(segments, segments.dropFirst()).filter { a, b in
                a.kind.isActive && b.kind.isActive && a.end == b.start && a.context != b.context
            }.count
        }
        /// Application switches that stayed on the same task.
        public var sameTaskChanges: Int {
            zip(segments, segments.dropFirst()).filter { a, b in
                a.kind == .work && b.kind == .work && a.end == b.start && a.task != nil && a.task == b.task
                    && a.context != b.context
            }.count
        }
        /// Same task (whatever the applications), otherwise same application + domain;
        /// never across a gap or idle state.
        public var sequences: [Focus] {
            var result: [Focus] = []
            for segment in segments where segment.kind.isActive {
                guard let application = segment.application, let context = segment.focusKey else { continue }
                if let last = result.last, last.end == segment.start, last.context == context {
                    result[result.count - 1].end = segment.end
                } else {
                    result.append(Focus(start: segment.start, end: segment.end, application: application,
                        host: segment.host, context: context, task: segment.kind == .work ? segment.task : nil))
                }
            }
            return result
        }
        public func focus(minimumMinutes: Int) -> [Focus] {
            sequences.filter { $0.seconds >= Double(max(1, minimumMinutes)) * 60 }
        }
        public func focusSeconds(minimumMinutes: Int) -> TimeInterval {
            focus(minimumMinutes: minimumMinutes).reduce(0) { $0 + $1.seconds }
        }
        /// Uses calendar hour intervals, including 23/25-hour DST days.
        public func hours(minimumMinutes: Int, calendar: Calendar = .current) -> [Hour] {
            var result: [Hour] = [], cursor = date
            let blocks = focus(minimumMinutes: minimumMinutes)
            while cursor < end, result.count < 26 {
                guard let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end, hourEnd > cursor else { break }
                let stop = min(end, hourEnd)
                var active = 0.0, work = 0.0, other = 0.0
                for segment in segments where segment.kind.isActive && segment.end > cursor && segment.start < stop {
                    let seconds = Self.overlap(segment.start, segment.end, cursor, stop)
                    active += seconds
                    if segment.kind == .work { work += seconds } else if segment.kind == .other { other += seconds }
                }
                let focus = blocks.reduce(0.0) { $0 + Self.overlap($1.start, $1.end, cursor, stop) }
                result.append(Hour(start: cursor, end: stop, seconds: active, focusSeconds: focus,
                                   workSeconds: work, otherSeconds: other))
                cursor = stop
            }
            return result
        }
        private static func overlap(_ a: Date, _ b: Date, _ c: Date, _ d: Date) -> TimeInterval {
            max(0, min(b, d).timeIntervalSince(max(a, c)))
        }
    }
    public struct Period: Equatable, Sendable {
        public let days: [Day]
        public var activeSeconds: TimeInterval { days.reduce(0) { $0 + $1.activeSeconds } }
        public var workSeconds: TimeInterval { days.reduce(0) { $0 + $1.seconds(.work) } }
        public var daysWithObservations: Int { days.filter { $0.activeSeconds > 0 }.count }
        public var eventCount: Int { days.reduce(0) { $0 + $1.eventCount } }
        public var observedSeconds: TimeInterval { days.reduce(0) { $0 + $1.observedSeconds } }
        public var incompleteDays: Int { days.filter { $0.state == .incomplete }.count }
        public var contextChanges: Int { days.reduce(0) { $0 + $1.contextChanges } }
        public var sameTaskChanges: Int { days.reduce(0) { $0 + $1.sameTaskChanges } }
        public var classifierVersions: Set<String> { days.reduce(into: []) { $0.formUnion($1.classifierVersions) } }
        public init(days: [Day]) { self.days = days }
        public func focus(minimumMinutes: Int) -> [Focus] { days.flatMap { $0.focus(minimumMinutes: minimumMinutes) } }
        public func focusSeconds(minimumMinutes: Int) -> TimeInterval { days.reduce(0) { $0 + $1.focusSeconds(minimumMinutes: minimumMinutes) } }
        public func usage(websites: Bool = false) -> [Usage] {
            var values: [String: Usage] = [:]
            for segment in days.flatMap(\.segments) where segment.kind.isActive {
                guard let name = websites ? segment.host : segment.application else { continue }
                let id = websites ? name : (segment.bundleIdentifier ?? name)
                var item = values[id] ?? Usage(id: id, name: name,
                    bundleIdentifier: websites ? nil : segment.bundleIdentifier, seconds: 0)
                item.seconds += segment.seconds; values[id] = item
            }
            return values.values.sorted { a, b in a.seconds == b.seconds ? a.id < b.id : a.seconds > b.seconds }
        }
    }

    public static func build(events: [HistoryEvent], day: Date, now: Date = Date(),
                             calendar: Calendar = .current, incomplete: Bool = false) -> Day {
        let start = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let end = max(start, min(dayEnd, now))
        let rows = evidenceRows(events, start: start, end: end)
        // A genuinely failed or unstable source still must not publish plausible totals.
        if incomplete { return unreadable(start: start, end: end, eventCount: rows.count) }
        // The same fold refreshes today from its last checkpoint: one definition of a day.
        var fold = DayFold(start: start, calendar: calendar)
        for row in rows { fold.consume(row) }
        return fold.finish(end: end)
    }

    static func unreadable(start: Date, end: Date, eventCount: Int) -> Day {
        Day(date: start, end: end, state: .incomplete, segments: end > start ? [Segment(start: start, end: end,
            kind: .unobserved, application: nil, bundleIdentifier: nil, host: nil, coverageReason: .unreadable)] : [],
            eventCount: eventCount, classifierVersions: [], dayReason: .unreadable)
    }

    /// Buffered typing/scroll bursts can be appended after newer foreground samples.
    /// Journal append order is not observation time order. Sort only this read-only
    /// projection, preserving journal order for ties (timestamps can be second-precision).
    static func evidenceRows(_ events: [HistoryEvent], start: Date, end: Date) -> [HistoryEvent] {
        events.enumerated()
            .filter { $0.element.timestamp >= start && $0.element.timestamp <= end && $0.element.isDerivedAnalysisEvidence }
            .sorted { a, b in
                a.element.timestamp == b.element.timestamp
                    ? a.offset < b.offset : a.element.timestamp < b.element.timestamp
            }.map(\.element)
    }

    /// The committed prefix has no leading/trailing extrapolation. Its last row is kept
    /// solely to form the next interval, including the last row of a timestamp tie.
    fileprivate struct DayFold {
        let start: Date
        let calendar: Calendar
        var segments: [Segment] = []
        var modes = GoalongActivityBreakdown.MinuteModes()
        var tracker = GoalongWorkContext.Tracker()
        var firstTimestamp: Date?
        var last: HistoryEvent?
        var lastContextKey: String?
        var rowCount = 0

        init(start: Date, calendar: Calendar) { self.start = start; self.calendar = calendar }

        mutating func consume(_ next: HistoryEvent) {
            let key = tracker.context(for: next)?.key
            modes.add(next, calendar: calendar)
            defer { last = next; lastContextKey = key; rowCount += 1 }
            guard let previous = last else { firstTimestamp = next.timestamp; return }
            // Goalong never labels an application as work: active time stays to classify
            // until the user's own definition is applied to its context.
            let contextKey = lastContextKey
            let gap = next.timestamp.timeIntervalSince(previous.timestamp)
            guard gap > 0 else { return }
            let kind: Kind
            var coverageReason: GoalongCoverageReason?
            if gap > maximumGap || next.metadata?["observation_gap"] == "true" {
                kind = .unobserved
                if next.metadata?["observation_gap"] == "true" { coverageReason = .observationGap }
                else if previous.suppressionReason != nil || [.recorderStopped, .recordingPaused, .systemSleep,
                    .sessionLocked, .secureInputSuppressed, .historyCleared].contains(previous.kind) {
                    coverageReason = .opening(previous)
                } else { coverageReason = .gap }
            } else if let reason = previous.suppressionReason {
                coverageReason = .opening(previous)
                switch reason {
                case .privateBrowserWindow, .excludedApplication, .excludedDomain, .secureInput, .manualPause:
                    kind = .concealed
                case .sessionUnavailable, .accessibilityUnavailable:
                    kind = .unobserved
                }
            } else if previous.isObservationContinuityBoundary || previous.app?.name.isEmpty != false {
                kind = .unobserved
                coverageReason = .opening(previous)
            } else if ForegroundUsageObservation.usesPresencePolicy(previous) {
                let seconds = ForegroundUsageObservation.activeDuration(after: previous,
                    until: next.timestamp, nextEvent: next)
                let activeEnd = previous.timestamp.addingTimeInterval(seconds)
                // A browser-process wake assertion cannot attribute the content of an unproven tab.
                let attributable = previous.url?.host == nil || ForegroundActivityEvidence.supportsWebsiteAttribution(previous)
                let siteSeconds = ForegroundUsageObservation.websiteDuration(after: previous,
                    until: next.timestamp, nextEvent: next)
                if previous.url?.host != nil && siteSeconds < seconds {
                    let siteEnd = previous.timestamp.addingTimeInterval(siteSeconds)
                    append(previous.timestamp, siteEnd, .unclassified, previous, contextKey: attributable ? contextKey : nil)
                    append(siteEnd, activeEnd, .unclassified, previous, websiteAllowed: false)
                } else {
                    append(previous.timestamp, activeEnd, .unclassified, previous, contextKey: attributable ? contextKey : nil)
                }
                // Split at the exact reading expiry. A later idle observation
                // never erases a preceding minute of reading or revives absence.
                append(activeEnd, next.timestamp,
                    ForegroundUsageObservation.hasVisibleForeground(previous) ? .idle : .unobserved,
                    reason: ForegroundUsageObservation.hasVisibleForeground(previous) ? nil : .noVisibleForeground)
                return
            } else if ForegroundActivityEvidence.isInputIdle(previous)
                || (ForegroundActivityEvidence.isInputIdle(next)
                    && ForegroundActivityEvidence.evidence(in: previous) == nil) {
                // A later idle sample/app switch must not erase an observed call
                // preceding it; equally, a later call must not revive earlier idle.
                kind = .idle
            } else {
                kind = .unclassified
            }
            // A browser-process wake assertion cannot attribute the content of an unproven tab.
            let attributable = previous.url?.host == nil || ForegroundActivityEvidence.supportsWebsiteAttribution(previous)
            append(previous.timestamp, next.timestamp, kind, previous, contextKey: attributable ? contextKey : nil, reason: coverageReason)
        }

        mutating func append(_ a: Date, _ b: Date, _ kind: Kind, _ event: HistoryEvent? = nil,
                    websiteAllowed: Bool = true, contextKey: String? = nil, reason: GoalongCoverageReason? = nil) {
            guard b > a else { return }
            let active = kind.isActive
            if active, let event, let evidence = ForegroundActivityEvidence.evidence(in: event) {
                modes.add(evidence, from: a, to: b, calendar: calendar)
            }
            let application = active ? event?.app?.name : nil
            let bundle = active ? event?.app?.bundleIdentifier : nil
            let host = active && websiteAllowed && event.map(ForegroundActivityEvidence.supportsWebsiteAttribution) == true
                ? event?.url?.host : nil
            let key = active ? contextKey : nil
            if let last = segments.last, last.end == a, last.kind == kind,
               last.application == application, last.bundleIdentifier == bundle, last.host == host,
               last.contextKey == key, last.coverageReason == reason {
                segments[segments.count - 1].end = b
            } else {
                segments.append(Segment(start: a, end: b, kind: kind, application: application,
                    bundleIdentifier: bundle, host: host, contextKey: key, coverageReason: reason))
            }
        }

        /// Finalization only touches a copy: the next read can replace the entire window,
        /// and no previous trailing `unobserved` segment can become an observed interval.
        func finish(end: Date) -> Day {
            var final = self
            guard let first = firstTimestamp, let last else {
                final.append(start, end, .unobserved, reason: .notRecorded)
                return Day(date: start, end: end, state: .noSource, segments: final.segments,
                    eventCount: 0, classifierVersions: [], dayReason: .notRecorded)
            }
            // No reason inside the day is `beforeFirstObservation`: this never merges.
            if first > start {
                final.segments.insert(Segment(start: start, end: first, kind: .unobserved, application: nil,
                    bundleIdentifier: nil, host: nil, coverageReason: .beforeFirstObservation), at: 0)
            }
            // A last foreground sample is not evidence that activity continued after that sample.
            let tailReason: GoalongCoverageReason = last.suppressionReason != nil || [.recorderStopped, .recordingPaused,
                .systemSleep, .sessionLocked, .secureInputSuppressed, .historyCleared].contains(last.kind)
                ? .opening(last) : .afterLastObservation
            final.append(last.timestamp, end, .unobserved, reason: tailReason)
            return Day(date: start, end: end, state: .ready, segments: final.segments, eventCount: rowCount,
                classifierVersions: [GoalongLocalAnalytics.method], firstObservation: first, lastObservation: last.timestamp,
                recordedBreakdown: .build(segments: final.segments, modes: final.modes, calendar: calendar))
        }
    }

    /// A committed prefix plus a 15-minute reorder window. `events` contains only the
    /// sorted window (including rows after `now`), never all of today's source events.
    /// The prefix holds derived segments, context hashes, counters and one boundary row.
    /// These value data contain no reader/file handle and stay owned by the app's actor.
    public struct ResumableDayState: @unchecked Sendable {
        public let cursor: HistoryLocalAnalyticsCursor?
        public let events: [HistoryEvent]
        public let windowStart: Date
        public let incomplete: Bool
        public var foldedEventCount: Int { fold.rowCount }
        public var retainedEventCount: Int { fold.rowCount + events.count }
        fileprivate let fold: DayFold
        fileprivate let evaluatedThrough: Date
    }

    public struct ResumableDayLoad: Sendable {
        public let day: Day
        /// Last complete checkpoint, unchanged if this attempt failed or was cancelled.
        public let state: ResumableDayState?
        public let didResume: Bool
        public let eventBytesRead: Int64
        public let wasCancelled: Bool
    }

    /// Only appended complete lines are decoded, and only the reorder window is folded
    /// again. Older arrivals or uncertain journal ordering transparently read the full day.
    public static func load(root: URL, day: Date, resuming state: ResumableDayState?,
                            now: Date = Date(), calendar: Calendar = .current,
                            shouldContinue: () -> Bool = { true }) -> ResumableDayLoad {
        let start = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let end = min(dayEnd, now)
        guard end > start, shouldContinue() else {
            return ResumableDayLoad(day: build(events: [], day: day, now: now, calendar: calendar, incomplete: end > start),
                state: state, didResume: false, eventBytesRead: 0, wasCancelled: end > start)
        }
        let reader = HistoryLocalStoreReader(rootDirectory: root)
        // Read to dayEnd: rows written during the read may be later than `now`. They stay
        // in the window and become visible only once `now` reaches their timestamps.
        // Rewinding `now` also requires the prefix rows that were already discarded.
        let candidate = state.flatMap { $0.fold.start == start && end >= $0.evaluatedThrough ? $0 : nil }
        var loaded = reader.loadLocalAnalyticsEvidence(start: start, endExclusive: dayEnd,
            resumeCursor: candidate?.cursor, timeZoneIdentifier: calendar.timeZone.identifier,
            shouldContinue: shouldContinue)
        var bytesRead = loaded.metrics.eventBytesRead
        if loaded.didResume, !loaded.metrics.wasCancelled, !loaded.metrics.sourceChangedDuringRead,
           !loaded.metrics.sourceAccessWasIncomplete, !loaded.metrics.evidenceBudgetExceeded, loaded.issues.isEmpty {
            let canFold: Bool
            if let candidate, let cursor = candidate.cursor {
                canFold = loaded.appendedEventCounts.count == cursor.files.count
                    && cursor.files.reduce(0, { $0 + $1.retainedEventCount }) == candidate.retainedEventCount
                    && loaded.appendedEventCounts.reduce(0, +) == loaded.events.count
                    && !loaded.events.contains { $0.timestamp < candidate.windowStart }
                    // Full-read file order precedes timestamp ordering. An earlier file's
                    // new ties could precede discarded rows of a later file: reread safely.
                    && (cursor.files.count <= 1 || loaded.events.isEmpty)
            } else { canFold = false }
            if !canFold {
                loaded = reader.loadLocalAnalyticsEvidence(start: start, endExclusive: dayEnd,
                    timeZoneIdentifier: calendar.timeZone.identifier, shouldContinue: shouldContinue)
                bytesRead += loaded.metrics.eventBytesRead
            }
        }
        let metrics = loaded.metrics
        let incomplete = metrics.wasCancelled || metrics.sourceChangedDuringRead || metrics.sourceAccessWasIncomplete
            || metrics.evidenceBudgetExceeded || !loaded.issues.isEmpty
        var checkpoint = loaded.didResume ? candidate!.fold : DayFold(start: start, calendar: calendar)
        // Incomplete output reports the count without publishing any plausible durations.
        // A failed attempt never changes the caller's last successful state.
        let projectionWasRejected = metrics.sourceChangedDuringRead || metrics.sourceAccessWasIncomplete
            || metrics.evidenceBudgetExceeded
        let count = projectionWasRejected ? 0 : checkpoint.rowCount
            + (loaded.didResume ? candidate!.events.filter { $0.timestamp <= end }.count : 0)
            + loaded.events.filter { $0.timestamp <= end }.count
        func failure(cancelled: Bool) -> ResumableDayLoad {
            ResumableDayLoad(day: unreadable(start: start, end: end, eventCount: count), state: state, didResume: loaded.didResume,
                eventBytesRead: bytesRead, wasCancelled: cancelled)
        }
        guard !incomplete else { return failure(cancelled: metrics.wasCancelled) }
        let rows: [HistoryEvent]
        if loaded.didResume, loaded.events.isEmpty {
            rows = candidate!.events
        } else {
            // For a single journal old rows always precede appended rows on timestamp ties.
            rows = evidenceRows((loaded.didResume ? candidate!.events : []) + loaded.events, start: start, end: dayEnd)
        }
        let latest = rows.last?.timestamp ?? checkpoint.last?.timestamp ?? start
        let windowStart = max(start, min(latest, end).addingTimeInterval(-15 * 60))
        var committed = 0
        for row in rows {
            guard row.timestamp < windowStart else { break }
            if committed % 128 == 0, !shouldContinue() { return failure(cancelled: true) }
            checkpoint.consume(row); committed += 1
        }
        let window = Array(rows.dropFirst(committed))
        var displayed = checkpoint
        for (index, row) in window.enumerated() {
            guard row.timestamp <= end else { break }
            if index % 128 == 0, !shouldContinue() { return failure(cancelled: true) }
            displayed.consume(row)
        }
        guard shouldContinue() else { return failure(cancelled: true) }
        let next = ResumableDayState(cursor: loaded.resumeCursor, events: window, windowStart: windowStart,
            incomplete: false, fold: checkpoint, evaluatedThrough: end)
        return ResumableDayLoad(day: displayed.finish(end: end), state: next, didResume: loaded.didResume,
            eventBytesRead: bytesRead, wasCancelled: false)
    }

    public static func load(root: URL, day: Date, now: Date = Date(), calendar: Calendar = .current,
                            shouldContinue: () -> Bool = { true }) -> Day {
        let start = calendar.startOfDay(for: day)
        let end = min(calendar.date(byAdding: .day, value: 1, to: start) ?? start, now)
        guard end > start, shouldContinue() else {
            return build(events: [], day: day, now: now, calendar: calendar)
        }
        let loaded = HistoryLocalStoreReader(rootDirectory: root).loadLocalAnalyticsEvidence(
            start: start, endExclusive: end, shouldContinue: shouldContinue)
        let metrics = loaded.metrics
        return build(events: loaded.events, day: day, now: now, calendar: calendar,
            incomplete: metrics.wasCancelled || metrics.sourceChangedDuringRead || metrics.sourceAccessWasIncomplete
                || metrics.evidenceBudgetExceeded || !loaded.issues.isEmpty)
    }
}
