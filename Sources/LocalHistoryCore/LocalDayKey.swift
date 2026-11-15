import Foundation

/// The `yyyy-MM-dd` day key used in file names and archives. It is always Gregorian with the POSIX
/// locale, whatever calendar the system uses (Buddhist, Japanese…): files written and read with
/// different calendars would never match.
public enum LocalDayKey {
    public static func gregorianCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = gregorianCalendar(timeZone: timeZone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The local day named by the first ten characters of `fileName` (`2026-11-15.jsonl`), or nil.
    public static func interval(fromFileName fileName: String, timeZone: TimeZone = .current) -> DateInterval? {
        guard fileName.utf8.count >= 10 else { return nil }
        let pieces = String(fileName.prefix(10)).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
            let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return nil }
        let calendar = gregorianCalendar(timeZone: timeZone)
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: start)
        guard verified.year == year, verified.month == month, verified.day == day,
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
}
