import Foundation

/// Parses a `yyyy-MM-dd` day key into the first instant of that day in a time zone.
/// A strict `DateFormatter` returns nil for a day without midnight (America/Santiago, 2026-09-06),
/// so the day is built at noon, which always exists, then moved to its start.
/// The zone is read at call time (`NSTimeZone.default`, as `DateFormatter` does), never frozen in a static.
public enum GoalongDayParser {
    public static func date(_ key: String, timeZone: TimeZone = NSTimeZone.default) -> Date? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-",
              scalars.enumerated().allSatisfy({ [4, 7].contains($0.offset) || ("0"..."9").contains($0.element) }),
              let year = Int(key.prefix(4)), let month = Int(key.dropFirst(5).prefix(2)), let day = Int(key.suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              calendar.dateComponents([.year, .month, .day], from: noon) == DateComponents(year: year, month: month, day: day) else { return nil }
        return calendar.startOfDay(for: noon)
    }
}
