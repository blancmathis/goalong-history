import Foundation

/// One civil Monday/ISO week definition shared by CLI validation, commitments and work limits.
public enum GoalongFocusCalendar {
    public static func civil(_ calendar: Calendar = .current) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        result.locale = Locale(identifier: "en_US_POSIX")
        result.firstWeekday = 2; result.minimumDaysInFirstWeek = 4
        return result
    }
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = civil(calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    /// Before R1-231 day keys followed the system calendar (Buddhist "2569-10-15", Japanese "0008-10-15").
    /// Returns the Gregorian key of the same day, or nil when `key` is not a legacy key (Gregorian keys give nil, so callers stay idempotent).
    /// Calendars whose current year is itself in 1900...2100 (Indian, Ethiopic) only match keys of the current or previous legacy year.
    public static func gregorianKey(fromLegacy key: String, calendar: Calendar, now: Date) -> String? {
        guard calendar.identifier != .gregorian else { return nil }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.count == 10, parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let currentYear = calendar.component(.year, from: now)
        if (1900...2100).contains(currentYear) { guard (currentYear - 1...currentYear).contains(year) else { return nil } }
        else if (1900...2100).contains(year) { return nil }
        let era = calendar.component(.era, from: now)
        for candidate in stride(from: era, through: max(0, era - 4), by: -1) {
            let wanted = DateComponents(era: candidate, year: year, month: month, day: day)
            guard let date = calendar.date(from: DateComponents(era: candidate, year: year, month: month, day: day, hour: 12)), date <= now.addingTimeInterval(86_400),
                  calendar.dateComponents([.era, .year, .month, .day], from: date) == wanted else { continue }
            let result = dayKey(date, calendar: calendar)
            return result == key ? nil : result
        }
        return nil
    }
    public static func dayInterval(_ key: String, calendar: Calendar = .current) -> DateInterval? {
        guard key.count == 10 else { return nil }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        // Noon exists even where midnight does not (America/Santiago, 2026-09-06); the day's start is the first instant of that day.
        let c = civil(calendar)
        guard let noon = c.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              dayKey(noon, calendar: calendar) == key else { return nil }
        let start = c.startOfDay(for: noon)
        guard let nextNoon = c.date(byAdding: .day, value: 1, to: noon) else { return nil }
        let end = c.startOfDay(for: nextNoon)
        return DateInterval(start: start, end: end)
    }
    public static func weekKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = civil(calendar).dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }
    public static func weekInterval(_ date: Date, calendar: Calendar = .current) -> DateInterval {
        civil(calendar).dateInterval(of: .weekOfYear, for: date)!
    }
    public static func weekInterval(_ key: String, calendar: Calendar = .current) -> DateInterval? {
        guard key.count == 8, key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789-W").contains($0) }),
              key.dropFirst(4).hasPrefix("-W"), let year = Int(key.prefix(4)), (1...9999).contains(year),
              let week = Int(key.suffix(2)), (1...53).contains(week) else { return nil }
        let c = civil(calendar)
        guard let start = c.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)),
              weekKey(start, calendar: c) == key, let end = c.date(byAdding: .day, value: 7, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }
}
