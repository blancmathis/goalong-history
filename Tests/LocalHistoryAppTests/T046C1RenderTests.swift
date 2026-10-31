#if os(macOS)
import AppKit
import AgentActivity
import LocalHistoryCore
import LocalHistoryQueryCLI
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-046 C1: views whose state a test could not give before (analysis result, chosen apps, drafts, projects).
/// Each test hands the view its state, renders it off screen (no window, no focus) and checks what the member sees.
final class T046C1RenderTests: XCTestCase {
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

    // MARK: Analyser une demande du site

    private func siteRequest() throws -> GoalongSiteAnalysisRequest {
        try GoalongSiteAnalysisRequest.parse(JSONSerialization.data(withJSONObject: [
            "schema": "goalong.analysis-request.v1", "requestId": "11111111-2222-4333-8444-555555555555",
            "date": "2026-09-07", "timezone": "Europe/Paris", "question": "Explain only these selected observations.",
            "data": ["totals": [["device": "SELECTED_PHONE", "kind": "phone", "source": "apple-screen-time", "seconds": 3600]]],
        ], options: [.sortedKeys]))
    }

    @MainActor func testSiteAnalysisWithARequestAndADraftOffersToDisconnectReviewAnalyzeAndEdit() throws {
        let model = GoalongSiteAnalysisModel(consent: { true }, makeSession: { throw CodexAppServerError.executableUnavailable })
        model.setStateForTesting(request: try siteRequest(), connected: true, accountLabel: "Compte de démonstration",
                                 draft: (title: "Journée de démonstration", summary: "Une heure sur le téléphone.", outcomes: "Rien d’autre."))
        let rendered = host(GoalongSiteAnalysisSheet(model: model))
        let seen = strings(of: rendered)
        for label in ["Compte de démonstration", "Se déconnecter", "2026-09-07, Europe/Paris", "Analyser avec ChatGPT",
                      "J’autorise l’envoi des seules données affichées à ChatGPT pour cette analyse",
                      "3. Relisez votre brouillon", "Journée de démonstration"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertFalse(seen.contains("Se connecter à ChatGPT"), "A connected account only offers to disconnect")
        XCTAssertEqual(isEnabled("Analyser avec ChatGPT", in: rendered), false, "Nothing is sent before the member reviewed the data")
        XCTAssertFalse(seen.contains("Annuler l’opération"), "No operation runs")
        assertNoVisibleWindow()
    }

    @MainActor func testSiteAnalysisWhileBusyOffersToCancelAndCancelStopsIt() throws {
        let model = GoalongSiteAnalysisModel(consent: { true }, makeSession: { throw CodexAppServerError.executableUnavailable })
        model.setStateForTesting(request: try siteRequest(), busy: true)
        let rendered = host(GoalongSiteAnalysisSheet(model: model))
        let seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("Opération en cours…"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Se connecter à ChatGPT"), "Not connected: the sign-in is offered, held back while busy")
        XCTAssertEqual(isEnabled("Se connecter à ChatGPT", in: rendered), false)
        XCTAssertTrue(press("Annuler l’opération", in: rendered), "The cancel button answers to the accessibility press")
        settle()
        XCTAssertFalse(model.busy, "Cancelling ends the operation")
        XCTAssertFalse(strings(of: rendered).contains("Opération en cours…"), "saw \(strings(of: rendered).sorted())")
        assertNoVisibleWindow()
    }

    // MARK: Choix d’enregistrement

    @MainActor func testApplicationScopePickerOffersTheNativeChoiceAndKeepsAnErrorToShow() {
        for error in [nil, "Fixture refusée"] as [String?] {
            let rendered = host(ApplicationScopePickerButton(text: .constant("com.example.a"), error: error))
            XCTAssertEqual(isEnabled("Choisir des applications…", in: rendered), true, "error \(error ?? "none")")
        }
        assertNoVisibleWindow()
    }

    // MARK: Blocage

    @MainActor func testBlockListEditorShowsTheNameAndTheReasonOfTheList() {
        let list = BlockList(name: "Réseaux fixes", sites: [BlockSiteRule(pattern: "example.com")], reason: "Finir le mémoire avant vendredi")
        let controller = BlockingController(document: BlockingDocument(lists: [list]), clock: { self.day }, continuous: { self.day.timeIntervalSince1970 })
        let seen = accessible(BlockListEditor(controller: controller, list: list, now: day))
        XCTAssertTrue(seen.contains("blocking-list-name"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Réseaux fixes"), "The name field holds the name; saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Finir le mémoire avant vendredi"), "The reason field holds the reason; saw \(seen.sorted())")
        assertNoVisibleWindow()
    }

    @MainActor func testAppPickerListsTheGivenAppsWithoutScanningAndHidesTheExcludedOnes() {
        let apps = [BlockAppRule(bundleIdentifier: "com.example.mail", name: "Courrier fixe"),
                    BlockAppRule(bundleIdentifier: "com.example.notes", name: "Carnet fixe")]
        let seen = accessible(BlockingAppPicker(excluded: ["com.example.notes"], apps: apps) { _ in })
        XCTAssertTrue(seen.contains { $0.contains("Courrier fixe") }, "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains { $0.contains("Carnet fixe") }, "An app already in the list is not offered again")
        assertNoVisibleWindow()
    }

    @MainActor func testTheVeilOffersAnExtraBreakOnlyWhenEveryBreakIsTakenAndThePasswordGrantsOne() {
        func veil(breaksLeft: Int, extra: Bool) -> BlockingVeilPresentation {
            BlockingVeilPresentation(reason: .site("example.com"), listName: "Réseaux fixes",
                start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(3600), lock: .locked,
                breakMinutes: 5, breaksLeft: breaksLeft, feedback: nil, extraBreak: extra)
        }
        var asked = 0
        let rendered = host(BlockedSiteVeil(presentation: veil(breaksLeft: 0, extra: true), now: day, onBreak: { asked += 1 }))
        let seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("Pause supplémentaire…"), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Pauses du jour prises. Le mot de passe en accorde une de plus."))
        XCTAssertFalse(seen.contains("Pause de 5 min"))
        XCTAssertTrue(press("blocking-veil-extra-break", in: rendered), "The extra break answers to the accessibility press")
        XCTAssertEqual(asked, 1)
        let plain = strings(of: host(BlockedSiteVeil(presentation: veil(breaksLeft: 2, extra: false), now: day)))
        XCTAssertTrue(plain.contains("Pause de 5 min"), "saw \(plain.sorted())")
        XCTAssertFalse(plain.contains("Pause supplémentaire…"))
        assertNoVisibleWindow()
    }

    // MARK: Activité

    private func previewWeek() -> GoalongAnalyticsPayload {
        let selected = Calendar.current.date(from: .init(year: 2026, month: 9, day: 18))!
        return GoalongAnalyticsPreview.make(ending: selected, count: 7, calendar: Calendar.current, now: selected)
    }

    @MainActor func testActivityHeaderOffersTheReturnToThePeriodAfterOpeningADay() {
        let selected = Calendar.current.date(from: .init(year: 2026, month: 9, day: 18))!
        var navigation = GoalongActivityNavigation(day: selected, period: 7, now: selected)
        navigation.openDay(selected, now: selected)
        XCTAssertNotNil(navigation.returnContext)
        var returned = 0
        let rendered = host(GoalongActivityHeader(selection: navigation, isPreview: false, isRefreshing: false, onDay: { _ in },
            onPeriod: { _ in }, onStep: { _ in }, onToday: {}, onReturn: { returned += 1 }, onRefresh: {}, onShare: {}))
        let seen = strings(of: rendered)
        XCTAssertTrue(seen.contains { $0.hasPrefix("Retour aux") }, "saw \(seen.sorted())")
        XCTAssertTrue(press("Retour aux 7 jours", in: rendered), "The return answers to the accessibility press")
        XCTAssertEqual(returned, 1)
        let without = strings(of: host(GoalongActivityHeader(selection: GoalongActivityNavigation(day: selected, period: 7, now: selected),
            isPreview: false, isRefreshing: false, onDay: { _ in }, onPeriod: { _ in }, onStep: { _ in }, onToday: {},
            onReturn: {}, onRefresh: {}, onShare: {})))
        XCTAssertFalse(without.contains { $0.hasPrefix("Retour aux") }, "Without an opened day there is nothing to return to")
        assertNoVisibleWindow()
    }

    @MainActor func testCodeSectionAsksToEnableOrToChooseProjectsAndNothingOnceTheyAreFollowed() throws {
        let payload = previewWeek()
        let day = try XCTUnwrap(payload.current.days.last)
        var opened: [String] = []
        func render(_ code: GoalongCodeDay) -> NSView {
            host(GoalongCodeSection(code: code, day: day, onSettings: { opened.append("settings") }, onProjects: { opened.append("projects") }))
        }
        let off = render(GoalongCodeDay(followsProjects: false))
        XCTAssertTrue(strings(of: off).contains("Réglages…"), "saw \(strings(of: off).sorted())")
        XCTAssertTrue(press("Réglages…", in: off)); XCTAssertEqual(opened, ["settings"])
        let none = render(GoalongCodeDay(followsProjects: true, followedProjects: 0))
        XCTAssertTrue(strings(of: none).contains("Choisir les projets…"), "saw \(strings(of: none).sorted())")
        XCTAssertTrue(press("Choisir les projets…", in: none)); XCTAssertEqual(opened, ["settings", "projects"])
        let followed = strings(of: render(GoalongCodeDay(followsProjects: true, followedProjects: 2)))
        XCTAssertFalse(followed.contains("Réglages…") || followed.contains("Choisir les projets…"), "saw \(followed.sorted())")
        assertNoVisibleWindow()
    }

    @MainActor func testUsageDetailOffersToOpenEachDayInTheHistory() throws {
        let week = previewWeek()
        let item = try XCTUnwrap(GoalongActivityProjection.usage(week.current, grouping: .sites, previous: week.previous).first)
        var opened: [Date] = []
        let rendered = host(GoalongActivityUsageDetail(item: item, period: week.current, grouping: .sites, isPreview: false,
                                                       onHistoryDay: { opened.append($0) }))
        XCTAssertEqual(isEnabled("Voir cette journée dans l’historique", in: rendered), true, "saw \(strings(of: rendered).sorted())")
        XCTAssertTrue(press("Voir cette journée dans l’historique", in: rendered))
        XCTAssertEqual(opened.count, 1, "One press opens one day")
        let preview = host(GoalongActivityUsageDetail(item: item, period: week.current, grouping: .sites, isPreview: true, onHistoryDay: { _ in }))
        XCTAssertEqual(isEnabled("Voir cette journée dans l’historique", in: preview), false, "An example day cannot be opened")
        assertNoVisibleWindow()
    }

    // MARK: Réglages, partage, projets

    @MainActor func testSharingSheetOffersToDropChoicesOfOtherDaysAndDroppingKeepsTheVisibleOnes() async throws {
        let suite = "goalong-c1-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let catalog = Data(#"{"days":[{"telemetry":{"timezone":"Europe/Paris","devices":[{"id":"mac","name":"Mac","kind":"computer","screenSeconds":60,"apps":[{"id":"com.example.editor","name":"Editeur","seconds":60}]}],"websites":{"rows":[{"domain":"example.com","seconds":60}]}}}]}"#.utf8)
        let none: () -> (String) -> Bool = { { _ in false } }
        let noApp: () -> (String?, String) -> Bool = { { _, _ in false } }
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: root, sourceConsent: { _ in true }, hiddenWebsites: none, hiddenApplications: noApp)
        let model = GoalongWebsiteSharingModel(autoSender: sender, root: root,
            catalogLoader: { _, _, _ in try GoalongSiteSelectionCatalog(payload: catalog) },
            exporter: { _, _, _ in XCTFail("Rendering never exports"); return Data() },
            sender: { _, _, _, _ in XCTFail("Rendering never sends"); return Data() },
            sourceConsent: { _ in true }, hiddenWebsites: none, hiddenApplications: noApp, sharingRulesReadable: { true })
        await model.loadCatalog()
        model.draft.deviceIDs = ["mac"]
        model.draft.includeApplications = true
        model.draft.applicationIDs = ["com.example.editor", "com.example.other-day"]
        let rendered = host(GoalongWebsiteSharingSheet(model: model))
        let seen = strings(of: rendered)
        XCTAssertTrue(seen.contains("1 choix d’autres journées conservés"), "saw \(seen.sorted())")
        XCTAssertTrue(press("Retirer", in: rendered), "The drop button answers to the accessibility press")
        settle()
        XCTAssertEqual(model.draft.applicationIDs, ["com.example.editor"], "Only the choice absent from this day is dropped")
        XCTAssertFalse(strings(of: rendered).contains("1 choix d’autres journées conservés"))
        sender.forget()
        assertNoVisibleWindow()
    }

    @MainActor func testRetentionSheetAsksToConfirmTheDeletionOfExpiredProofsOnlyWhenTheyCanExpire() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-c1-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = HistoryRetentionStorage(policyFile: root.appendingPathComponent("policy.json"),
                                              activationFile: root.appendingPathComponent("activation.json"), artifactDirectories: [], prepare: {})
        let model = HistoryRetentionSettingsModel(store: HistoryRetentionStore(legacyRetentionDays: 30, storage: storage))
        let confirm = "J’autorise aussi la suppression des preuves et reçus expirés. La vérification de ces périodes peut devenir impossible."
        model.draft.setDuration(RetentionDuration(days: nil), for: .minuteSeals)
        model.draft.setDuration(RetentionDuration(days: nil), for: .anchorReceipts)
        model.automaticCleanup = true
        XCTAssertFalse(accessible(HistoryRetentionSettingsSheet(model: model)).contains(confirm), "Nothing expires, nothing to confirm")
        model.draft.setDuration(RetentionDuration(days: 90), for: .minuteSeals)
        let seen = accessible(HistoryRetentionSettingsSheet(model: model))
        XCTAssertTrue(seen.contains(confirm), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("retention-confirm-proofs"))
        model.automaticCleanup = false
        XCTAssertFalse(accessible(HistoryRetentionSettingsSheet(model: model)).contains(confirm), "Without automatic cleanup nothing is deleted")
        assertNoVisibleWindow()
    }

    @MainActor func testProjectsSheetShowsTheFollowedProjectsAndTheSuggestionsOfAGivenModelAndReadsNothingElse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-c1-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let consents = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json"))
        let model = GoalongDeveloperModel(root: root.appendingPathComponent("data"), consents: consents)
        let empty = accessible(GoalongDeveloperProjectsSheet(developer: model))
        XCTAssertTrue(empty.contains("Projets suivis"), "saw \(empty.sorted())")
        XCTAssertTrue(empty.contains("Aucun projet suivi."))
        XCTAssertFalse(empty.contains("Vus dans vos agents"))
        let followed = GoalongDeveloperProject(root: URL(fileURLWithPath: "/Users/demo/Projets/suivi-fixe"), name: "suivi-fixe")
        let seenProject = GoalongDeveloperProject(root: URL(fileURLWithPath: "/Users/demo/Projets/vu-fixe"), name: "vu-fixe")
        model.setSelectedProjectsForTesting([followed])
        let value = GoalongDeveloperDay(day: day, t3: T3CodeMetadataReader.read(day: day, enabled: false, shouldContinue: { true }),
            agents: GoalongAgentProjectGrouping.group(.init(day: day), t3: nil, enabled: false), git: [],
            files: .init(status: .noData, buckets: []), selectedProjects: [followed], suggestions: [seenProject], developerStatus: .noData)
        model.setValueForTesting(value)
        let rendered = host(GoalongDeveloperProjectsSheet(developer: model))
        let seen = strings(of: rendered)
        for label in ["suivi-fixe", "vu-fixe", "Vus dans vos agents", "Retirer", "Suivre", "Ajouter un dossier…", "OK", "developer-projects-sheet"] {
            XCTAssertTrue(seen.contains(label), "\(label); saw \(seen.sorted())")
        }
        XCTAssertFalse(seen.contains("Aucun projet suivi."))
        XCTAssertEqual(model.selectedProjects, [followed], "Showing the sheet changes nothing: the given model is not refreshed")
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
