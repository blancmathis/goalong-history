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
    /// « 14:05 » — 24-hour clock whatever the system region.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
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
