import XCTest
@testable import LocalHistoryApp

/// T-052 lot 4: « Nouvelle règle » in the Blocages header with ⌘N, a styled « Abandonner », a named action for the
/// prepared session row. Source checks: the views need no window (no test shows a window).
final class Lot4HeaderAndDiscardTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp")
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }

    func testNewRuleSitsInTheHeaderWithCommandNAndOnlyOpensTheEditor() throws {
        let page = try source("Blocages/BlocagesPage.swift")
        XCTAssertEqual(page.components(separatedBy: "\"blocages-new-rule\"").count - 1, 1, "one button")
        XCTAssertEqual(page.components(separatedBy: "keyboardShortcut(\"n\", modifiers: .command)").count - 1, 1)
        let header = try XCTUnwrap(page.range(of: "private var header: some View"))
        let rules = try XCTUnwrap(page.range(of: "private func rules(now: Date)"))
        let button = try XCTUnwrap(page.range(of: "blocages-new-rule"))
        XCTAssertTrue(button.lowerBound > header.lowerBound && button.lowerBound < rules.lowerBound, "in the header")
        XCTAssertTrue(page.contains("Button { editing = .new }"), "opens the editor, writes nothing")
    }

    func testDiscardIsStyledAndStillConfirmsAboveOneChange() throws {
        let root = try source("DashboardRootView.swift")
        XCTAssertTrue(root.contains("\"pending-discard\""))
        XCTAssertTrue(root.contains("discardNeedsConfirmation"))
    }

    func testPreparedSessionRowHasAKeyboardAndVoiceOverEquivalentOfTheDoubleClick() throws {
        let row = try source("Blocages/PreparedSession.swift")
        XCTAssertTrue(row.contains(".accessibilityAction(named: \"Modifier la séance\")"))
        XCTAssertTrue(row.contains("Button(\"Modifier…\") { onOpen(session) }"), "the button stays reachable by keyboard")
    }
}
