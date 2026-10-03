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
        var segments: [Segment] = []
        var passive: [GoalongActivityBreakdown.PassiveInterval] = []
        var tracker = GoalongWorkContext.Tracker()
        let contextKeys = rows.map { tracker.context(for: $0)?.key }
        func append(_ a: Date, _ b: Date, _ kind: Kind, _ event: HistoryEvent? = nil,
                    websiteAllowed: Bool = true, contextKey: String? = nil, reason: GoalongCoverageReason? = nil) {
            guard b > a else { return }
            let active = kind.isActive
            if active, let event, let evidence = ForegroundActivityEvidence.evidence(in: event) {
                passive.append(.init(start: a, end: b, evidence: evidence))
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
        // A genuinely failed or unstable source still must not publish plausible totals.
        if incomplete {
            append(start, end, .unobserved, reason: .unreadable)
            return Day(date: start, end: end, state: .incomplete, segments: segments, eventCount: rows.count, classifierVersions: [], dayReason: .unreadable)
        }
        guard let first = rows.first, let last = rows.last else {
            append(start, end, .unobserved, reason: .notRecorded)
            return Day(date: start, end: end, state: .noSource, segments: segments, eventCount: 0, classifierVersions: [], dayReason: .notRecorded)
        }
        append(start, first.timestamp, .unobserved, reason: .beforeFirstObservation)
        for (offset, (previous, next)) in zip(rows, rows.dropFirst()).enumerated() {
            // Goalong never labels an application as work: active time stays to classify
            // until the user's own definition is applied to its context.
            let contextKey = contextKeys[offset]
            let gap = next.timestamp.timeIntervalSince(previous.timestamp)
            guard gap > 0 else { continue }
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
                continue
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
        // A last foreground sample is not evidence that activity continued after that sample.
        let tailReason: GoalongCoverageReason = last.suppressionReason != nil || [.recorderStopped, .recordingPaused,
            .systemSleep, .sessionLocked, .secureInputSuppressed, .historyCleared].contains(last.kind)
            ? .opening(last) : .afterLastObservation
        append(last.timestamp, end, .unobserved, reason: tailReason)
        return Day(date: start, end: end, state: .ready, segments: segments, eventCount: rows.count,
                   classifierVersions: [GoalongLocalAnalytics.method], firstObservation: first.timestamp, lastObservation: last.timestamp,
                   recordedBreakdown: .build(segments: segments, events: rows, passive: passive, calendar: calendar))
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
