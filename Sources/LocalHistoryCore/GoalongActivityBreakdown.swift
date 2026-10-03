import Foundation

/// A partition of observed active seconds. These modes describe evidence, not attention.
public struct GoalongActivityBreakdown: Codable, Equatable, Sendable {
    /// Raw order is the precedence for a calendar minute.
    public enum Mode: Int, Codable, CaseIterable, Sendable {
        case reading, pointer, keyboard, display, media, call
    }
    public struct Hour: Codable, Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let secondsByMode: [Mode: TimeInterval]
        public var totalSeconds: TimeInterval { Mode.allCases.reduce(0) { $0 + seconds($1) } }
        public func seconds(_ mode: Mode) -> TimeInterval { secondsByMode[mode] ?? 0 }
    }
    public let hours: [Hour]
    public var secondsByMode: [Mode: TimeInterval] {
        hours.reduce(into: [:]) { result, hour in
            for mode in Mode.allCases { result[mode, default: 0] += hour.seconds(mode) }
        }
    }
    public func seconds(_ mode: Mode) -> TimeInterval { hours.reduce(0) { $0 + $1.seconds(mode) } }
    public var totalSeconds: TimeInterval { Mode.allCases.reduce(0) { $0 + seconds($1) } }
    public init(hours: [Hour] = []) { self.hours = hours }

    struct PassiveInterval {
        let start: Date, end: Date
        let evidence: ForegroundActivityEvidence
    }

    static func build(segments: [GoalongLocalAnalytics.Segment], events: [HistoryEvent],
                      passive: [PassiveInterval], calendar: Calendar) -> Self {
        // Calendar minute boundaries also behave correctly on 23/25-hour days.
        func minute(_ date: Date) -> Date { calendar.dateInterval(of: .minute, for: date)?.start ?? date }
        var modes: [Date: Mode] = [:]
        func add(_ date: Date, _ mode: Mode) {
            let key = minute(date)
            if (modes[key] ?? .reading).rawValue < mode.rawValue { modes[key] = mode }
        }
        for event in events where event.suppressionReason == nil && !event.isObservationContinuityBoundary {
            switch event.kind {
            case .keyPressed, .typingBurst, .keyboardShortcut: add(event.timestamp, .keyboard)
            case .mouseClick, .scrollBurst: add(event.timestamp, .pointer)
            default: break
            }
        }
        for interval in passive {
            let mode: Mode
            switch interval.evidence { case .call: mode = .call; case .mediaPlayback: mode = .media; case .displayAssertion: mode = .display }
            var cursor = minute(interval.start)
            while cursor < interval.end {
                add(cursor, mode)
                guard let next = calendar.dateInterval(of: .minute, for: cursor)?.end, next > cursor else { break }
                cursor = next
            }
        }
        var buckets: [Date: [Mode: TimeInterval]] = [:]
        for segment in segments where segment.kind.isActive {
            var cursor = segment.start
            while cursor < segment.end {
                guard let minuteEnd = calendar.dateInterval(of: .minute, for: cursor)?.end,
                      let hour = calendar.dateInterval(of: .hour, for: cursor), minuteEnd > cursor else { break }
                let stop = min(segment.end, minuteEnd, hour.end)
                let mode = modes[minute(cursor)] ?? .reading
                buckets[hour.start, default: [:]][mode, default: 0] += stop.timeIntervalSince(cursor)
                cursor = stop
            }
        }
        return Self(hours: buckets.keys.sorted().map {
            Hour(start: $0, end: calendar.dateInterval(of: .hour, for: $0)!.end, secondsByMode: buckets[$0]!)
        })
    }
}

extension GoalongLocalAnalytics.Day {
    public var breakdown: GoalongActivityBreakdown {
        recordedBreakdown ?? .build(segments: segments, events: [], passive: [], calendar: .current)
    }
}
extension GoalongLocalAnalytics.Period {
    public var breakdown: GoalongActivityBreakdown { .init(hours: days.flatMap { $0.breakdown.hours }) }
}
