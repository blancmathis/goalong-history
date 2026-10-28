#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// H30b sweep: list name draft (D1), a blocked app is never force-quit (D2), and the cheap limits (L1, L3, L4, L6, L8, L9).
@MainActor final class T045H32Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_158_400)

    private func controller(_ lists: [BlockList]) -> BlockingController {
        BlockingController(document: .init(lists: lists), clock: { self.now }, backend: H32Backend())
    }

    private func locked(_ list: BlockList) -> BlockList {
        var list = list
        list.program = BlockProgram(ranges: [BlockProgramRange(weekdays: [1], startMinute: 600, endMinute: 900)],
                                    lockedUntil: now.addingTimeInterval(3600))
        return list
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // D1: erasing the name to retype it never shows the unrelated « Vérifiez la liste… » banner.
    func testEmptyListNameKeepsTheListAndSaysWhy() throws {
        let list = BlockList(name: "Vidéo")
        let c = controller([list])
        XCTAssertEqual(c.rename(list.id, to: "   "), "Le nom ne peut pas être vide.")
        XCTAssertEqual(c.list(list.id)?.name, "Vidéo")
        XCTAssertNil(c.error)
        XCTAssertNil(c.rename(list.id, to: " Jeu "))
        XCTAssertEqual(c.list(list.id)?.name, "Jeu")
        XCTAssertNil(c.rename(list.id, to: String(repeating: "a", count: 50)))
        XCTAssertEqual(c.list(list.id)?.name.count, 40)
        // The field edits a draft; it is saved on return or when the sheet closes, not at each key.
        let editor = try source("Sources/LocalHistoryApp/Blocking/BlockingPageLists.swift")
        XCTAssertTrue(editor.contains("TextField(\"Nom de la liste\", text: $nameDraft)"))
    }

    // D1: a trimmed name stays in the field; the stale snapshot must not undo it at the next close.
    func testTrimmedNameIsNotUndoneByTheStaleSnapshot() {
        let list = BlockList(name: "Vidéo")
        let c = controller([list])
        let first = BlockListEditor.commitName("Jeu ", of: list, controller: c)
        XCTAssertEqual(first, .init(text: "Jeu"))
        // The sheet closes before the view gets the new list: the second commit sees the old snapshot.
        XCTAssertEqual(BlockListEditor.commitName(first.text, of: list, controller: c), .init(text: "Jeu"))
        XCTAssertEqual(c.list(list.id)?.name, "Jeu")
        XCTAssertEqual(BlockListEditor.commitName("  ", of: c.list(list.id)!, controller: c),
                       .init(text: "Jeu", error: "Le nom ne peut pas être vide."))
    }

    // D2: ask the app to quit; if it stays open (a save dialog), hide it. Never force-quit.
    func testBlockedAppThatStaysOpenIsHiddenNeverKilled() throws {
        let app = H32App()
        XCTAssertTrue(BlockingAppQuit.followUp(app, stillBlocked: true))
        XCTAssertEqual(app.hides, 1)
        XCTAssertFalse(BlockingAppQuit.followUp(app, stillBlocked: false))
        app.isTerminated = true
        XCTAssertFalse(BlockingAppQuit.followUp(app, stillBlocked: true))
        XCTAssertEqual(app.hides, 1)
        let enforcement = try source("Sources/LocalHistoryApp/Blocking/BlockingEnforcement.swift")
        XCTAssertFalse(enforcement.contains("forceTerminate"))
        XCTAssertTrue(BlockingActionPicture.blockText.contains("jamais forcée"))
        XCTAssertTrue(BlockingActionPicture.blockText.contains("rien n’est perdu"))
        XCTAssertTrue(BlockedAppNotice.heldLine.contains("travail"))
        XCTAssertGreaterThan(BlockedAppNotice.height(nil, held: true), BlockedAppNotice.height(nil))
    }

    // L1: under a lock a stepper cannot go above the current value.
    func testLockedStepperRangesStopAtTheCurrentValue() {
        XCTAssertEqual(BlockListEditor.quotaRange(current: 30, stricterOnly: true), 5...30)
        XCTAssertEqual(BlockListEditor.quotaRange(current: 30, stricterOnly: false), 5...720)
        XCTAssertEqual(BlockListEditor.breakCountRange(current: 3, stricterOnly: true), 1...3)
        XCTAssertEqual(BlockListEditor.breakCountRange(current: 3, stricterOnly: false), 1...12)
        XCTAssertEqual(BlockListEditor.breakMinutesRange(current: 5, stricterOnly: true), 1...5)
        XCTAssertEqual(BlockListEditor.breakMinutesRange(current: 5, stricterOnly: false), 1...30)
    }

    // L3: a lock refusal is shown as is, not rewritten as « n’est pas un mot-clé ».
    func testLockRefusalOfAnExceptionIsShownAsIs() {
        let list = locked(BlockList(name: "Vidéo", sites: [.init(pattern: "youtube.com")]))
        let c = controller([list])
        let check = c.addException("youtube.com/cours", to: list.id)
        guard case .refused(let reason) = check else { return XCTFail("a locked list must refuse a new exception") }
        XCTAssertEqual(BlockListEditor.refusalMessage(check, input: "youtube.com/cours", kind: "une adresse de page"), reason)
        XCTAssertEqual(BlockListEditor.refusalMessage(.refused("Chaque mot-clé doit contenir de 2 à 40 caractères."),
                                                      input: "x", kind: "un mot-clé de 2 à 40 caractères"),
                       "« x » n’est pas un mot-clé de 2 à 40 caractères.")
        XCTAssertEqual(BlockListEditor.refusalMessage(.refused("Adresse d’exception invalide."), input: "x", kind: "une adresse de page"),
                       "« x » n’est pas une adresse de page.")
        XCTAssertNil(BlockListEditor.refusalMessage(.allowed, input: "x", kind: "un mot-clé"))
    }

    // L4: a refused site keeps the typed text and says why next to the field.
    func testRefusedSiteKeepsTheTypedText() {
        let free = BlockList(name: "Vidéo")
        let c = controller([free])
        XCTAssertEqual(BlockListEditor.addSite("youtube.com", to: free, controller: c), .init(text: "", error: nil))
        XCTAssertEqual(c.list(free.id)?.sites.map(\.pattern), ["youtube.com"])
        XCTAssertEqual(BlockListEditor.addSite("pas un site", to: free, controller: c).text, "pas un site")
        let strict = locked(BlockList(name: "Travail", mode: .allowOnly, sites: [.init(pattern: "example.com")]))
        let lockedController = controller([strict])
        let refused = BlockListEditor.addSite("youtube.com", to: strict, controller: lockedController)
        XCTAssertEqual(refused.text, "youtube.com")
        XCTAssertNotNil(refused.error)
        XCTAssertEqual(lockedController.list(strict.id)?.sites.map(\.pattern), ["example.com"])
    }

    // L6: a refused range removal keeps the popover open.
    func testRefusedRangeRemovalKeepsThePopoverOpen() {
        let strict = locked(BlockList(name: "Vidéo", sites: [.init(pattern: "youtube.com")]))
        let c = controller([strict])
        XCTAssertFalse(BlockingRangePopover.removeRange(strict.program.ranges[0].id, from: strict, controller: c))
        XCTAssertEqual(c.list(strict.id)?.program.ranges.count, 1)
        var free = strict; free.program.lockedUntil = nil
        let freeController = controller([free])
        XCTAssertTrue(BlockingRangePopover.removeRange(free.program.ranges[0].id, from: free, controller: freeController))
        XCTAssertEqual(freeController.list(free.id)?.program.ranges.count, 0)
    }

    // L8: an empty « Tout bloquer sauf » list blocks everything.
    func testEmptyAllowOnlyCardSaysEverythingIsBlocked() {
        XCTAssertEqual(BlockingListsSection.contents(BlockList(name: "Travail", mode: .allowOnly)), "Tout bloqué")
        XCTAssertEqual(BlockingListsSection.contents(BlockList(name: "Travail", mode: .allowOnly, sites: [.init(pattern: "example.com")])),
                       "Tout sauf 1 site")
    }

    // L9: the lock button is off while it would not move the end.
    func testProgramLockButtonNeedsALaterEnd() {
        let current = BlockingWallClock.endOfDay(now.addingTimeInterval(20 * 86_400))
        XCTAssertFalse(BlockingProgramLock.extends(until: current, current: current))
        XCTAssertTrue(BlockingProgramLock.extends(until: current.addingTimeInterval(86_400), current: current))
        XCTAssertTrue(BlockingProgramLock.extends(until: now, current: nil))
    }
}

private final class H32App: BlockingQuittableApp {
    var isTerminated = false
    var hides = 0
    func terminate() -> Bool { true }
    func hide() -> Bool { hides += 1; return true }
}

@MainActor private final class H32Backend: BlockingEnforcementBackend {
    var accessibilityAvailable = true
    var canLockScreen = true
    var browsers: [BlockingBrowserSupport] = []
    var appStillBlocked: ((BlockingObservation) -> Bool)?
    func observeBrowser(_ target: BlockingObservation) {}
    func updateProtection(locked: Bool) -> BlockingProtectionState { .init() }
    func blockApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) {}
    func blockSite(_ target: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void) {}
    func clearSite() {}
    func updateFreeze(_ freeze: BlockFreeze?) {}
    func returnToShield() {}
    func shutdown() {}
}
#endif
