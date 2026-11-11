#if os(macOS)
import AppKit
import BraiseCore
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-052 lot 1c: the five sheets that use the shared click-outside mechanism, each in its real view, hosted in a real SwiftUI
/// `.sheet` on a window the headless support keeps off screen (alpha 0, never key). No window shows, no focus moves.
@MainActor final class GoalongSheetDismissalLot1cTests: XCTestCase {
    private final class Box: ObservableObject { @Published var shown = true; var closes = 0 }

    private struct Host<Content: View>: View {
        @ObservedObject var box: Box
        let content: Content
        var body: some View {
            Color.clear.frame(width: 700, height: 500).sheet(isPresented: Binding(get: { box.shown }, set: { if !$0 { box.shown = false; box.closes += 1 } })) { content }
        }
    }

    private struct Rig {
        let parent: NSWindow
        let box: Box
        var sheet: NSWindow { parent.attachedSheet! }
    }

    private func rig<Content: View>(_ content: Content) -> Rig {
        let box = Box()
        let parent = NSWindow(contentRect: NSRect(x: 20000, y: 20000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentViewController = NSHostingController(rootView: Host(box: box, content: content))
        parent.orderFrontRegardless()
        spin({ parent.attachedSheet != nil && !(parent.attachedSheet?.contentView?.subviews.isEmpty ?? true) }, for: 2)
        spin(for: 0.3)
        return Rig(parent: parent, box: box)
    }

    private func spin(_ condition: () -> Bool = { false }, for seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func clickOutside(_ rig: Rig) {
        let point = NSPoint(x: 60, y: rig.parent.contentLayoutRect.height / 2)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime - 5,
                                       windowNumber: rig.parent.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(event)
        spin(for: 0.5)
    }

    private func press(_ rig: Rig, _ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: rig.sheet.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
        spin(for: 0.5)
    }

    /// Types into the sheet's text field whose placeholder (or accessibility label) matches, through its field editor.
    @discardableResult private func type(_ text: String, into rig: Rig, field label: String) -> Bool {
        let sheet = rig.sheet
        func all(_ view: NSView) -> [NSTextField] { ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        guard let root = sheet.contentView else { return false }
        let visible = all(root).filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
        // « lowest »: the field lowest in the sheet (the list editor's « Ajouter un site » sits under the name and the reason).
        let lowest = visible.min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        let match = label == "lowest" ? lowest : all(root).first { field in
            (field.placeholderString == label || field.placeholderAttributedString?.string == label || field.accessibilityLabel() == label
                || field.accessibilityIdentifier() == label) && field.isEditable
        }
        // The sheet puts its first field in focus when it opens (lot 1): fields with a custom placeholder fall back on it.
        let editor: NSTextView
        if let field = match {
            sheet.makeFirstResponder(field)
            spin(for: 0.1)
            guard let current = field.currentEditor() as? NSTextView else { return false }
            editor = current
        } else if let focused = sheet.firstResponder as? NSTextView, focused.isEditable { editor = focused }
        else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        spin(for: 0.3)
        return true
    }

    private func close(_ rig: Rig) {
        if let sheet = rig.parent.attachedSheet { rig.parent.endSheet(sheet); sheet.close() }
        rig.parent.close()
    }

    private func temporaryRoot() -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-lot1c-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // MARK: Éditeur de liste

    func testListSheetClosesOnAnOutsideClick() {
        let box = Box()
        let list = BlockList(id: UUID(), name: "Réseaux", sites: [BlockSiteRule(pattern: "x.com")])
        let controller = BlockingController(document: BlockingDocument(lists: [list]), clock: { Date() })
        let content = BlockListSheet(controller: controller, listID: list.id, now: Date(), onDone: { box.shown = false; box.closes += 1 })
        let rig = Rig(parent: rig(content).parent, box: box)
        defer { close(rig) }
        XCTAssertNotNil(rig.parent.attachedSheet)
        clickOutside(rig)
        XCTAssertEqual(box.closes, 1, "un clic dehors = « Fermer »")
    }

    func testListSheetWithATypedSiteNotYetAddedAsksFirst() {
        let box = Box()
        let list = BlockList(id: UUID(), name: "Réseaux", sites: [BlockSiteRule(pattern: "x.com")])
        let controller = BlockingController(document: BlockingDocument(lists: [list]), clock: { Date() })
        let content = BlockListSheet(controller: controller, listID: list.id, now: Date(), onDone: { box.shown = false; box.closes += 1 })
        let rig = Rig(parent: rig(content).parent, box: box)
        defer { close(rig) }
        XCTAssertTrue(type("youtube.com", into: rig, field: "lowest"),
                      "the site field takes the typed text")
        clickOutside(rig)
        XCTAssertEqual(box.closes, 0, "un site tapé et pas ajouté n'est pas perdu sans question")
        XCTAssertNotNil(rig.parent.attachedSheet)
    }

    // MARK: Concentration

    private func concentration() throws -> ConcentrationController {
        try ConcentrationController(store: FocusStore(directory: temporaryRoot()), clock: { Date() }, blocking: { BlockingController(clock: { Date() }) })
    }

    func testReviewSheetClosesCleanAndAsksWhenANoteIsTyped() throws {
        let controller = try concentration()
        let clean = Box()
        let first = Rig(parent: rig(ConcentrationReviewSheet(controller: controller, plan: controller.plan, review: nil,
                                                              onClose: { clean.closes += 1 })).parent, box: clean)
        clickOutside(first)
        XCTAssertEqual(clean.closes, 1, "bilan intact : « Annuler »")
        close(first)

        let dirty = Box()
        let second = Rig(parent: rig(ConcentrationReviewSheet(controller: controller, plan: controller.plan, review: nil,
                                                               onClose: { dirty.closes += 1 })).parent, box: dirty)
        defer { close(second) }
        XCTAssertTrue(type("Relire le plan", into: second, field: "concentration-tomorrow-first") || type("Relire le plan", into: second, field: "Demain, je commence par"))
        clickOutside(second)
        XCTAssertEqual(dirty.closes, 0, "un bilan modifié demande avant de fermer")
    }

    func testCommitmentEditorClosesOnAnOutsideClickAndEscape() throws {
        let controller = try concentration()
        let today = FocusCommitmentPeriod(kind: .day, key: FocusCalendar.dayKey(Date()))
        let box = Box()
        let content = FocusCommitmentEditor(controller: controller, request: .init(periods: [today]), now: Date(), onClose: { box.closes += 1 })
        let rig = Rig(parent: rig(content).parent, box: box)
        clickOutside(rig)
        XCTAssertEqual(box.closes, 1, "engagement intact : « Annuler »")
        press(rig, "\u{1B}", code: 53)
        XCTAssertGreaterThanOrEqual(box.closes, 2, "Échap = « Annuler » aussi")
        close(rig)
    }

    // MARK: Braise (plage, sans mot de passe)

    private func braise() throws -> (BraiseController, RedScreenRangeDraft) {
        let root = temporaryRoot()
        let store = BraiseStore(directory: root, legacySettings: root.appendingPathComponent("missing"))
        let controller = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false, clock: { Date(timeIntervalSince1970: 1_790_000_000) })
        addTeardownBlock { controller.shutdown() }
        let range = BlockProgramRange(weekdays: Set(1...5), startMinute: 21 * 60, endMinute: 7 * 60, lock: nil)
        return (controller, RedScreenRangeDraft(range: range, intensity: 0.8, enabled: true, existed: false))
    }

    func testRangeEditorClosesOnAnOutsideClickAndAsksWithAnUnreadTime() throws {
        let (controller, draft) = try braise()
        let first = rig(RedScreenRangeEditor(controller: controller, initial: draft))
        clickOutside(first)
        XCTAssertFalse(first.box.shown, "plage intacte : « Annuler »")
        close(first)

        let second = rig(RedScreenRangeEditor(controller: controller, initial: draft))
        defer { close(second) }
        XCTAssertTrue(type("zz", into: second, field: "Début"), "the start time field takes the unreadable text")
        clickOutside(second)
        XCTAssertTrue(second.box.shown, "une heure illisible tapée demande avant de fermer")
    }

    // MARK: Jev

    func testJevConnectionSheetClosesCleanAndAsksWhenAKeyIsTyped() {
        let first = rig(JevConnectionSheet())
        clickOutside(first)
        XCTAssertFalse(first.box.shown, "aucune clé tapée : « Fermer »")
        close(first)

        let second = rig(JevConnectionSheet())
        defer { close(second) }
        XCTAssertTrue(type("sk-test-123", into: second, field: "jev-api-key") || type("sk-test-123", into: second, field: "Clé d’accès Jev"))
        clickOutside(second)
        XCTAssertTrue(second.box.shown, "une clé tapée n'est pas perdue sans question")
    }

    // MARK: Onboarding

    func testTheOnboardingActivationSheetIsAlreadyOnTheMechanism() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LocalHistoryApp/SourceActivation.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("goalongDismissOnOutsideClick(isEnabled: { !restarting }"),
                      "l'onboarding ouvre SourceActivationSheet : le même branchement (lot 1) le couvre")
    }
}
#endif
