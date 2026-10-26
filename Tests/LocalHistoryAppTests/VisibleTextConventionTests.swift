#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// Visible French text: no « (s) » shortcut, typographic apostrophes in shown errors, « 85 % » with a space,
/// French decimal comma. Source scans skip log, diagnostic and AI-prompt literals (listed below).
final class VisibleTextConventionTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func swiftFiles(_ subpath: String) throws -> [URL] {
        let base = root.appendingPathComponent(subpath)
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// English diagnostics and model prompts that mention « (s) » on purpose; none is shown to the user.
    private let nonVisibleParenthesisS: [String] = [
        "recent-memory load diagnostic(s)", "unreadable row(s)", "Semantic clear removed", "raw callback(s)",
        "event identifier(s)", "minute(s)\"", "additional visible message(s)", "additional imported message(s)",
        "additional \\(", "candidate(s)", "capture gap(s)", "semantic snapshot identifier(s)",
        "Adds the typed site(s)", "http(s)", "Coverage:", "(s)\" +",
    ]

    func testNoLazyParenthesisPluralInVisibleFrenchText() throws {
        var offenders: [String] = []
        for dir in ["Sources/LocalHistoryApp", "Features/AgentActivity/Sources"] {
            for file in try swiftFiles(dir) {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where line.contains("(s)") {
                    // A shown plural sits inside a string literal; code such as `isKnown(s)` does not.
                    guard line.range(of: #""[^"]*[a-zà-ÿ]\(s\)"#, options: .regularExpression) != nil else { continue }
                    if file.lastPathComponent == "ChatGPTRecapContext.swift" { continue }  // AI prompt text
                    if nonVisibleParenthesisS.contains(where: line.contains) { continue }
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    offenders.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Use FrenchCount instead of « (s) »")
    }

    func testShownErrorsUseTypographicApostrophes() throws {
        let files = [
            "Sources/LocalHistoryCore/GoalongContextualRhythm.swift",
            "Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift",
        ]
        let shown = try NSRegularExpression(pattern: #"(Failure\.invalid|CLIError\.unsafeSource)\("[^"]*\b[dlnsjcmtDLNSJCMT]'[A-Za-zÀ-ÿ][^"]*""#)
        var offenders: [String] = []
        for path in files {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where shown.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                offenders.append("\(path):\(i + 1)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testPercentagesKeepTheSpaceBeforeTheSign() {
        XCTAssertEqual(DashboardFormatters.percentage(1, 4), "25\u{00A0}%")
        XCTAssertEqual(DashboardFormatters.percentage(0, 0), "0\u{00A0}%")
        let spots = [
            "Sources/LocalHistoryApp/ComputerHistoryPage.swift",
            "Sources/LocalHistoryApp/DashboardComponents.swift",
        ]
        for path in spots {
            let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains(".rounded()))%\""), path)
        }
    }

    func testDistancesUseTheFrenchDecimalComma() {
        XCTAssertEqual(GoalongHealthImportSheet.kilometres(5_250), "5,25 km")
        XCTAssertEqual(GoalongHealthImportSheet.formatted(["value": 5_000.0, "unit": "m"]), "5,00 km")
    }

    func testBreakdownRowsAreFrench() throws {
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/UsageBreakdownProjection.swift"),
            encoding: .utf8)
        for english in ["Other or unidentified browsing", "Other web activity", "Other active time",
                        "Websites not assigned to a browser"] {
            XCTAssertFalse(text.contains(english), english)
        }
    }

    func testRemovedDeadOverviewViewStaysRemoved() throws {
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/OverviewPage.swift"), encoding: .utf8)
        XCTAssertFalse(text.contains("struct OverviewPage"))
        XCTAssertFalse(text.contains("struct TimelineStrip"))
    }
}
#endif
