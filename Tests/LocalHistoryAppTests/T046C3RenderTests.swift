#if os(macOS)
import AppKit
import AgentActivity
import LocalHistoryCore
import LocalHistoryQueryCLI
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-046 C3: controls shown only in one state (a Jev break, a disconnected ChatGPT account, the management of the
/// conversation sources, the Apple Screen Time details, a saved Health day). Each test puts the app in that state in the
/// throwaway HOME, renders the view off screen (no window, no focus) and checks what the member sees.
final class T046C3RenderTests: XCTestCase {
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

    /// The consent store, the Jev files and the Health archive live under the application-support folder:
    /// the test runners give it a throwaway HOME. Never the real one.
    private func requireThrowawayHome() throws {
        let path = AppPaths.applicationSupportDirectory.path
        let throwaway = path.hasPrefix(ProcessInfo.processInfo.environment["GOALONG_TEST_HOME"] ?? "/nonexistent")
            || path.contains("/tmp/") || path.contains("/var/folders/")
        guard throwaway else {
            let message = "The application-support folder must not be the real one: \(path)"
            XCTFail(message)
            throw XCTSkip(message)
        }
    }

    /// Sets a consent for this test only; the previous choice comes back at teardown.
    @MainActor private func consent(_ capability: GoalongCapability, _ enabled: Bool) {
        let store = GoalongCapabilityConsentStore.shared
        let before = store.isEnabled(capability)
        addTeardownBlock { _ = GoalongCapabilityConsentStore.shared.set(capability, enabled: before, surface: .settings) }
        XCTAssertTrue(store.set(capability, enabled: enabled, surface: .settings), "\(capability) not saved")
    }

    // MARK: Jev

    /// Jev off, no break: the privacy controls still offer the excerpt switch; the break group says nothing.
    @MainActor func testJevPrivacyControlsOfferTheExcerptSwitchAndNoBreakWhileMonitoringIsOff() throws {
        try requireThrowawayHome()
        let monitor = JevMonitor.shared
        consent(.jevMonitoring, false)
        addTeardownBlock { JevMonitor.shared.endBreak() }
        monitor.endBreak()
        let seen = strings(of: host(JevPrivacyControls()))
        XCTAssertTrue(seen.contains("Joindre un bref extrait du texte affiché"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Voir le dernier contenu envoyé (sans la clé)"), "saw \(seen.sorted())")
        let breaks = strings(of: host(VStack { JevBreakControls(); Text("fin") }))
        XCTAssertFalse(breaks.contains("Faire une pause"), "Nothing to pause; saw \(breaks.sorted())")
        assertNoVisibleWindow()
    }

    /// An unreadable break file suspends monitoring: the break group offers to reset it, the page shows the error
    /// with « Réessayer », and resetting clears both.
    @MainActor func testUnreadableBreakFileOffersResetAndRetryAndResettingClearsIt() throws {
        try requireThrowawayHome()
        let monitor = JevMonitor.shared
        consent(.jevMonitoring, false)
        addTeardownBlock { JevMonitor.shared.endBreak() }
        try JevLocalFiles.write(Data("{".utf8), name: "break.json")
        monitor.retry()
        XCTAssertTrue(monitor.breakStorageInvalid)
        let breaks = host(JevBreakControls())
        var seen = strings(of: breaks)
        XCTAssertTrue(seen.contains(JevMonitor.unreadableBreakNotice), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Réinitialiser la pause"), "saw \(seen.sorted())")
        let page = strings(of: host(JevMonitoringPage(onOpenRecording: {})))
        XCTAssertTrue(page.contains("jev-retry") || page.contains("Réessayer"), "The error offers a retry; saw \(page.sorted())")
        XCTAssertTrue(press("Réinitialiser la pause", in: breaks))
        XCTAssertFalse(monitor.breakStorageInvalid, "The reset removes the unreadable file")
        XCTAssertNil(monitor.timedBreak)
        XCTAssertNil(try JevLocalFiles.read("break.json"))
        spin(until: { !strings(of: breaks).contains("Réinitialiser la pause") })
        seen = strings(of: breaks)
        XCTAssertFalse(seen.contains(JevMonitor.unreadableBreakNotice), "saw \(seen.sorted())")
        assertNoVisibleWindow()
    }

    /// Jev on: the group and the menu offer the durations; a break shows its countdown and « Reprendre la
    /// surveillance » in both, and resuming ends it.
    @MainActor func testJevOnOffersBreakDurationsAndARunningBreakOffersToResumeInTheGroupAndTheMenu() throws {
        try requireThrowawayHome()
        let monitor = JevMonitor.shared
        consent(.jevMonitoring, true)
        addTeardownBlock { JevMonitor.shared.endBreak() }
        monitor.endBreak()
        XCTAssertTrue(monitor.enabled)

        let menu = NSMenu()
        JevMenuController.shared.menuNeedsUpdate(menu)
        var titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Pause de 5 min (historique inchangé)"), "saw \(titles)")
        XCTAssertTrue(titles.contains("Désactiver la surveillance"), "saw \(titles)")
        XCTAssertFalse(titles.contains("Reprendre la surveillance"), "No break yet; saw \(titles)")

        let quick = strings(of: host(JevQuickPauseControl()))
        XCTAssertTrue(quick.contains("jev-quick-pause"), "saw \(quick.sorted())")

        let breaks = host(JevBreakControls())
        var seen = strings(of: breaks)
        for label in ["Faire une pause", "5 min", "10 min", "15 min", "30 min", "Autre durée"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertTrue(press("10 min", in: breaks))
        XCTAssertNotNil(monitor.timedBreak, "Pressing a duration starts the break")
        spin(until: { strings(of: breaks).contains("jev-end-break") })
        seen = strings(of: breaks)
        XCTAssertTrue(seen.contains("Reprendre la surveillance"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("jev-break-countdown"), "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains("5 min"), "No new break during a break; saw \(seen.sorted())")

        JevMenuController.shared.menuNeedsUpdate(menu)
        titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Reprendre la surveillance"), "saw \(titles)")
        XCTAssertTrue(titles.contains { $0.hasPrefix("Surveillance en pause : ") && $0.hasSuffix(" restantes") }, "saw \(titles)")
        XCTAssertFalse(titles.contains("Pause de 5 min (historique inchangé)"), "saw \(titles)")

        let quickBreak = strings(of: host(JevQuickPauseControl()))
        XCTAssertTrue(quickBreak.contains { $0.hasPrefix("Pause, ") }, "The quick control shows the countdown; saw \(quickBreak.sorted())")

        XCTAssertTrue(press("Reprendre la surveillance", in: breaks))
        XCTAssertNil(monitor.timedBreak, "Resuming ends the break")
        XCTAssertNil(try JevLocalFiles.read("break.json"), "No break file is left")
        assertNoVisibleWindow()
    }

    // MARK: ChatGPT

    /// Signed out: the card offers « Connecter ChatGPT », enabled, and says the connection alone analyses nothing.
    @MainActor func testChatGPTCardSignedOutOffersToConnect() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("t046-c3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        let runtime = ChatGPTRecapRuntime(
            chatHistoryStore: ChatGPTHistoryStore(rootDirectory: container.appendingPathComponent("history", isDirectory: true)),
            recapsDirectory: container.appendingPathComponent("recaps", isDirectory: true),
            executableLocator: { nil },
            sessionFactory: { _ in throw NSError(domain: "T046C3RenderTests", code: 1) },
            directoryOpener: { _ in }, fileRevealer: { _ in },
            delayedAutomaticScheduler: { _ in }, automaticRetryScheduler: { _, _ in },
            analysisConsentProvider: { true },
            dayOverviewReader: { _ in throw CodexAppServerError.generationFailed("journée de test") })
        let card = host(ChatGPTAccountConnectionCard(runtime: runtime))
        // The card checks the account when it appears; with no Codex tool that ends at once, then the state is set.
        runtime.setConnectionStateForTesting(.signedOut)
        spin(until: { strings(of: card).contains("Connecter ChatGPT") })
        let seen = strings(of: card)
        XCTAssertTrue(seen.contains("Non connecté"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("La connexion seule ne lance aucune analyse."), "saw \(seen.sorted())")
        XCTAssertEqual(isEnabled("Connecter ChatGPT", in: card), true)
        XCTAssertFalse(seen.contains("Annuler"), "Nothing to cancel; saw \(seen.sorted())")
        assertNoVisibleWindow()
    }

    // MARK: Sources des conversations

    /// The management page offers the scan, the signals folder and, for each watched folder, open, edit and remove.
    @MainActor func testSourcesManagementOffersTheScanTheSignalsFolderAndTheFolderActions() throws {
        let runtime = try makeRuntime(.filled)
        let seen = strings(of: host(AgentActivityPage(agents: runtime, presentation: .management, onManageSources: {})))
        XCTAssertTrue(seen.contains("Détection immédiate (facultatif)"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Afficher le dossier"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains { $0.hasSuffix("Sources lisibles") }, "saw \(seen.sorted())")
        assertNoVisibleWindow()
    }

    @MainActor private func makeRuntime(_ state: GalleryCatalog.Conversations) throws -> AgentActivityRuntime {
        try requireThrowawayHome()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t046-c3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        consent(.aiConversations, true)
        let clockBefore = GoalongToday.galleryClock
        GoalongToday.galleryClock = { GalleryClock.now }
        addTeardownBlock { GoalongToday.galleryClock = clockBefore }
        let runtime = try AgentActivityRuntime(rootDirectory: root.appendingPathComponent("agents"),
            executableURL: URL(fileURLWithPath: "/nonexistent/goalong-c3"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, pauseRoot: root, onCaptured: { _ in })
        GalleryCatalog.installConversations(state, runtime: runtime)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root) }
        return runtime
    }

    // MARK: Temps d’écran Apple

    /// A day read from Apple: the details, opened, offer the export detail and, in the technical diagnostic, the macOS
    /// permissions check.
    @MainActor func testScreenTimeDetailsOfferTheExportDetailAndThePermissionsCheck() throws {
        try requireThrowawayHome()
        let entry = try XCTUnwrap(GalleryCatalog.all.first { $0.id == "temps-ecran/importe" })
        try GalleryRenderer.withPreparedApplication {
            let ctx = GalleryContext()
            defer { ctx.finish() }
            try GalleryStateReset.all(home: ctx.home, resetData: false)
            let page = host(try entry.view(ctx))
            spin(until: { entry.ready?(ctx) ?? true }, timeout: 10)
            spin(until: { strings(of: page).contains("Source, confidentialité et export") })
            XCTAssertFalse(strings(of: page).contains("Détail de l’export"), "Closed at first")
            XCTAssertTrue(press("Source, confidentialité et export", in: page))
            spin(until: { strings(of: page).contains("Diagnostic technique") })
            var seen = strings(of: page)
            XCTAssertTrue(seen.contains("Détail de l’export"), "saw \(seen.sorted())")
            XCTAssertTrue(seen.contains("Exporter un fichier…"), "saw \(seen.sorted())")
            XCTAssertTrue(press("Diagnostic technique", in: page))
            spin(until: { strings(of: page).contains("Vérifier les autorisations macOS…") })
            seen = strings(of: page)
            XCTAssertTrue(seen.contains { $0.hasPrefix("AppUsage : ") }, "saw \(seen.sorted())")
        }
        assertNoVisibleWindow()
    }

    // MARK: Santé

    /// A Health day already saved on this Mac: the import sheet offers to show it or put it in the trash.
    @MainActor func testHealthImportSheetOffersTheDaysAlreadySavedOnThisMac() throws {
        try requireThrowawayHome()
        let root = AppPaths.applicationSupportDirectory
        let health = root.appendingPathComponent("health", isDirectory: true)
        XCTAssertTrue((try? GoalongHealthArchive.dates(root: root))?.isEmpty ?? true, "No saved day before the test")
        addTeardownBlock { try? FileManager.default.removeItem(at: health) }
        try GoalongHealthArchive.save(try GalleryCatalog.galleryHealthImport(), root: root)
        let sheet = host(GoalongHealthImportSheet())
        spin(until: { strings(of: sheet).contains("Mettre à la corbeille") })
        let seen = strings(of: sheet)
        XCTAssertTrue(seen.contains("Déjà sur ce Mac"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Afficher"), "saw \(seen.sorted())")
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
        // The conversations page first shows « Vérification des accès… » while it checks the sources.
        spin(until: { let seen = strings(of: view); return !seen.isEmpty && !seen.contains("source-access-page-loading") })
        return view
    }

    /// Runs the run loop in 10 ms steps until `condition` holds; fails after `timeout` seconds.
    @MainActor private func spin(until condition: () -> Bool, timeout: TimeInterval = 5, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Condition not met within \(timeout) s", line: line) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

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
