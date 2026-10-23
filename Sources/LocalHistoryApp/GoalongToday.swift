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

    /// `Calendar.isDateInToday`, against `now`.
    static func isToday(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: now)
    }
}
