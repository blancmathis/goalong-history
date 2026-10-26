#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// The interface is French-only: no UI formatter may follow an English system region (« 10.63 Go », « 2:39 AM »).
final class FrenchFormatsGuardTests: XCTestCase {
    func testStorageSizeUsesFrenchDecimalComma() {
        let text = StorageHealth.formatted(10_630_000_000)
        XCTAssertTrue(text.contains("10,63"), text)
        XCTAssertFalse(text.contains("10.63"), text)
    }
    func testNumbersAndTimesIgnoreSystemRegion() {
        XCTAssertEqual(GoalongUIFormat.number(1_234), "1\u{202F}234")
        XCTAssertEqual(GoalongUIFormat.number(1.5), "1,5")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 14, minute: 5))!
        XCTAssertEqual(GoalongUIFormat.time(date), "14:05")
    }
    /// One clock everywhere: « 06:53 », never « 6:53 » (T-044 B3-01).
    func testBlockingTimesUseTwoDigitHours() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 6, minute: 53))!
        XCTAssertEqual(BlockingFormat.time(morning), "06:53")
        XCTAssertEqual(BlockingFormat.endTime(calendar.startOfDay(for: morning)), "minuit")
        XCTAssertEqual(BlockingFormat.minuteOfDay(6 * 60 + 53), "06:53")
    }
    /// The stake « jusqu’à » chips use the same clock (T-044 C4-04): « 09:30 », never « 9:30 ».
    func testCommitmentStakeTimesUseTwoDigitHours() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let nine = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9, minute: 30))!
        XCTAssertEqual(FocusCommitmentFormat.clock("09:30"), BlockingFormat.time(nine))
        XCTAssertEqual(FocusCommitmentFormat.until("08:00"), "jusqu’à 08:00")
        XCTAssertEqual(FocusCommitmentFormat.until("23:59"), "toute la journée")
    }
    /// Stored day keys read as French days (T-044 C3-04); an unreadable key is never hidden.
    func testDayKeysShowAsFrenchDays() {
        XCTAssertEqual(GoalongUIFormat.day(key: "2026-10-26"), "26 octobre 2026")
        XCTAssertEqual(GoalongUIFormat.day(key: "2026-03-01"), "1 mars 2026")
        XCTAssertEqual(GoalongUIFormat.day(key: "bad"), "bad")
    }
    /// Source guard: forbidden patterns in UI code (comments and `en_US_POSIX` data formats are fine).
    func testUISourcesDoNotUseSystemLocaleFormatting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp")
        let forbidden = ["Locale.current", "\\.formatted\\(\\)", "\\.formatted\\(date:", "style: \\.time\\)", "style: \\.date\\)", "ByteCountFormatter\\(\\)\\s*\\n\\s*formatter\\.countStyle = \\.file\\n\\s*(?!formatter\\.locale)",
                         // « Repère ajouté à 2:39 AM » (T-044 C3-03): the system-region shorthand.
                         "DateFormatter\\.localizedString\\(",
                         // A stored day key in French text, « Aperçu local du 2026-10-26 » (T-044 C3-04): use GoalongUIFormat.day(key:).
                         // A display time as « 6:53 » (T-044 B3-01), or an ad-hoc « HH:mm » formatter: use GoalongUIFormat.time.
                         "dateFormat = \"[HhKk]:mm", "dateFormat = \"HH:mm\"", "String\\(format: \"%d:%02d\", value / 60",
                         // A stored « 09:30 » cut to « 9:30 » (T-044 C4-04).
                         "hasPrefix\\(\"0\"\\)", "trimmingPrefix\\(\"0\"\\)", "drop\\(while: \\{ \\$0 == \"0\" \\}\\)",
                         "(du|reçue :) \\\\\\((\\w+\\.)*day\\)", "\"\\\\\\((\\w+\\.)*day\\) · "]
        let regexes = try forbidden.map { try NSRegularExpression(pattern: $0) }
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let s = String(line)
                for r in regexes where r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    // `.formatted()` on a non-number (e.g. a Date style) is the risk; allow GoalongUIFormat's own helpers.
                    if file.lastPathComponent == "GoalongPresentationRequests.swift" { continue }
                    // Language of the generated recap text follows the system language on purpose (not a UI format).
                    if s.contains("languageCode?.identifier") { continue }
                    hits.append("\(file.lastPathComponent): \(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(hits, [])
    }
}
#endif
