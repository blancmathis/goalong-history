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
        // Tour 2: the whole file, not one phrase (a « séances continues » put back to « séquences » must fail).
        XCTAssertFalse(text.lowercased().contains("séquence"), "« séance » is the word of the focus explanation")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // Tour 2, point 4: the gauge sentence, built by one function the page calls.
    func testQuotaGaugeLineWording() {
        XCTAssertEqual(BlockingFormat.quotaGaugeLine(name: "Réseaux", secondsLeft: 20 * 60, quotaMinutes: 20, earnedMinutes: 0),
                       "Réseaux : 20 min restantes sur 20 min")
        XCTAssertTrue(BlockingFormat.quotaGaugeLine(name: "Réseaux", secondsLeft: 0, quotaMinutes: 20, earnedMinutes: 0)
            .hasPrefix("Réseaux : vos "))
        XCTAssertTrue(BlockingFormat.quotaGaugeLine(name: "Réseaux", secondsLeft: 600, quotaMinutes: 20, earnedMinutes: 5)
            .hasPrefix("Réseaux : 10 min restantes sur 25 min. "))
    }

    func testBlockingPageUsesTheGaugeLine() throws {
        let text = try source("Sources/LocalHistoryApp/Blocking/BlockingPage.swift")
        XCTAssertTrue(text.contains("BlockingFormat.quotaGaugeLine("), "the page must say the gauge through the tested function")
        XCTAssertFalse(text.contains("BlockingFormat.quotaLeft("), "no second, untested copy of the sentence in the page")
    }

    // Tour 2, point 3: the VoiceOver name is the visible label or starts with it.
    func testConcentrationFieldNamesMatchTheirLabels() throws {
        let text = try source("Sources/LocalHistoryApp/Concentration/ConcentrationPage.swift")
        XCTAssertTrue(text.contains("addField(\"Durée estimée (min)\")"))
        XCTAssertTrue(text.contains(".accessibilityLabel(\"Durée estimée (min)\")"))
        XCTAssertTrue(text.contains("Text(\"Heure de fin\")"))
        XCTAssertTrue(text.contains(".accessibilityLabel(\"Heure de fin\")"))
        XCTAssertFalse(text.contains("Estimation en minutes"))
        XCTAssertFalse(text.contains("Heure de fin de journée"))
    }

    // Tour 2, point 1: a module the person switched off is a choice to undo, like a refused permission.
    func testUserDisabledModulesUseTheLockKind() throws {
        let hub = try source("Sources/LocalHistoryApp/Concentration/ConcentrationHubPage.swift")
        XCTAssertTrue(hub.contains("est désactivé\", kind: .needsPermission"))
        let braise = try source("Sources/LocalHistoryApp/Braise/BraisePage.swift")
        XCTAssertTrue(braise.contains("est désactivée\", kind: .needsPermission"))
    }

    // Tour 2, point 2: a stop or an unreadable day is never « pas encore ».
    func testActivityEmptyKindFollowsTheState() {
        let stopped = GoalongActivityEmptyCopy.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0, purged: false,
            recording: nil, storage: .init(kind: .diskFull, since: nil))
        XCTAssertEqual(stopped.kind, .unavailable)
        let unreadable = GoalongActivityEmptyCopy.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 1, purged: false, recording: nil)
        XCTAssertEqual(unreadable.kind, .unavailable)
        let waiting = GoalongActivityEmptyCopy.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0, purged: false, recording: nil)
        XCTAssertEqual(waiting.kind, .notYet)
        XCTAssertEqual(ComputerHistoryPageCopy.emptyTimelineKind(storageStopped: true, status: .available), .unavailable)
        XCTAssertEqual(ComputerHistoryPageCopy.emptyTimelineKind(storageStopped: false, status: .inaccessible("x")), .unavailable)
        XCTAssertEqual(ComputerHistoryPageCopy.emptyTimelineKind(storageStopped: false, status: .available), .notYet)
    }

    // Tour 2, point 9: an app too old to connect is unavailable, not an empty list.
    func testRecapEmptyKindSaysTooOld() {
        XCTAssertEqual(ChatGPTRecapPage.emptyReportKind(analysesEnabled: true, connected: false, needsUpdate: true), .unavailable)
        XCTAssertEqual(ChatGPTRecapPage.emptyReportKind(analysesEnabled: true, connected: false, needsUpdate: false), .empty)
        XCTAssertEqual(ChatGPTRecapPage.emptyReportKind(analysesEnabled: true, connected: true, needsUpdate: false), .empty)
    }

    // Tour 2, point 6: « son » no longer points at the recording.
    func testCLITimezoneSentence() throws {
        let text = try source("Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift")
        XCTAssertTrue(text.contains("avec le fuseau horaire actuel du Mac"))
        XCTAssertFalse(text.contains("avec son fuseau horaire"))
    }

    // Tour 2, point 7: « séance » in the Rhythm and analytics preview texts.
    func testRhythmAndPreviewSaySeance() throws {
        for path in ["Sources/LocalHistoryApp/GoalongRhythmStudio.swift", "Sources/LocalHistoryApp/GoalongAnalyticsPreview.swift"] {
            XCTAssertFalse(try source(path).lowercased().contains("séquence"), path)
        }
    }
}
#endif
