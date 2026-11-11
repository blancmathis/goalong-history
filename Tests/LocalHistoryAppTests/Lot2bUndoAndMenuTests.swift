import XCTest
@testable import LocalHistoryApp

/// Lot 2b: « Annuler » after a harmless list deletion, and the ⌘R menu item.
final class Lot2bUndoAndMenuTests: XCTestCase {
    @MainActor private func controller(_ lists: [BlockList]) -> BlockingController {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let c = BlockingController(document: BlockingDocument(lists: lists), clock: { now },
                                   continuous: { now.timeIntervalSince1970 }, runningApps: { [] })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }

    @MainActor func testEmptyListIsDeletedAtOnceAndComesBack() {
        let empty = BlockList(name: "Vide")
        let c = controller([empty])
        XCTAssertTrue(c.deleteWithUndo(empty.id))
        XCTAssertNil(c.list(empty.id))
        XCTAssertEqual(c.undoableDeletion?.id, empty.id)
        c.undoDeletion()
        XCTAssertNotNil(c.list(empty.id))
        XCTAssertNil(c.undoableDeletion)
    }

    @MainActor func testListWithRulesKeepsTheConfirmation() {
        let full = BlockList(name: "Sites", sites: [BlockSiteRule(pattern: "youtube.com")])
        let c = controller([full])
        XCTAssertFalse(c.deleteWithUndo(full.id))
        XCTAssertNotNil(c.list(full.id))
        XCTAssertNil(c.undoableDeletion)
    }

    @MainActor func testUndoOfferExpires() async throws {
        let empty = BlockList(name: "Vide")
        let c = controller([empty])
        c.undoWindow = 0.05
        XCTAssertTrue(c.deleteWithUndo(empty.id))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(c.undoableDeletion)
        XCTAssertNil(c.list(empty.id))
    }

    @MainActor func testRefreshPageItemPostsTheNotification() throws {
        let controller = ApplicationMenuController(onOpenSettings: {}, onNavigate: { _ in },
                                                   onCheckForUpdates: {}, canCheckForUpdates: { true }, onQuit: {})
        let view = try XCTUnwrap(controller.mainMenu.items.first { $0.submenu?.title == "Présentation" }?.submenu)
        let item = try XCTUnwrap(view.item(withTitle: "Relire la page"))
        XCTAssertEqual(item.keyEquivalent, "r")
        var posted = false
        let token = NotificationCenter.default.addObserver(forName: .goalongRefreshPageRequested, object: nil, queue: nil) { _ in posted = true }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        XCTAssertTrue(posted)
    }
}
