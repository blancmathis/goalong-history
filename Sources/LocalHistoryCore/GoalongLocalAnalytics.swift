import Foundation

/// A read-only projection of foreground observations, not a productivity or attention score.
/// Every elapsed second belongs to one state; missing evidence is never inferred as rest.
public enum GoalongLocalAnalytics {
    public static let method = "local-observed-rhythm-v2"
    public static let maximumGap: TimeInterval = 120
    public static let idleThreshold = ForegroundActivityEvidence.inputIdleThreshold

    public enum Kind: String, CaseIterable, Codable, Sendable {
        case work, other, unclassified, idle, concealed, unobserved
        public var isActive: Bool { self == .work || self == .other || self == .unclassified }
    }
    public enum State: String, Sendable { case ready, noSource, incomplete }
    public struct Segment: Identifiable, Equatable, Sendable {
        public let start: Date
        public var end: Date
        public let kind: Kind
        public let application: String?
        public let bundleIdentifier: String?
        public let host: String?
        public var id: Date { start }
        public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
        public var context: String? {
            guard let application else { return nil }
            return (bundleIdentifier ?? application) + "|" + (host ?? "")
        }
    }
    public struct Focus: Identifiable, Equatable, Sendable {
        public let start: Date
        public var end: Date
        public let application: String
        public let host: String?
        public let context: String
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
        public var id: Date { start }
    }
    public struct Day: Identifiable, Equatable, Sendable {
        public let date: Date
        public let end: Date
        public let state: State
        public let segments: [Segment]
        public let eventCount: Int
        public let classifierVersions: Set<String>
        public var id: Date { date }
        public var activeSeconds: TimeInterval { seconds(.work) + seconds(.other) + seconds(.unclassified) }
        public var observedSeconds: TimeInterval { segments.filter { $0.kind != .unobserved }.reduce(0) { $0 + $1.seconds } }
        public func seconds(_ kind: Kind) -> TimeInterval { segments.filter { $0.kind == kind }.reduce(0) { $0 + $1.seconds } }
        public var contextChanges: Int {
            zip(segments, segments.dropFirst()).filter { a, b in
                a.kind.isActive && b.kind.isActive && a.end == b.start && a.context != b.context
            }.count
        }
        /// Same application + domain, across class changes but never across a gap or idle state.
        public var sequences: [Focus] {
            var result: [Focus] = []
            for segment in segments where segment.kind.isActive {
                guard let application = segment.application, let context = segment.context else { continue }
                if let last = result.last, last.end == segment.start, last.context == context {
                    result[result.count - 1].end = segment.end
                } else {
                    result.append(Focus(start: segment.start, end: segment.end, application: application,
                        host: segment.host, context: context))
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
                let active = segments.filter { $0.kind.isActive }.reduce(0.0) {
                    $0 + Self.overlap($1.start, $1.end, cursor, stop)
                }
                let focus = blocks.reduce(0.0) { $0 + Self.overlap($1.start, $1.end, cursor, stop) }
                result.append(Hour(start: cursor, end: stop, seconds: active, focusSeconds: focus))
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
        // Buffered typing/scroll bursts can be appended after newer foreground samples.
        // Journal append order is not observation time order. Sort only this read-only
        // projection, preserving journal order for ties (timestamps can be second-precision).
        let rows = events.enumerated()
            .filter { $0.element.timestamp >= start && $0.element.timestamp <= end && $0.element.isDerivedAnalysisEvidence }
            .sorted { a, b in
                a.element.timestamp == b.element.timestamp
                    ? a.offset < b.offset : a.element.timestamp < b.element.timestamp
            }.map(\.element)
        var segments: [Segment] = []
        func append(_ a: Date, _ b: Date, _ kind: Kind, _ event: HistoryEvent? = nil) {
            guard b > a else { return }
            let active = kind.isActive
            let application = active ? event?.app?.name : nil
            let bundle = active ? event?.app?.bundleIdentifier : nil
            let host = active && event.map(ForegroundActivityEvidence.supportsWebsiteAttribution) == true
                ? event?.url?.host : nil
            if let last = segments.last, last.end == a, last.kind == kind,
               last.application == application, last.bundleIdentifier == bundle, last.host == host {
                segments[segments.count - 1].end = b
            } else {
                segments.append(Segment(start: a, end: b, kind: kind, application: application,
                    bundleIdentifier: bundle, host: host))
            }
        }
        // A genuinely failed or unstable source still must not publish plausible totals.
        if incomplete {
            append(start, end, .unobserved)
            return Day(date: start, end: end, state: .incomplete, segments: segments, eventCount: rows.count, classifierVersions: [])
        }
        guard let first = rows.first, let last = rows.last else {
            append(start, end, .unobserved)
            return Day(date: start, end: end, state: .noSource, segments: segments, eventCount: 0, classifierVersions: [])
        }
        append(start, first.timestamp, .unobserved)
        var versions = Set<String>()
        for (previous, next) in zip(rows, rows.dropFirst()) {
            let gap = next.timestamp.timeIntervalSince(previous.timestamp)
            guard gap > 0 else { continue }
            let kind: Kind
            if gap > maximumGap || next.metadata?["observation_gap"] == "true" {
                kind = .unobserved
            } else if let reason = previous.suppressionReason {
                switch reason {
                case .privateBrowserWindow, .excludedApplication, .excludedDomain, .secureInput, .manualPause:
                    kind = .concealed
                case .sessionUnavailable, .accessibilityUnavailable:
                    kind = .unobserved
                }
            } else if previous.isObservationContinuityBoundary || previous.app?.name.isEmpty != false {
                kind = .unobserved
            } else if ForegroundActivityEvidence.isInputIdle(previous)
                || (ForegroundActivityEvidence.isInputIdle(next)
                    && ForegroundActivityEvidence.evidence(in: previous) == nil) {
                // A later idle sample/app switch must not erase an observed call
                // preceding it; equally, a later call must not revive earlier idle.
                kind = .idle
            } else if previous.url?.host != nil,
                      !ForegroundActivityEvidence.supportsWebsiteAttribution(previous) {
                // A browser-process wake assertion cannot classify the content
                // of an unproven tab as productive or unproductive.
                kind = .unclassified
            } else if let classification = previous.classification, classification.confidence >= 0.5 {
                kind = classification.isWork.map { $0 ? .work : .other } ?? .unclassified
            } else {
                kind = .unclassified
            }
            if kind.isActive, let version = previous.classification?.classifierVersion { versions.insert(version) }
            append(previous.timestamp, next.timestamp, kind, previous)
        }
        // A last foreground sample is not evidence that activity continued after that sample.
        append(last.timestamp, end, .unobserved)
        return Day(date: start, end: end, state: .ready, segments: segments, eventCount: rows.count, classifierVersions: versions)
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
