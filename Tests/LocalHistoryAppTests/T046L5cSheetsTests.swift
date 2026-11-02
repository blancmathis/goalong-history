#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-046 L5c: sheets and editors that no test rendered. Each test renders the view off screen (no window, no focus)
/// and checks the controls the user sees: which buttons exist for a new item and for an existing one.
final class T046L5cSheetsTests: XCTestCase {
    private let day = Calendar.current.date(from: .init(year: 2026, month: 9, day: 18))!

    // MARK: Note du jour

    @MainActor func testNewDayNoteOffersSaveAndCancelButNoDelete() {
        let seen = accessible(GoalongDayNoteSheet(day: day, initial: "", onSave: { _ in }, onDelete: {}))
        XCTAssertTrue(seen.contains("Enregistrer"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Annuler"), "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains("Supprimer"), "A note that does not exist yet cannot be deleted")
        XCTAssertTrue(seen.contains("activity-note-text"))
    }

    @MainActor func testExistingDayNoteOffersDeleteAndShowsItsLength() {
        let seen = accessible(GoalongDayNoteSheet(day: day, initial: "Deux rendez-vous.", onSave: { _ in }, onDelete: {}))
        XCTAssertTrue(seen.contains("Supprimer"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Annuler"))
        XCTAssertTrue(seen.contains("Enregistrer"))
        XCTAssertTrue(seen.contains("17 / \(GoalongDayNoteSheet.limit)"), "Counter shows the trimmed length; saw \(seen.sorted())")
    }

    // MARK: Plage de blocage

    @MainActor func testNewBlockingRangeAsksWhichListsAndHasNoDelete() {
        let list = BlockList(name: "Réseaux", sites: [.init(pattern: "example.org")])
        let controller = BlockingController(document: BlockingDocument(lists: [list]))
        let draft = BlockingRangeDraft(existing: nil, listIDs: [list.id], days: [1, 2, 3, 4, 5], start: 9 * 60, end: 12 * 60)
        let seen = accessible(BlockingRangePopover(controller: controller, draft: draft, now: day, onClose: {}))
        XCTAssertTrue(seen.contains("Programmer un blocage"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Programmer"), "A new range is created with « Programmer »")
        XCTAssertTrue(seen.contains("Annuler"))
        XCTAssertTrue(seen.contains("Lun–ven") && seen.contains("Tous"))
        XCTAssertTrue(seen.contains("blocking-range-save"))
        XCTAssertFalse(seen.contains("blocking-range-delete"), "Nothing to delete before the range exists")
    }

    @MainActor func testExistingBlockingRangeCanBeSavedOrDeleted() {
        var list = BlockList(name: "Réseaux", sites: [.init(pattern: "example.org")])
        let range = BlockProgramRange(weekdays: [1, 2], startMinute: 9 * 60, endMinute: 12 * 60)
        list.program = BlockProgram(ranges: [range])
        let controller = BlockingController(document: BlockingDocument(lists: [list]))
        let draft = BlockingRangeDraft(existing: range.id, listIDs: [list.id], days: [1, 2], start: 9 * 60, end: 12 * 60)
        let seen = accessible(BlockingRangePopover(controller: controller, draft: draft, now: day, onClose: {}))
        XCTAssertTrue(seen.contains("Enregistrer"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("blocking-range-delete"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Supprimer"))
    }

    // MARK: Rendu

    /// Renders off screen and returns every identifier, label, title and string value of the AX tree.
    @MainActor private func accessible(_ root: some View) -> Set<String> {
        let view = NSHostingView(rootView: root.environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 1200)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        var strings = Set<String>(), pending: [Any] = [view], visited = Set<ObjectIdentifier>()
        while let value = pending.popLast(), visited.count < 20_000 {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = read(object, name) as? String, !text.isEmpty { strings.insert(text) }
            }
            pending.append(contentsOf: read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return strings
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
}
#endif
