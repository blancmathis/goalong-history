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
    public static func dayInterval(_ key: String, calendar: Calendar = .current) -> DateInterval? {
        guard key.count == 10 else { return nil }
        let f = DateFormatter(); f.calendar = civil(calendar); f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let start = f.date(from: key), f.string(from: start) == key,
              let end = civil(calendar).date(byAdding: .day, value: 1, to: start) else { return nil }
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
