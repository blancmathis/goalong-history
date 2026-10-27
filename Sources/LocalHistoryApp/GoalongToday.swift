import Foundation

/// The views' "today": the real clock in the app; the test gallery freezes it to its own day, so a page that says
/// « Aujourd’hui » renders the same image on any date (spec C §5.1).
enum GoalongToday {
    #if DEBUG
    /// Test gallery only: the frozen clock. Nil reads the real clock.
    nonisolated(unsafe) static var galleryClock: (() -> Date)?
    #endif

    static var now: Date {
        #if DEBUG
        if let galleryClock { return galleryClock() }
        #endif
        return Date()
    }

    /// A `TimelineView` tick: the frozen clock in the gallery, the tick itself in the app.
    static func timeline(_ date: Date) -> Date {
        #if DEBUG
        if let galleryClock { return galleryClock() }
        #endif
        return date
    }

    /// `Calendar.isDateInToday`, against `now`.
    static func isToday(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: now)
    }
}

/// A calendar date (year, month, day), not an instant. A day chosen on a page keeps its date after a time zone
/// change: « 25 octobre 00:00 Paris » is 24 October in New York, but the key stays 25 October.
struct GoalongCalendarDay: Hashable {
    let year: Int
    let month: Int
    let day: Int

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    /// Midnight of this date in `calendar`.
    func start(calendar: Calendar = .current) -> Date {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
        return calendar.startOfDay(for: date)
    }
}
