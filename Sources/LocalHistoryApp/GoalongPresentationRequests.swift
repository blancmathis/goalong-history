#if os(macOS)
import Foundation
import LocalHistoryCore

/// Capture navigation arguments together with presentation identity. A separate
/// Boolean and payload can otherwise present stale values on the first click.
struct GoalongWebsitePresentation: Identifiable {
    let id = UUID()
    let day: Date?
}
struct GoalongAnalysisPresentation: Identifiable {
    let id = UUID()
    let tab: Int
}
enum GoalongUIFormat {
    /// The interface is French-only; never follow an English system region for its text.
    static let locale = Locale(identifier: "fr_FR")
    /// « 12,4 Mo », « 0 octet » — French units whatever the system region.
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
    }
    /// « 26 octobre 2026 » for a stored day key « 2026-10-26 »; an unreadable key is shown as is.
    static func day(key: String) -> String { GoalongDayParser.date(key, timeZone: .current).map(day) ?? key }
    /// « 1 234 » — French grouping whatever the system region.
    static func number<T: BinaryInteger>(_ value: T) -> String {
        Int(value).formatted(.number.locale(locale))
    }
    /// « 1,5 » — French decimal comma, at most one decimal.
    static func number(_ value: Double) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...1)))
    }
    /// Pins the 12/24 h choice (tests, gallery). nil = the user's macOS choice.
    nonisolated(unsafe) static var twelveHourOverride: Bool?
    /// French text is 24 h unless the user chose the 12 h clock in macOS (Réglages › Général › Date et heure).
    static var usesTwelveHourClock: Bool {
        // The user's locale carries the macOS 12/24 h choice; no UserDefaults read (the gallery forbids them).
        // Tests and the gallery stay 24 h whatever the machine's region, so renders do not depend on it.
        if let twelveHourOverride { return twelveHourOverride }
        if NSClassFromString("XCTestCase") != nil { return false }
        if let systemTwelveHour { return systemTwelveHour }
        let value = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? "").contains("a")
        systemTwelveHour = value
        // Read once per region change, not once per displayed hour (lists, chart axes).
        if localeObserver == nil { localeObserver = observeLocaleChange() }
        return value
    }
    /// Clears the cached 12/24 h choice on the main queue, where the cache is read: a `nil` queue would run the
    /// closure on whatever thread posts the notification, racing the readers of `nonisolated(unsafe)` state.
    static func observeLocaleChange(center: NotificationCenter = .default, didClear: (() -> Void)? = nil) -> NSObjectProtocol {
        center.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { _ in
            systemTwelveHour = nil
            didClear?()
        }
    }
    nonisolated(unsafe) private static var systemTwelveHour: Bool?
    nonisolated(unsafe) private static var localeObserver: NSObjectProtocol?
    /// « 14:05 » — the system short time: 24 h, or « 2:05 PM » when the user chose 12 h. Every displayed hour with minutes uses it.
    static func time(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return time(minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
    /// Same style as `time(_:)` for a minute of the day (0…1439; 1440 reads « 24:00 » in 24 h).
    static func time(minuteOfDay minute: Int) -> String {
        let value = minute == 1_440 ? 1_440 : ((minute % 1_440) + 1_440) % 1_440
        let hour = value / 60, rest = value % 60
        guard usesTwelveHourClock else { return String(format: "%02d:%02d", hour, rest) }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, rest, hour % 24 < 12 ? "AM" : "PM")
    }
    /// « 8 h », « 16 h » — a whole hour alone (axes, hour ranges), never « 08 h ».
    static func hour(_ date: Date) -> String {
        hour(Calendar.current.component(.hour, from: date))
    }
    static func hour(_ value: Int) -> String { "\(value) h" }
    /// « 1 h 05 », « 25 min », « moins d’une minute » — a timer's length, minutes rounded up (decision 15).
    static func timerLength(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "moins d’une minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d", minutes / 60, minutes % 60)
    }
    /// « 12 min restantes », « moins d’une minute restante » — never a bare number.
    static func remaining(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "moins d’une minute restante" : "\(timerLength(seconds)) restantes"
    }
    /// « depuis 25 min ».
    static func elapsed(_ seconds: TimeInterval) -> String { "depuis \(timerLength(max(60, seconds)))" }
    /// « 1 fichier », « 2 fichiers », « 0 fichier » — French plural (zero and one are singular). Pass `plural` for irregular nouns.
    static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        "\(number(value)) " + (abs(value) > 1 ? (plural ?? singular + "s") : singular)
    }
    /// « 50 % » — French percent: a no-break space (U+00A0) before the sign, never a plain space.
    static func percent(_ value: Int) -> String { "\(value)\u{00A0}%" }
    static func percent(_ value: Double) -> String { percent(Int(value.rounded())) }
    /// « 26 oct. 2026 ».
    static func dayAbbreviated(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }
}

#endif
