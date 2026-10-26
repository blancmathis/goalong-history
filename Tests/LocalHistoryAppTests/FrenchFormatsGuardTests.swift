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
    /// Source guard: forbidden patterns in UI code (comments and `en_US_POSIX` data formats are fine).
    func testUISourcesDoNotUseSystemLocaleFormatting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp")
        let forbidden = ["Locale.current", "\\.formatted\\(\\)", "\\.formatted\\(date:", "style: \\.time\\)", "style: \\.date\\)", "ByteCountFormatter\\(\\)\\s*\\n\\s*formatter\\.countStyle = \\.file\\n\\s*(?!formatter\\.locale)"]
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
