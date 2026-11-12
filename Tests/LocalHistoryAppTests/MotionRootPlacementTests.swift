#if os(macOS)
import XCTest

/// T-054: a sheet, popover or panel is a hosting view of its own: a transaction does not reach it. Each root in
/// Blocages / Blocking / Braise / Concentration (and the window's toast layer) must carry `goalongControls()` or
/// `goalongMotion()`, or « Animations » off would leave it moving. Reads the sources.
final class MotionRootPlacementTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LocalHistoryApp")

    private func swiftFiles(_ folder: String) throws -> [URL] {
        let dir = Self.sources.appendingPathComponent(folder)
        let found = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(found.isEmpty, "no sources in \(dir.path)")
        return found
    }

    /// The text between the matching delimiters that open at `start`, or nil.
    private func balanced(_ chars: [Character], from start: Int, open: Character, close: Character) -> (body: String, end: Int)? {
        guard start < chars.count, chars[start] == open else { return nil }
        var depth = 0, i = start
        while i < chars.count {
            if chars[i] == open { depth += 1 } else if chars[i] == close {
                depth -= 1
                if depth == 0 { return (String(chars[(start + 1)..<i]), i) }
            }
            i += 1
        }
        return nil
    }

    func testEverySheetAndPopoverRootCarriesTheMotionModifier() throws {
        var checked = 0
        for folder in ["Blocages", "Blocking", "Braise", "Concentration"] {
            for file in try swiftFiles(folder) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let chars = Array(text)
                for marker in [".sheet(", ".popover("] {
                    var from = text.startIndex
                    while let range = text.range(of: marker, range: from..<text.endIndex) {
                        from = range.upperBound
                        let open = text.distance(from: text.startIndex, to: range.upperBound) - 1
                        guard let args = balanced(chars, from: open, open: "(", close: ")") else { continue }
                        var next = args.end + 1
                        while next < chars.count, chars[next].isWhitespace { next += 1 }
                        guard let body = balanced(chars, from: next, open: "{", close: "}") else { continue }
                        checked += 1
                        let line = text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                        XCTAssertTrue(body.body.contains("goalongControls()") || body.body.contains("goalongMotion()"),
                                      "\(file.lastPathComponent):\(line) \(marker) root lacks goalongControls()/goalongMotion()")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 25, "the scan found too few sheets and popovers: did the sources move?")
    }

    func testOwnHostingViewsCarryTheMotionModifier() throws {
        let expected: [(file: String, needle: String)] = [
            ("Blocking/BlockingTimerHUD.swift", "NSHostingView(rootView: AnyView(view.goalongMotion()))"),
            ("Blocking/BlockingEnforcement.swift", ".goalongControls())"),
            ("Concentration/ConcentrationPanelViews.swift", ".goalongControls()"),
            ("DashboardKeptPages.swift", "GoalongToastHost().environment(\\.locale, GoalongUIFormat.locale).goalongMotion()"),
            ("JevWarningPanel.swift", ".goalongMotion()"),
        ]
        for item in expected {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(item.file), encoding: .utf8)
            XCTAssertTrue(text.contains(item.needle), "\(item.file): own hosting view lacks the motion modifier")
        }
    }
}
#endif
