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
        public init(start: Date, end: Date, secondsByMode: [Mode: TimeInterval]) {
            self.start = start; self.end = end; self.secondsByMode = secondsByMode
        }
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

    /// The strongest evidence of each calendar minute. Folded row by row, a day keeps at
    /// most one entry per minute instead of its rows.
    struct MinuteModes: Codable {
        private(set) var modes: [Date: Mode] = [:]

        mutating func add(_ event: HistoryEvent, calendar: Calendar) {
            guard event.suppressionReason == nil, !event.isObservationContinuityBoundary else { return }
            switch event.kind {
            case .keyPressed, .typingBurst, .keyboardShortcut: add(event.timestamp, .keyboard, calendar)
            case .mouseClick, .scrollBurst: add(event.timestamp, .pointer, calendar)
            default: break
            }
        }

        mutating func add(_ evidence: ForegroundActivityEvidence, from start: Date, to end: Date, calendar: Calendar) {
            let mode: Mode
            switch evidence { case .call: mode = .call; case .mediaPlayback: mode = .media; case .displayAssertion: mode = .display }
            var cursor = Self.minute(start, calendar)
            while cursor < end {
                add(cursor, mode, calendar)
                guard let next = calendar.dateInterval(of: .minute, for: cursor)?.end, next > cursor else { break }
                cursor = next
            }
        }

        func mode(at date: Date, calendar: Calendar) -> Mode { modes[Self.minute(date, calendar)] ?? .reading }

        private mutating func add(_ date: Date, _ mode: Mode, _ calendar: Calendar) {
            let key = Self.minute(date, calendar)
            if (modes[key] ?? .reading).rawValue < mode.rawValue { modes[key] = mode }
        }

        // Calendar minute boundaries also behave correctly on 23/25-hour days.
        private static func minute(_ date: Date, _ calendar: Calendar) -> Date {
            calendar.dateInterval(of: .minute, for: date)?.start ?? date
        }
    }

    static func build(segments: [GoalongLocalAnalytics.Segment], modes: MinuteModes, calendar: Calendar) -> Self {
        var buckets: [Date: [Mode: TimeInterval]] = [:]
        for segment in segments where segment.kind.isActive {
            var cursor = segment.start
            while cursor < segment.end {
                guard let minuteEnd = calendar.dateInterval(of: .minute, for: cursor)?.end,
                      let hour = calendar.dateInterval(of: .hour, for: cursor), minuteEnd > cursor else { break }
                let stop = min(segment.end, minuteEnd, hour.end)
                let mode = modes.mode(at: cursor, calendar: calendar)
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
        recordedBreakdown ?? .build(segments: segments, modes: .init(), calendar: .current)
    }
}
extension GoalongLocalAnalytics.Period {
    public var breakdown: GoalongActivityBreakdown { .init(hours: days.flatMap { $0.breakdown.hours }) }
}
