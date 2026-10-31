#if os(macOS)
import AppKit
import AgentActivity
import LocalHistoryCore
import LocalHistoryQueryCLI
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-046 C2a: views a test can render with the values their init takes (day, date, app row).
/// Each test hands the view its state, renders it off screen (no window, no focus) and checks what the member sees.
final class T046C2RenderTests: XCTestCase {
    private let day = Calendar.current.date(from: .init(year: 2026, month: 9, day: 18, hour: 12))!
    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private var enhancedUIBefore: Any?
    private var visibleWindowsBefore: Set<ObjectIdentifier> = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            visibleWindowsBefore = Set(NSApplication.shared.windows.filter(\.isVisible).map(ObjectIdentifier.init))
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

    private var calendar: Calendar { .current }

    @MainActor func testRhythmStudioOffersToPickAProjectAndPrepareTheSelectionButNotBeforeAProjectIsNamed() throws {
        var accepted = false
        let rendered = host(GoalongRhythmStudio(day: day, masks: ["Mail"]) { _ in accepted = true })
        let seen = strings(of: rendered)
        for label in ["Comprendre une session", "Fermer", "Début", "Fin",
                      "Inclure les textes de fenêtres déjà autorisés", "Préparer la sélection locale", "Utiliser cette session relue"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertEqual(isEnabled("Préparer la sélection locale", in: rendered), false, "No project is named yet")
        XCTAssertEqual(isEnabled("Utiliser cette session relue", in: rendered), false, "No result to accept yet")
        XCTAssertFalse(seen.contains("Contexte à analyser"), "Nothing is selected yet")
        XCTAssertTrue(press("Fermer", in: rendered))
        XCTAssertFalse(accepted, "Closing accepts nothing")
        assertNoVisibleWindow()
    }

    @MainActor func testDateControlStepsOneDayBackAndHidesTheStepForwardOnTodayAndOffersToday() throws {
        let earlier = calendar.date(byAdding: .day, value: -3, to: GoalongToday.now)!
        var chosen: [Date] = []
        let rendered = host(DateSelectionControl(date: earlier, onChange: { chosen.append($0) }))
        let seen = strings(of: rendered)
        for label in ["Jour précédent", "Jour suivant", "Choisir un jour", "Aujourd’hui"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertEqual(isEnabled("Jour suivant", in: rendered), true)
        XCTAssertTrue(press("Jour précédent", in: rendered))
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen.first.map { calendar.dateComponents([.day], from: $0, to: earlier).day }, 1, "One day back")
        XCTAssertTrue(press("Aujourd’hui", in: rendered))
        XCTAssertEqual(chosen.count, 2)

        let today = host(DateSelectionControl(date: GoalongToday.now, onChange: { _ in }))
        XCTAssertEqual(isEnabled("Jour suivant", in: today), false, "No day after today")
        XCTAssertFalse(strings(of: today).contains("Aujourd’hui"), "Already on today")
        assertNoVisibleWindow()
    }

    @MainActor func testDateControlStepsAWholePeriodAndShowsItsLabel() throws {
        var steps: [Int] = []
        var control = DateSelectionControl(date: day, onChange: { _ in })
        control.onStep = { steps.append($0) }
        control.dateLabel = "23 oct. – 29 oct."
        control.previousLabel = "Période précédente"
        let rendered = host(control)
        XCTAssertTrue(strings(of: rendered).contains("Période précédente"))
        XCTAssertTrue(press("Période précédente", in: rendered))
        XCTAssertEqual(steps, [-1])
        assertNoVisibleWindow()
    }

    @MainActor func testCalendarButtonNamesTheDayAndOpensTheCalendarOnPress() throws {
        let rendered = host(GoalongCalendarButton(date: day, onChange: { _ in }))
        XCTAssertTrue(strings(of: rendered).contains("Choisir un jour"))
        XCTAssertTrue(press("Choisir un jour", in: rendered))
        settle()
        assertNoVisibleWindow()
    }

    @MainActor func testApplicationRowWithDetailsButNoFieldSaysSoAndLetsTheMemberCustomizeThenGoBackToTheCommonSettings() throws {
        final class Box { var scope = GoalongAnalysisScope() }
        let box = Box()
        let binding = Binding(get: { box.scope }, set: { box.scope = $0 })
        let app = GoalongApplicationChoice(id: "com.apple.mail", name: "Mail")
        let rendered = host(GoalongAnalysisAppRow(app: app, scope: binding, excluded: false))
        var seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("Aucun détail activé"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Personnaliser"))
        XCTAssertTrue(press("Personnaliser", in: rendered))
        settle()
        seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("Masquer les options"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Utiliser les réglages communs"), "saw \(seen.sorted())")
        box.scope.perApplicationFields["com.apple.mail"] = ["windowTitles"]
        XCTAssertTrue(press("Utiliser les réglages communs", in: rendered))
        XCTAssertNil(box.scope.perApplicationFields["com.apple.mail"], "Back to the common settings")
        assertNoVisibleWindow()
    }

    // MARK: Conversations locales (runtime hors fenêtre, état installé par la couture DEBUG de la galerie)

    /// A runtime on a temporary folder: no tool folder is read, nothing is scanned, no hook is installed.
    @MainActor private func makeRuntime(_ state: GalleryCatalog.Conversations) throws -> AgentActivityRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t046-c2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let consentBefore = GoalongCapabilityConsentStore.shared.isEnabled(.aiConversations)
        addTeardownBlock { GoalongCapabilityConsentStore.shared.set(.aiConversations, enabled: consentBefore, surface: .settings) }
        let clockBefore = GoalongToday.galleryClock
        GoalongToday.galleryClock = { GalleryClock.now }
        addTeardownBlock { GoalongToday.galleryClock = clockBefore }
        let runtime = try AgentActivityRuntime(rootDirectory: root.appendingPathComponent("agents"),
            executableURL: URL(fileURLWithPath: "/nonexistent/goalong-c2"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, pauseRoot: root, onCaptured: { _ in })
        GalleryCatalog.installConversations(state, runtime: runtime)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root) }
        return runtime
    }

    @MainActor func testConversationsHistoryListsTheReadConversationsAndSaysWhenReadingOrAccessFails() throws {
        var checked = 0
        let filled = host(AgentActivityPage(agents: try makeRuntime(.filled), presentation: .history, onManageSources: { checked += 1 }))
        let seen = strings(of: filled)
        XCTAssertTrue(seen.contains("Tous les outils"), "saw \(seen.sorted())")
        let loading = strings(of: host(AgentActivityPage(agents: try makeRuntime(.loading), presentation: .history, onManageSources: {})))
        XCTAssertTrue(loading.contains("Lecture des conversations"), "saw \(loading.sorted())")
        let unreadable = host(AgentActivityPage(agents: try makeRuntime(.unreadable), presentation: .history, onManageSources: { checked += 1 }))
        XCTAssertTrue(strings(of: unreadable).contains("Conversations indisponibles"))
        XCTAssertTrue(press("Vérifier les sources", in: unreadable))
        XCTAssertEqual(checked, 1)
        _ = host(AgentActivityPage(agents: try makeRuntime(.partial), presentation: .history, onManageSources: {}))
        assertNoVisibleWindow()
    }

    @MainActor func testSourcesPageShowsTheWatchedFoldersAndTheIntegrationsOfARuntimeWithConversations() throws {
        for state in [GalleryCatalog.Conversations.filled, .unreadable, .partial, .loading] {
            let rendered = host(AgentActivityPage(agents: try makeRuntime(state), presentation: .management, onManageSources: {}))
            XCTAssertFalse(strings(of: rendered).isEmpty)
        }
        assertNoVisibleWindow()
    }

    /// These tests open no window: every view is hosted off screen, so no window is visible that was not before.
    @MainActor private func assertNoVisibleWindow(_ line: UInt = #line) {
        let added = NSApplication.shared.windows.filter { $0.isVisible && !visibleWindowsBefore.contains(ObjectIdentifier($0)) }
        XCTAssertTrue(added.isEmpty, "A window became visible: \(added.map(\.title))", line: line)
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
        for node in nodes(of: view) where node.texts.contains(label) && node.enabled {
            if flag(node.object, "accessibilityPerformPress") == true { return true }
        }
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
