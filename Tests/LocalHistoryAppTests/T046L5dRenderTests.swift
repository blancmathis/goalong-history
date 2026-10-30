#if os(macOS)
import AppKit
import LocalHistoryCore
import LocalHistoryQueryCLI
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-046 L5d: sheets with a simple constructor that no test rendered. Each test renders the view off screen
/// (no window, no focus) and checks the title, the controls and the state the user sees.
final class T046L5dRenderTests: XCTestCase {
    private let day = Calendar.current.date(from: .init(year: 2026, month: 9, day: 18, hour: 12))!
    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private var enhancedUIBefore: Any?

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            enhancedUIBefore = NSApplication.shared.accessibilityAttributeValue(Self.enhancedUI)
            NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            NSApplication.shared.accessibilitySetValue(enhancedUIBefore ?? false, forAttribute: Self.enhancedUI)
        }
        try await super.tearDown()
    }

    @MainActor func testHealthImportShowsTheFailureOfARefusedFileAndKeepsTheChoices() {
        let rendered = host(GoalongHealthImportSheet(gallery: .failed("Ce fichier n’a pas pu être lu.")))
        let seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("Apple Santé"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Ce fichier n’a pas pu être lu."), "The refusal stays in the footer; saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Choisir export.xml…"))
        XCTAssertTrue(seen.contains("Oublier ce fichier"), "A chosen file can be forgotten")
        XCTAssertTrue(seen.contains("Choisir les dates et les données"))
        XCTAssertTrue(seen.contains("Du") && seen.contains("Au"), "The two dates of the range; saw \(seen.sorted())")
        for group in GoalongHealthGroup.allCases { XCTAssertTrue(seen.contains(group.title), "A switch for \(group.title)") }
        XCTAssertEqual(isEnabled("Préparer l’aperçu local", in: rendered), true, "Every group is chosen, so the preview can be prepared")
        XCTAssertEqual(isEnabled("Fermer", in: rendered), true, "Nothing is running, so the sheet can be closed")
    }

    @MainActor func testHealthImportWhileReadingOffersToCancelTheRead() {
        let rendered = host(GoalongHealthImportSheet(gallery: .reading))
        let seen = strings(of: rendered)
        XCTAssertEqual(isEnabled("Fermer", in: rendered), false, "The sheet cannot be closed while the file is read")
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
        let rendered = host(GoalongRhythmStudio(day: day, masks: [], onAccept: { _ in }))
        let seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("Comprendre une session"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Fermer"))
        XCTAssertTrue(seen.contains("Préparer la sélection locale"), "saw \(seen.sorted())")
        // The two text fields are empty, so their placeholders are not in the accessibility tree.
        for label in ["Début", "Fin", "Inclure les extraits de contexte enrichi déjà autorisés", "Vous choisirez ensuite les champs transmis au site."] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertEqual(isEnabled("Préparer la sélection locale", in: rendered), false, "No project is typed yet, so nothing can be prepared")
        XCTAssertTrue(seen.contains("Utiliser cette session relue"), "The accept button is always offered; saw \(seen.sorted())")
    }

    @MainActor func testProfileStudioOffersToOpenASavedAnalysis() {
        let seen = accessible(GoalongProfileStudio(onSend: { _ in }, onClose: {}, localOnly: true, initialDay: day))
        XCTAssertTrue(seen.contains("Comprendre mon travail"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Fermer"))
        XCTAssertTrue(seen.contains("Ouvrir une analyse ou une sélection enregistrée…"))
        XCTAssertTrue(seen.contains("Activité depuis"), "The computer history is on by default; saw \(seen.sorted())")
        for key in GoalongProfileAnalysis.modules where key != "ai" {
            XCTAssertTrue(seen.contains(GoalongProfileAnalysis.labels[key] ?? key), "A switch for the module \(key); saw \(seen.sorted())")
        }
        XCTAssertFalse(seen.contains("Conversations actives depuis"), "The conversations start date waits for the switch")
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
        XCTAssertTrue(seen.contains("Jusqu’au"), "The end date can be changed; saw \(seen.sorted())")
        let named = "Verrouiller jusqu’au \(BlockingFormat.day(BlockingProgramLock.initialUntil(current: nil, now: day)))"
        XCTAssertTrue(seen.contains(named), "The button names the default end of the lock; saw \(seen.sorted())")
        XCTAssertTrue(locked.isEmpty, "Rendering never locks")
        let end = BlockingProgramLock.initialUntil(current: nil, now: day)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: day, to: end).day, 14)
        XCTAssertFalse(BlockingProgramLock.extends(until: day, current: BlockingWallClock.endOfDay(day.addingTimeInterval(86_400 * 3))),
                       "An earlier end does not extend the lock")
    }

    @MainActor func testJevMenuShowsTheStatusAndOpensTheMonitoringPage() throws {
        var opened = 0
        let parent = NSMenu()
        JevMenuController.shared.install(in: parent, onOpenMonitoring: { opened += 1 })
        addTeardownBlock { @MainActor in JevMenuController.shared.install(in: NSMenu(), onOpenMonitoring: {}) }
        let menu = try XCTUnwrap(parent.items.first?.submenu)
        JevMenuController.shared.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, JevMonitor.shared.status, "The first line states the monitoring status")
        XCTAssertFalse(menu.items[0].isEnabled, "The status line is not clickable")
        XCTAssertTrue(titles.contains("Ouvrir la surveillance…"), "saw \(titles)")
        let open = try XCTUnwrap(menu.items.first { $0.title == "Ouvrir la surveillance…" })
        _ = open.target?.perform(open.action)
        XCTAssertEqual(opened, 1, "The item opens the monitoring page")
        let enabled = JevMonitor.shared.enabled
        XCTAssertEqual(titles.contains("Désactiver la surveillance"), enabled, "Disabling is offered only while monitoring runs")
        XCTAssertEqual(titles.contains { $0.hasPrefix("Pause de ") }, enabled && JevMonitor.shared.timedBreak == nil,
                       "Breaks are offered only while monitoring runs and no break is active")
    }

    @MainActor func testHealthImportKeptPreviewOffersSavingExportingAndAGatedSend() throws {
        let rendered = host(GoalongHealthImportSheet(gallery: .imported(try GalleryCatalog.galleryHealthImport(), message: nil)))
        let seen = strings(of: rendered)
        for label in ["Conserver sur ce Mac", "Exporter pour Goalong…", "Envoyer au site Goalong", "Choisir mon fichier de connexion…",
                      "J’autorise l’envoi de ces données Santé au site indiqué.", "Envoyer les données relues"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertEqual(isEnabled("Envoyer les données relues", in: rendered), false, "Nothing is sent without consent, address and access file")
        XCTAssertEqual(isEnabled("Conserver sur ce Mac", in: rendered), true)
        XCTAssertTrue(seen.contains { $0.contains("Journée") }, "The day picker of the preview (line 158); saw \(seen.sorted())")
        XCTAssertFalse(seen.contains("Oublier"), "No access file is chosen, so there is nothing to forget (line 203)")
        XCTAssertTrue(press("J’autorise l’envoi de ces données Santé au site indiqué.", in: rendered))
        settle()
        XCTAssertEqual(isEnabled("Envoyer les données relues", in: rendered), false, "Consent alone is not enough: the address field (line 200) and the access file are empty")
        assertNoVisibleWindow()
    }

    /// Click without a window: the accessibility action of the off-screen view, nothing is shown.
    @MainActor func testProfileStudioConversationSwitchRevealsTheConversationStartDate() {
        let rendered = host(GoalongProfileStudio(onSend: { _ in }, onClose: {}, localOnly: true, initialDay: day))
        let label = "Historique des conversations — utiliser les conversations IA comme contexte"
        XCTAssertFalse(strings(of: rendered).contains("Conversations actives depuis"))
        XCTAssertTrue(press(label, in: rendered), "The switch answers to the accessibility press; saw \(strings(of: rendered).sorted())")
        settle()
        XCTAssertTrue(strings(of: rendered).contains("Conversations actives depuis"), "Switching on shows the start date; saw \(strings(of: rendered).sorted())")
        assertNoVisibleWindow()
    }

    /// Click without a window: choosing nothing disables the preview (GoalongHealthImportSheet.swift:146).
    @MainActor func testHealthImportWithEveryGroupSwitchedOffCannotPrepareThePreview() {
        let rendered = host(GoalongHealthImportSheet(gallery: .failed("Ce fichier n’a pas pu être lu.")))
        for group in GoalongHealthGroup.allCases { XCTAssertTrue(press(group.title, in: rendered), "The switch for \(group.title) answers to the press") }
        settle()
        XCTAssertEqual(isEnabled("Préparer l’aperçu local", in: rendered), false, "Nothing is chosen, so nothing can be prepared; saw \(strings(of: rendered).sorted())")
        XCTAssertTrue(press(GoalongHealthGroup.allCases[0].title, in: rendered))
        settle()
        XCTAssertEqual(isEnabled("Préparer l’aperçu local", in: rendered), true, "One group is enough")
        assertNoVisibleWindow()
    }

    @MainActor func testWebsiteConnectionSheetWithoutAccessAsksToPairFromTheSite() {
        let rendered = host(GoalongWebsiteConnectionSheet())
        let seen = strings(of: rendered)
        for label in ["Relier votre compte Goalong", "1. Votre compte Goalong", "Relier depuis le site", "Connexion manuelle et options avancées",
                      "2. Choisir vos données", "3. Vérifier avant l’envoi", "Terminé", "Noms des applications et durées",
                      "Répartition par heure, si elle est enregistrée", "Sites observés sur ce Mac", "Résumé d’analyse enregistré",
                      "Rapport structuré de productivité", "Calculer le rythme à partir de l’historique de ce Mac", "Partage ponctuel avancé"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertFalse(seen.contains("Accès enregistré sur ce Mac"), "No access file is chosen")
        XCTAssertEqual(isEnabled("Envoyer les données vérifiées", in: rendered), false, "Nothing is sent without a preview, an address and an access file")
        XCTAssertEqual(isEnabled("Préparer l’aperçu hors ligne", in: rendered), true)
        XCTAssertEqual(isEnabled("Terminé", in: rendered), true, "Nothing is running, so the sheet can be closed")
    }

    @MainActor func testWebsiteConnectionSheetAdvancedOptionsOfferTheAccessFileAndThePastedPath() {
        let rendered = host(GoalongWebsiteConnectionSheet())
        XCTAssertTrue(press("Connexion manuelle et options avancées", in: rendered), "saw \(strings(of: rendered).sorted())")
        settle()
        var seen = strings(of: rendered)
        for label in ["Adresse et accès enregistrés", "Choisir le fichier d’accès…", "Autre méthode : coller le chemin du fichier", "Ouvrir « Sources » sur le site"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertFalse(seen.contains("Oublier le fichier"), "Nothing to forget without an access file")
        XCTAssertTrue(press("Autre méthode : coller le chemin du fichier", in: rendered), "saw \(seen.sorted())")
        settle()
        seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("Valider ce fichier"), "saw \(seen.sorted())")
        XCTAssertEqual(isEnabled("Valider ce fichier", in: rendered), false, "An empty path cannot be validated")
        assertNoVisibleWindow()
    }

    @MainActor func testWebsiteConnectionSheetSwitchesRevealTheirChoices() {
        let rendered = host(GoalongWebsiteConnectionSheet())
        XCTAssertFalse(strings(of: rendered).contains("Charger le récap de cette journée"), "The recap choices wait for the switch")
        XCTAssertTrue(press("Résumé d’analyse enregistré", in: rendered), "saw \(strings(of: rendered).sorted())")
        settle()
        var seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("Charger le récap de cette journée"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Produire ou actualiser avec mon agent"), "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains { $0.hasPrefix("Les mêmes durées deviennent un rapport modifiable") })
        XCTAssertTrue(press("Rapport structuré de productivité", in: rendered))
        settle()
        XCTAssertTrue(strings(of: rendered).contains { $0.hasPrefix("Les mêmes durées deviennent un rapport modifiable") }, "The note appears with the switch")
        XCTAssertFalse(seen.contains("Inclure l’heure de début précise"), "The rhythm choices wait for the switch")
        XCTAssertTrue(press("Calculer le rythme à partir de l’historique de ce Mac", in: rendered))
        settle()
        seen = strings(of: rendered)
        for label in ["Analyser le contexte d’une session…", "Inclure les épisodes simplifiés", "Inclure l’heure de début précise",
                      "Association simple par application, sans analyse du contexte"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertFalse(seen.contains("Inclure les sujets, explications et éléments de contexte relus"), "Context needs a reviewed session")
        assertNoVisibleWindow()
    }

    // MARK: Rendu

    private struct Node { let texts: Set<String>; let enabled: Bool; let object: NSObject }

    /// Renders off screen: a hosting view with no window, so nothing is shown and nothing takes the focus.
    @MainActor private func host(_ root: some View) -> NSView {
        let view = NSHostingView(rootView: root.environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 1600)
        view.layoutSubtreeIfNeeded()
        settle()
        return view
    }

    @MainActor private func assertNoVisibleWindow(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(NSApplication.shared.windows.filter(\.isVisible).isEmpty, "A press must not show a window", file: file, line: line)
    }

    @MainActor private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.35)) }

    /// Every identifier, label, title and string value of the AX tree, with the enabled state of each element.
    @MainActor private func nodes(of view: NSView) -> [Node] {
        var found: [Node] = [], pending: [Any] = [view], visited = Set<ObjectIdentifier>()
        while let value = pending.popLast(), visited.count < 20_000 {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            var texts = Set<String>()
            for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = read(object, name) as? String, !text.isEmpty { texts.insert(text) }
            }
            if !texts.isEmpty { found.append(Node(texts: texts, enabled: flag(object, "isAccessibilityEnabled") ?? true, object: object)) }
            pending.append(contentsOf: read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return found
    }

    @MainActor private func strings(of view: NSView) -> Set<String> { nodes(of: view).reduce(into: []) { $0.formUnion($1.texts) } }
    @MainActor private func accessible(_ root: some View) -> Set<String> { strings(of: host(root)) }

    /// Enabled state of the element with this label; nil when there is none. A label counts as enabled if any element carrying it is.
    @MainActor private func isEnabled(_ label: String, in view: NSView) -> Bool? {
        let matching = nodes(of: view).filter { $0.texts.contains(label) }
        return matching.isEmpty ? nil : matching.contains { $0.enabled }
    }

    /// Presses the first element with this label that answers to the accessibility press.
    @MainActor private func press(_ label: String, in view: NSView) -> Bool {
        let all = nodes(of: view).filter { $0.enabled }
        // A button built from several texts (a disclosure) carries a composed label: fall back to a label that contains this one.
        for node in all where node.texts.contains(label) { if flag(node.object, "accessibilityPerformPress") == true { return true } }
        for node in all where node.texts.contains(where: { $0.contains(label) }) { if flag(node.object, "accessibilityPerformPress") == true { return true } }
        return false
    }

    private func flag(_ object: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Getter.self)(object, selector)
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
}
#endif
