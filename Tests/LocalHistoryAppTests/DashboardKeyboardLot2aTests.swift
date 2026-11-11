#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import LocalHistoryApp

/// T-052 lot 2a: the keyboard, the return pages and the reopened page, on the real model, the real window controller and the
/// real menu. Nothing is ordered on screen and no focus moves: synthetic key events go to the router, and the one sheet is a
/// bare window attached to the dashboard window.
@MainActor final class DashboardKeyboardLot2aTests: XCTestCase {
    private func isolated() throws {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("needs the isolated test HOME of make check (the window frame is saved in the preferences)")
        }
    }

    private struct Rig {
        let ctx: GalleryContext
        let model: DashboardViewModel
        let controller: DashboardWindowController
        var window: NSWindow { controller.window! }
        var router: DashboardKeyRouter { controller.keyRouter! }
    }

    private func rig(_ section: DashboardSection = .overview) throws -> Rig {
        let ctx = GalleryContext()
        var options = GalleryFixtures.DashboardOptions()
        options.section = section
        let model = try GalleryFixtures.dashboardModel(ctx, options)
        let controller = DashboardWindowController(viewModel: model)
        controller.loadWindow()
        return Rig(ctx: ctx, model: model, controller: controller)
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    @discardableResult private func press(_ rig: Rig, _ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> Bool {
        rig.router.handle(key(code, chars, flags: flags, in: rig.window))
    }

    private let left: UInt16 = 123, right: UInt16 = 124, escape: UInt16 = 53, tKey: UInt16 = 17

    private func close(_ rig: Rig) {
        rig.window.contentView = nil
        rig.window.close()
        rig.ctx.finish()
    }

    /// A text field in the window, first responder (its field editor is the focus).
    private func addField(_ rig: Rig, placeholder: String, text: String = "", focus: Bool) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        field.placeholderString = placeholder
        field.stringValue = text
        rig.window.contentView?.addSubview(field)
        if focus { XCTAssertTrue(rig.window.makeFirstResponder(field)) }
        return field
    }

    // MARK: ←, → and T (2)

    func testArrowsAndTMoveTheDayOnHistoriqueAndNeverWhileTyping() throws {
        try isolated()
        let rig = try rig(.history)
        defer { close(rig) }
        let model = rig.model
        let today = Calendar.current.startOfDay(for: model.now())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(Calendar.current.startOfDay(for: model.navigationStore.selectedDay), today)
        XCTAssertTrue(press(rig, left))
        XCTAssertEqual(Calendar.current.startOfDay(for: model.navigationStore.selectedDay), yesterday)
        XCTAssertTrue(press(rig, right))
        XCTAssertEqual(Calendar.current.startOfDay(for: model.navigationStore.selectedDay), today)
        press(rig, right)
        XCTAssertEqual(Calendar.current.startOfDay(for: model.navigationStore.selectedDay), today, "no day after today")
        press(rig, left); press(rig, left)
        XCTAssertTrue(press(rig, tKey, "t"))
        XCTAssertEqual(Calendar.current.startOfDay(for: model.navigationStore.selectedDay), today)
        // A key with a modifier is a menu's, not ours.
        XCTAssertFalse(press(rig, left, flags: .command))
        XCTAssertFalse(press(rig, tKey, "t", flags: .shift))
        // The focus is in a text field: the keys belong to it.
        _ = addField(rig, placeholder: "Nom", focus: true)
        XCTAssertFalse(press(rig, left))
        XCTAssertFalse(press(rig, tKey, "t"))
        XCTAssertEqual(Calendar.current.startOfDay(for: model.navigationStore.selectedDay), today)
    }

    func testArrowsOnActiviteReachThePageAndStayOffOtherPages() throws {
        try isolated()
        let rig = try rig(.overview)
        defer { close(rig) }
        var received: [DashboardKeyCommand] = []
        let sink = rig.model.navigationStore.dayKeys.sink { received.append($0) }
        defer { sink.cancel() }
        XCTAssertTrue(press(rig, left)); XCTAssertTrue(press(rig, right)); XCTAssertTrue(press(rig, tKey, "t"))
        XCTAssertEqual(received, [.previousDay, .nextDay, .today])
        rig.model.selectSection(.blocking)
        XCTAssertFalse(press(rig, left))
        rig.model.selectSection(.settings)
        XCTAssertFalse(press(rig, tKey, "t"))
        XCTAssertEqual(received.count, 3)
    }

    func testKeysArriveThroughTheRealMonitor() throws {
        try isolated()
        let rig = try rig(.history)
        defer { close(rig) }
        rig.window.setFrameOrigin(NSPoint(x: 20000, y: 20000))
        rig.window.orderFrontRegardless()
        defer { rig.window.orderOut(nil) }
        let today = Calendar.current.startOfDay(for: rig.model.now())
        NSApp.sendEvent(key(left, in: rig.window))
        XCTAssertNotEqual(Calendar.current.startOfDay(for: rig.model.navigationStore.selectedDay), today, "the monitor did not route ←")
    }

    // MARK: Échap (3)

    func testEscapeGoesBackOnlyFromASecondaryPageWithNothingInFront() throws {
        try isolated()
        let rig = try rig(.settings)
        defer { close(rig) }
        let model = rig.model
        XCTAssertFalse(press(rig, escape), "Échap on a main page does nothing")
        model.selectSection(.privacy)
        XCTAssertEqual(model.navigationStore.selectedSection, .privacy)
        // A sheet is open: Échap closes the sheet, not the page.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        rig.window.beginSheet(sheet)
        XCTAssertFalse(press(rig, escape))
        XCTAssertEqual(model.navigationStore.selectedSection, .privacy)
        rig.window.endSheet(sheet)
        // A search field holds text: Échap clears it first.
        let search = addField(rig, placeholder: "Rechercher…", text: "mail", focus: false)
        XCTAssertFalse(press(rig, escape))
        XCTAssertEqual(model.navigationStore.selectedSection, .privacy)
        search.stringValue = ""
        XCTAssertTrue(press(rig, escape))
        XCTAssertEqual(model.navigationStore.selectedSection, .settings)
    }

    // MARK: Return pages (9, 10) and Réglages (7)

    func testEachReturnNamesAndReachesItsRealOrigin() throws {
        try isolated()
        let rig = try rig(.overview)
        defer { close(rig) }
        let model = rig.model
        let cases: [(DashboardSection, DashboardSection, String)] = [
            (.overview, .screenTime, "Retour à l’activité"),
            (.history, .agentActivity, "Retour à l’historique"),
            (.blocking, .privacy, "Retour aux blocages"),
            (.settings, .cli, "Retour aux réglages"),
        ]
        for (origin, secondary, title) in cases {
            model.selectSection(origin)
            model.selectSection(secondary)
            XCTAssertEqual(model.navigationStore.secondaryReturnTitle, title, "\(origin) → \(secondary)")
            model.returnFromSecondaryPage()
            XCTAssertEqual(model.navigationStore.selectedSection, origin)
        }
    }

    func testReglagesKeepsItsPaneUnlessAlreadyThere() throws {
        try isolated()
        let rig = try rig(.overview)
        defer { close(rig) }
        let model = rig.model
        model.selectSection(.settings)
        model.navigationStore.settingsPane = .permissions
        model.selectSection(.history)
        model.selectSection(.settings)
        XCTAssertEqual(model.navigationStore.settingsPane, .permissions, "leaving and coming back keeps the open pane")
        model.selectSection(.settings)
        XCTAssertEqual(model.navigationStore.settingsPane, .home, "a click on Réglages while there goes home")
    }

    // MARK: ⌘ digits and ⌘F (4)

    func testCommandDigitsOpenEachSidebarPageAndAmbianceFollowsItsModule() throws {
        var opened: [DashboardSection] = []
        var ambiance = true
        let controller = ApplicationMenuController(
            onOpenSettings: {}, onNavigate: { opened.append($0) }, onCheckForUpdates: {}, canCheckForUpdates: { true }, onQuit: {},
            isSectionAvailable: { $0 != .ambiance || ambiance })
        func command(_ digit: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                         characters: digit, charactersIgnoringModifiers: digit, isARepeat: false, keyCode: 0)!
            _ = controller.mainMenu.performKeyEquivalent(with: event)
        }
        for digit in ["1", "2", "3", "4"] { command(digit) }
        XCTAssertEqual(opened, [.overview, .history, .blocking, .ambiance])
        ambiance = false
        command("4")
        XCTAssertEqual(opened.count, 4, "⌘4 is off while the Ambiance module is off")
        for section in [DashboardSection.overview, .history, .blocking, .ambiance, .settings] {
            XCTAssertTrue(section.sidebarTooltip.hasSuffix("(⌘\(section.sidebarShortcutKey!))"))
        }
        XCTAssertEqual(DashboardSection.settings.sidebarTooltip, "Réglages (⌘,)")
    }

    func testFindGivesTheSearchFieldTheFocusOnlyWhenThePageHasOne() throws {
        try isolated()
        let rig = try rig(.history)
        defer { close(rig) }
        XCTAssertTrue(DashboardKeyboard.searchFields(in: rig.window).allSatisfy { $0 !== rig.window.firstResponder })
        let field = addField(rig, placeholder: "Rechercher dans l’historique…", focus: false)
        XCTAssertTrue(DashboardKeyboard.focusSearchField(in: rig.window))
        XCTAssertTrue((rig.window.firstResponder as? NSText)?.delegate === field, "the field editor of the search field has the focus")
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        rig.window.beginSheet(sheet)
        XCTAssertFalse(DashboardKeyboard.focusSearchField(in: rig.window), "never behind a sheet")
        rig.window.endSheet(sheet)
    }

    // MARK: The reopened window (11)

    func testTheWindowReopensOnTheLastMainPageAndRestoresItsFrame() throws {
        try isolated()
        let first = try rig(.overview)
        first.model.selectSection(.history)
        first.model.selectSection(.agentActivity)   // a secondary page is not a resting page
        XCTAssertEqual(first.model.lastMainSection(ambianceAvailable: true), .history)
        // A new model on the same preferences, as after a relaunch.
        let model = try GalleryFixtures.dashboardModel(first.ctx, GalleryFixtures.DashboardOptions())
        XCTAssertEqual(model.lastMainSection(ambianceAvailable: true), .history)
        let second = DashboardWindowController(viewModel: model)
        XCTAssertEqual(second.resumeSection(), .history)
        first.model.selectSection(.ambiance)
        XCTAssertEqual(model.lastMainSection(ambianceAvailable: true), .ambiance)
        XCTAssertEqual(model.lastMainSection(ambianceAvailable: false), .overview, "Ambiance off: Activité")
        // Size and position: saved with the frame name, restored by the next window.
        let screen = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        let frame = NSRect(x: screen.minX + 37, y: screen.minY + 41, width: 913, height: 700)
        first.window.setFrame(frame, display: false)
        first.window.saveFrame(usingName: DashboardWindowController.frameAutosaveName)
        close(first)
        let third = DashboardWindowController(viewModel: model)
        third.loadWindow()
        let restored = try XCTUnwrap(third.window).frame
        XCTAssertEqual(restored.size.width, 913, accuracy: 1)
        XCTAssertEqual(restored.size.height, 700, accuracy: 1)
        XCTAssertEqual(restored.origin.x, frame.origin.x, accuracy: 1)
        third.window?.contentView = nil; third.window?.close()
    }
}
#endif
