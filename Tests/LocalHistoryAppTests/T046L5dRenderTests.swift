#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-046 L5d: sheets with a simple constructor that no test rendered. Each test renders the view off screen
/// (no window, no focus) and checks the title, the controls and the state the user sees.
final class T046L5dRenderTests: XCTestCase {
    private let day = Calendar.current.date(from: .init(year: 2026, month: 9, day: 18, hour: 12))!

    @MainActor func testHealthImportShowsTheFailureOfARefusedFileAndKeepsTheChoices() {
        let seen = accessible(GoalongHealthImportSheet(gallery: .failed("Ce fichier n’a pas pu être lu.")))
        XCTAssertTrue(seen.contains("Apple Santé"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Ce fichier n’a pas pu être lu."), "The refusal stays in the footer; saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Choisir export.xml…"))
        XCTAssertTrue(seen.contains("Oublier ce fichier"), "A chosen file can be forgotten")
        XCTAssertTrue(seen.contains("Choisir les dates et les données"))
    }

    @MainActor func testHealthImportWhileReadingOffersToCancelTheRead() {
        let seen = accessible(GoalongHealthImportSheet(gallery: .reading))
        XCTAssertTrue(seen.contains("Lecture locale de l’export…"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Annuler la lecture"))
        XCTAssertFalse(seen.contains("Données déclaratives · aucun score de productivité calculé"), "The footer note gives way to the progress")
    }

    @MainActor func testHealthImportWithoutFileOnlyAsksForTheExport() {
        let seen = accessible(GoalongHealthImportSheet())
        XCTAssertTrue(seen.contains("Choisir export.xml…"), "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains("Oublier ce fichier"))
        XCTAssertFalse(seen.contains("Choisir les dates et les données"), "Dates and groups appear once a file is chosen")
        XCTAssertTrue(seen.contains("Données déclaratives · aucun score de productivité calculé"))
    }

    @MainActor func testRhythmStudioAsksForAProjectAndARange() {
        let seen = accessible(GoalongRhythmStudio(day: day, masks: [], onAccept: { _ in }))
        XCTAssertTrue(seen.contains("Comprendre une session"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Fermer"))
        XCTAssertTrue(seen.contains("Préparer la sélection locale"), "saw \(seen.sorted())")
    }

    @MainActor func testProfileStudioOffersToOpenASavedAnalysis() {
        let seen = accessible(GoalongProfileStudio(onSend: { _ in }, onClose: {}, localOnly: true, initialDay: day))
        XCTAssertTrue(seen.contains("Comprendre mon travail"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Fermer"))
        XCTAssertTrue(seen.contains("Ouvrir une analyse ou une sélection enregistrée…"))
    }

    @MainActor func testSiteAnalysisSheetTitleAndClose() {
        let seen = accessible(GoalongSiteAnalysisSheet())
        XCTAssertTrue(seen.contains("Analyser une demande du site"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Fermer"))
    }

    @MainActor func testProgramLockNamesTheRealEndOfTheLock() {
        var locked: [Date] = []
        let seen = accessible(BlockingProgramLock(current: nil, now: day, onLock: { locked.append($0) }))
        XCTAssertTrue(seen.contains("Verrouiller le programme"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains { $0.hasPrefix("Verrouiller jusqu’au ") }, "The button names the end date; saw \(seen.sorted())")
        XCTAssertTrue(locked.isEmpty, "Rendering never locks")
        let end = BlockingProgramLock.initialUntil(current: nil, now: day)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: day, to: end).day, 14)
        XCTAssertFalse(BlockingProgramLock.extends(until: day, current: BlockingWallClock.endOfDay(day.addingTimeInterval(86_400 * 3))),
                       "An earlier end does not extend the lock")
    }

    @MainActor func testJevMenuShowsTheStatusAndOpensTheMonitoringPage() {
        var opened = 0
        let parent = NSMenu()
        JevMenuController.shared.install(in: parent, onOpenMonitoring: { opened += 1 })
        let menu = try! XCTUnwrap(parent.items.first?.submenu)
        JevMenuController.shared.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, JevMonitor.shared.status, "The first line states the monitoring status")
        XCTAssertFalse(menu.items[0].isEnabled, "The status line is not clickable")
        XCTAssertTrue(titles.contains("Ouvrir la surveillance…"), "saw \(titles)")
        let open = try! XCTUnwrap(menu.items.first { $0.title == "Ouvrir la surveillance…" })
        _ = open.target?.perform(open.action)
        XCTAssertEqual(opened, 1, "The item opens the monitoring page")
        if !JevMonitor.shared.enabled {
            XCTAssertFalse(titles.contains("Désactiver la surveillance"), "Nothing to disable while monitoring is off")
            XCTAssertFalse(titles.contains { $0.hasPrefix("Pause de ") }, "No break is offered while monitoring is off")
        }
    }

    // MARK: Rendu

    /// Renders off screen and returns every identifier, label, title and string value of the AX tree.
    @MainActor private func accessible(_ root: some View) -> Set<String> {
        let view = NSHostingView(rootView: root.environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 1600)
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
