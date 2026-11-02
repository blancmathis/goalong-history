#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-043 lot R4e: `kind:` required, quota gauge words, « séance » wording.
final class T043R4eTests: XCTestCase {
    // Décision 24: the gauge says « <n> min restantes sur <total> », shown and read alike.
    func testQuotaGaugeSaysMinutesLeftOfTotal() {
        XCTAssertEqual(BlockingFormat.quotaLeft(seconds: 24 * 60, totalMinutes: 60), "24 min restantes sur 60 min")
        XCTAssertEqual(BlockingFormat.quotaLeft(seconds: 61, totalMinutes: 30), "2 min restantes sur 30 min", "rounded up")
        XCTAssertEqual(BlockingFormat.quotaLeft(seconds: 40, totalMinutes: 30), "1 min restante sur 30 min", "singular")
    }

    // R4d-7: the glyph of a pill comes from its kind unless the state has its own; every kind has its own glyph.
    func testPillTakesItsGlyphFromItsKind() {
        let kinds: [GoalongStateKind] = [.notYet, .needsPermission, .unavailable, .empty, .ready, .attention]
        XCTAssertEqual(Set(kinds.map(\.symbol)).count, kinds.count, "one glyph per kind")
        for kind in kinds { XCTAssertEqual(StatusPill(title: "x", kind: kind).symbol, kind.symbol) }
        XCTAssertEqual(StatusPill(title: "x", kind: .ready, symbol: "bolt").symbol, "bolt", "an own glyph wins")
        XCTAssertEqual(GoalongSourceRow.State.needsPermission.kind, .needsPermission)
        XCTAssertEqual(GoalongSourceRow.State.failed.kind, .unavailable)
        XCTAssertEqual(GoalongSourceRow.State.partial.kind, .attention)
    }

    // R-289 5: the CLI never names the source « historique de ce Mac » (glossary).
    func testNoSourceNameInThisFileSet() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("historique de ce Mac"))
    }

    // R4d-11: the focus threshold speaks of « séances ».
    func testFocusExplanationSaysSeance() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp/GoalongActivityFocusChart.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("séquence minimale"))
        XCTAssertFalse(text.contains("Séquence minimale"))
    }
}
#endif
