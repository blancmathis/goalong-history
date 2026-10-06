import Foundation

public enum FilterMode: String, Codable, CaseIterable, Identifiable {
    case auto, on, off
    public var id: String { rawValue }
    public var label: String { switch self { case .auto: return "Auto"; case .on: return "Activé"; case .off: return "Désactivé" } }
}

/// Weekdays use Foundation's numbering (Sunday = 1). A selected day is the
/// START day, including when its time range continues into the following day.
public struct ScheduleRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int
    public init(id: UUID = UUID(), enabled: Bool = true, weekdays: Set<Int> = Set(1...7), startMinute: Int = 22*60, endMinute: Int = 8*60) {
        self.id = id; self.enabled = enabled
        self.weekdays = weekdays.intersection(Set(1...7))
        self.startMinute = max(0, min(1439, startMinute))
        self.endMinute = max(0, min(1439, endMinute))
    }
    public var crossesMidnight: Bool { endMinute < startMinute }
    public var isValid: Bool { !weekdays.isEmpty && startMinute != endMinute && (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute) }
    public static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    public var hours: String { "\(Self.clock(startMinute)) – \(Self.clock(endMinute))" }
    public var dayLabel: String {
        if weekdays == Set(1...7) { return "Tous les jours" }
        if weekdays == Set(2...6) { return "Du lundi au vendredi" }
        if weekdays == Set([1,7]) { return "Le week-end" }
        let names = [2:"Lun",3:"Mar",4:"Mer",5:"Jeu",6:"Ven",7:"Sam",1:"Dim"]
        return [2,3,4,5,6,7,1].filter { weekdays.contains($0) }.compactMap { names[$0] }.joined(separator: " · ")
    }
    public func interval(startingOn day: Date, calendar: Calendar) -> DateInterval? {
        guard enabled, isValid, weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        let midnight = calendar.startOfDay(for: day)
        // Use wall-clock hours (not seconds since midnight) to handle DST.
        guard let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: midnight, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
              let endDay = calendar.date(byAdding: .day, value: crossesMidnight ? 1 : 0, to: midnight),
              let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: endDay, matchingPolicy: .nextTime, repeatedTimePolicy: .last, direction: .forward), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: date)
        for offset in [-1,0] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), let interval = interval(startingOn: day, calendar: calendar) else { continue }
            if date >= interval.start && date < interval.end { return true }
        }
        return false
    }
}

public struct ScheduleEngine {
    public static func isActive(_ rules: [ScheduleRule], at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        rules.contains { $0.contains(date, calendar: calendar) }
    }
    /// Only returns boundaries that change the UNION of all enabled ranges.
    /// Adjacent or overlapping rules must not produce a flash of normal color.
    public static func nextTransition(_ rules: [ScheduleRule], after now: Date = Date(), calendar: Calendar = .current) -> (date: Date, active: Bool)? {
        let midnight = calendar.startOfDay(for: now)
        var boundaries: Set<Date> = []
        for offset in -1...9 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: midnight) else { continue }
            for rule in rules {
                guard let interval = rule.interval(startingOn: day, calendar: calendar) else { continue }
                if interval.start > now { boundaries.insert(interval.start) }
                if interval.end > now { boundaries.insert(interval.end) }
            }
        }
        for boundary in boundaries.sorted() {
            let before = isActive(rules, at: boundary.addingTimeInterval(-0.1), calendar: calendar)
            let after = isActive(rules, at: boundary, calendar: calendar)
            if before != after { return (boundary, after) }
        }
        return nil
    }
}

public struct Preferences: Codable, Equatable {
    public var version: Int = 1
    public var mode: FilterMode = .off
    public var intensity: Double = 1
    public var brightness: Double = 1
    public var rules: [ScheduleRule] = [ScheduleRule()]
    public var pauseUntil: Date? = nil
    public init() {}
    public mutating func sanitize() {
        intensity = intensity.isFinite ? max(0, min(1, intensity)) : 1
        brightness = brightness.isFinite ? max(0.2, min(1, brightness)) : 1
        rules = Array(rules.prefix(32)).map { rule in
            ScheduleRule(id: rule.id, enabled: rule.enabled, weekdays: rule.weekdays, startMinute: rule.startMinute, endMinute: rule.endMinute)
        }
    }
}

public struct ChannelGains: Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(intensity: Double, brightness: Double) {
        let x = max(0, min(1, intensity)), light = max(0.2, min(1, brightness))
        red = light
        green = pow(1-x, 1.5) * light
        blue = pow(1-x, 3) * light
    }
}
