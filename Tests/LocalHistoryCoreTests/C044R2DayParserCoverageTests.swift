import Foundation
import XCTest

/// T-044 tour 2: a strict local `yyyy-MM-dd` DateFormatter returns nil on a day without midnight
/// (America/Santiago 2026-09-06). C1-01 moved day parsing to `GoalongDayParser`; no source file may
/// still parse a day key with such a formatter (GMT formatters have no DST and are allowed).
final class C044R2DayParserCoverageTests: XCTestCase {
    func testStrictLocalFormatterStillRejectsTheDay() {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Santiago")!
        XCTAssertNil(f.date(from: "2026-09-06"), "precondition: Foundation still rejects this day")
    }

    func testNoSourceParsesADayKeyWithAStrictLocalFormatter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let assign = try NSRegularExpression(pattern: #"\b(\w+)\.dateFormat = "yyyy-MM-dd""#)
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "GoalongDayParser.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let names = Set(assign.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            })
            for name in names where !text.contains("\(name).timeZone = TimeZone(secondsFromGMT: 0)") {
                for (n, line) in text.components(separatedBy: "\n").enumerated() where line.contains("\(name).date(from:") {
                    offenders.append("\(url.path.replacingOccurrences(of: root.path + "/", with: "")):\(n + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "day keys parsed without GoalongDayParser (skip a day without midnight)")
    }
}
