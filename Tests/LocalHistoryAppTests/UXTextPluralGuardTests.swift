#if os(macOS)
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// UX10 text fixes: counts agree in number through `FrenchCount`, never a fixed plural.
@MainActor final class UXTextPluralGuardTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Sources/" + path), encoding: .utf8)
    }

    func testCountsUseTheSharedPluralHelperInsteadOfAFixedPlural() throws {
        let slowDown = try source("LocalHistoryApp/Blocking/SlowDownViews.swift")
        XCTAssertTrue(slowDown.contains("FrenchCount.count(seconds(at: date), \"seconde\", \"secondes\")"))
        XCTAssertFalse(slowDown.contains("encore \\(seconds(at: date)) secondes"))
        let content = try source("LocalHistoryApp/GoalongActivityContent.swift")
        XCTAssertTrue(content.contains("FrenchCount.count(summary.contextChanges, \"changement\", \"changements\")"))
        XCTAssertFalse(content.contains("\\(summary.contextChanges) changements"))
        let blocking = try source("LocalHistoryApp/Blocking/BlockingPage.swift")
        XCTAssertTrue(blocking.contains("\"pause restante\", \"pauses restantes\""))
        let evidence = try source("LocalHistoryQueryCLI/GoalongConversationEvidence.swift")
        XCTAssertTrue(evidence.contains("\"extrait sélectionnable\", \"extraits sélectionnables\""))
        XCTAssertFalse(evidence.contains("\\(rows.count) extraits sélectionnables"))
    }

    func testFrenchCountTakesTheSingularAtOne() {
        XCTAssertEqual(FrenchCount.count(1, "seconde", "secondes"), "1 seconde")
        XCTAssertEqual(FrenchCount.count(0, "pause restante", "pauses restantes"), "0 pause restante")
        XCTAssertEqual(FrenchCount.count(2, "changement", "changements"), "2 changements")
    }

    func testScheduleShowsAFrenchTimeNotTheRawZoneIdentifier() {
        let label = GoalongWebsiteSettings.scheduleLabel(hour: 8, minute: 0, zone: "Europe/Paris")
        XCTAssertTrue(label.hasPrefix("8 h 00"), label)
        XCTAssertFalse(label.contains("Europe/Paris"), label)
        XCTAssertEqual(GoalongWebsiteSettings.scheduleLabel(hour: 18, minute: 5, zone: nil), "18 h 05")
    }
}
#endif
