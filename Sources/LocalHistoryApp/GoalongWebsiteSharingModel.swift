#if os(macOS)
import Foundation
import Combine
import LocalHistoryCore
import LocalHistoryQueryCLI

struct GoalongWebsiteShareDraft: Equatable, Codable {
    enum Delivery: String, CaseIterable, Codable { case once, daily }
    var delivery: Delivery = .once
    var date = Calendar.current.date(byAdding: .day, value: -1, to: GoalongToday.now) ?? GoalongToday.now
    var deviceIDs = Set<String>()
    var applicationIDs = Set<String>()
    var anonymousApplicationIDs = Set<String>()
    var websiteDomains = Set<String>()
    var includeApplications = true
    var includeHourly = false
    var includeWebsites = false
    var includeDeviceNames = false
    var hour = 9
    var minute = 0
    var timezone = TimeZone.current.identifier

    var day: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    var options: GoalongSiteExportOptions {
        .init(deviceIDs: deviceIDs.sorted(), includeApplications: includeApplications,
              includeHourly: false, includeWebsites: includeWebsites,
              maskedApplications: anonymousApplicationIDs.intersection(applicationIDs).sorted(),
              selectedApplicationIDs: applicationIDs.sorted(), selectedWebsiteDomains: websiteDomains.sorted(),
              includeDeviceNames: includeDeviceNames, strictSelection: true)
    }
    var validationMessage: String? {
        if deviceIDs.isEmpty { return "Sélectionnez au moins un appareil." }
        if deviceIDs.count > 12 { return "Sélectionnez au maximum douze appareils." }
        // An empty optional group must not block a different, explicitly selected group.
        // Empty allow-lists remain empty in the payload; they never mean “allow all”.
        let selectedApps = includeApplications && !applicationIDs.isEmpty
        let selectedSites = includeWebsites && !websiteDomains.isEmpty
        if !selectedApps && !selectedSites { return "Sélectionnez au moins une application ou un site." }
        return nil
    }
}

/// The preview owns immutable bytes, a destination and a credential fingerprint.
/// Editing a choice invalidates it and pauses the previously approved daily plan.
@MainActor final class GoalongWebsiteSharingModel: ObservableObject {
    struct Preview {
        let payload: Data
        let draft: GoalongWebsiteShareDraft
        let origin: String
        let tokenPath: String
        let credentialFingerprint: String
        let createdAt: Date
        var privacyRevision: String = "none"
        var pauseRevision: String = "initial"
        var transmittedCounts: (devices: Int, applications: Int, websites: Int) {
            guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let day = (value["days"] as? [[String: Any]])?.first,
                  let telemetry = day["telemetry"] as? [String: Any] else { return (0, 0, 0) }
            let rows = telemetry["devices"] as? [[String: Any]] ?? []
            let apps = rows.reduce(0) { $0 + (($1["apps"] as? [Any])?.count ?? 0) }
            let websites = ((telemetry["websites"] as? [String: Any])?["rows"] as? [Any])?.count ?? 0
            return (rows.count, apps, websites)
        }
    }
    @Published var draft = GoalongWebsiteShareDraft() {
        didSet {
            guard draft != oldValue else { return }
            if !configuringPresentation {
                if draft.deviceIDs != oldValue.deviceIDs || draft.applicationIDs != oldValue.applicationIDs
                    || draft.includeApplications != oldValue.includeApplications { userChangedSelection = true }
                if draft.websiteDomains != oldValue.websiteDomains { needsWebsiteSuggestion = false }
            }
            invalidate()
            // Browsing another sample day only changes the preview; it does not change what the plan sends.
            var samePlanOldValue = oldValue; samePlanOldValue.date = draft.date
            if !configuringPresentation && oldValue.delivery == .daily && autoSender.enabled && samePlanOldValue != draft { autoSender.stop(); status = "Synchronisation mise en pause pendant la modification. Relisez puis confirmez vos nouveaux choix." }
        }
    }
    @Published private(set) var catalog: GoalongSiteSelectionCatalog?
    @Published private(set) var preview: Preview?
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published var reviewed = false
    @Published var error: String?
    @Published var status: String?
    private var generation = UUID()
    private var configuringPresentation = false
    private var needsInitialSuggestion = true
    private var userChangedSelection = false
    private var needsWebsiteSuggestion = true
    let autoSender: GoalongWebsiteAutoSender
    private let hiddenWebsites: () -> (String) -> Bool
    private let hiddenApplications: () -> (String?, String) -> Bool
    private let sharingRulesReadable: () -> Bool
    /// The `includeWebsites` value the catalog on screen was loaded with. The model's own
    /// fallback change must not trigger another load that would erase its explanation.
    private var loadedIncludeWebsites: Bool?
    private let root: URL
    private let catalogLoader: (URL, String, Bool) throws -> GoalongSiteSelectionCatalog
    private let exporter: (URL, String, GoalongSiteExportOptions) throws -> Data
    private let sender: ((Data, String, URL, String) throws -> Data)?
    private let sourceConsent: @MainActor (GoalongSiteExportOptions) -> Bool

    init(autoSender: GoalongWebsiteAutoSender? = nil, root: URL = AppPaths.applicationSupportDirectory,
         catalogLoader: @escaping (URL, String, Bool) throws -> GoalongSiteSelectionCatalog = { try GoalongQueryCLI.siteSelectionCatalog(rootDirectory: $0, day: $1, includeWebsites: $2) },
         exporter: @escaping (URL, String, GoalongSiteExportOptions) throws -> Data = { try GoalongQueryCLI.siteExportPayload(rootDirectory: $0, day: $1, options: $2) },
         sender: ((Data, String, URL, String) throws -> Data)? = nil,
         sourceConsent: @escaping @MainActor (GoalongSiteExportOptions) -> Bool = { GoalongWebsiteAutoSender.sourcesAllowed($0) },
         hiddenWebsites: @escaping () -> (String) -> Bool = { SharingRulesStore().hiddenWebsiteFilter() },
         hiddenApplications: @escaping () -> (String?, String) -> Bool = { SharingRulesStore().hiddenApplicationFilter() },
         sharingRulesReadable: @escaping () -> Bool = { !SharingRulesStore().isDamaged }) {
        self.sharingRulesReadable = sharingRulesReadable
        self.hiddenWebsites = hiddenWebsites
        self.hiddenApplications = hiddenApplications
        let autoSender = autoSender ?? .shared
        self.autoSender = autoSender; self.root = root; self.catalogLoader = catalogLoader
        self.exporter = exporter; self.sender = sender; self.sourceConsent = sourceConsent
        if let saved = autoSender.savedConfiguration, [2, 3].contains(saved.policyVersion ?? 0) {
            var restored = GoalongWebsiteShareDraft()
            restored.delivery = .daily
            restored.deviceIDs = Set(saved.options.deviceIDs)
            restored.applicationIDs = Set(saved.options.selectedApplicationIDs ?? [])
            restored.anonymousApplicationIDs = Set(saved.options.maskedApplications)
            restored.websiteDomains = Set(saved.options.selectedWebsiteDomains ?? [])
            restored.includeApplications = saved.options.includeApplications
            restored.includeHourly = saved.options.includeHourly
            restored.includeWebsites = saved.options.includeWebsites
            restored.includeDeviceNames = saved.options.includeDeviceNames ?? false
            restored.hour = saved.hour ?? 9; restored.minute = saved.minute ?? 0
            restored.timezone = saved.timeZoneIdentifier ?? TimeZone.current.identifier
            draft = restored
            needsInitialSuggestion = false; needsWebsiteSuggestion = false
        } else if root.standardizedFileURL == AppPaths.applicationSupportDirectory.standardizedFileURL,
                  let remembered = Self.rememberedSelection(in: root) {
            draft = remembered; draft.delivery = .once; draft.date = GoalongToday.now
            needsInitialSuggestion = false; needsWebsiteSuggestion = false
        }
        userChangedSelection = false
    }
    /// Opening a one-off send never edits or pauses the approved daily plan.
    func presentSingleDay(_ day: Date) {
        configuringPresentation = true
        defer { configuringPresentation = false }
        draft.delivery = .once
        draft.date = day
    }
    private struct Remembered: Codable { let account: String; let draft: GoalongWebsiteShareDraft }
    private static var accountKey: String {
        SHA256Digest.hashHex((UserDefaults.standard.string(forKey: "goalong.website.origin") ?? "") + "|" +
            (UserDefaults.standard.string(forKey: "goalong.website.accountID") ?? ""))
    }
    private static func rememberedSelection(in root: URL) -> GoalongWebsiteShareDraft? {
        let file = root.appendingPathComponent("website-selection.json")
        guard let data = try? Data(contentsOf: file), data.count < 262144,
              let value = try? JSONDecoder().decode(Remembered.self, from: data), value.account == accountKey else { return nil }
        return value.draft
    }
    private func rememberSelection() {
        guard root.standardizedFileURL == AppPaths.applicationSupportDirectory.standardizedFileURL else { return }
        let file = root.appendingPathComponent("website-selection.json")
        do {
            try JSONEncoder().encode(Remembered(account: Self.accountKey, draft: draft)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Delivery succeeded; failure to remember must not duplicate a send. */ }
    }
    private func readableError(_ error: Error) -> String {
        let message = String(describing: error)
        if message.contains("Apple Screen Time is off") { return "Activez Temps d’écran Apple dans Enregistrement pour lire les données à envoyer." }
        if message.contains("No saved Screen Time") { return "Aucune donnée Apple enregistrée pour cette journée. Choisissez une autre date ou actualisez l’historique." }
        if message.contains("Computer History is off") { return "Activez l’historique de ce Mac pour inclure les sites, ou désactivez Sites web." }
        if message.contains("Website details are unavailable") { return "Les sites ne sont pas disponibles pour cette date. Les applications restent utilisables sans les sites." }
        return "Lecture locale indisponible : " + goalongUserMessage(error)
    }
    var selectionHint: String? {
        if loading { return "Lecture de la journée…" }
        if catalog == nil { return "Aucune journée disponible. Actualisez ou choisissez une autre date." }
        return draft.validationMessage
    }
    func invalidate() { preview = nil; reviewed = false; error = nil; status = nil }
    func connectionChanged() { generation = UUID(); invalidate(); autoSender.stop() }
    func cancelPreparation() { generation = UUID(); loading = false; invalidate() }
    /// Called when `draft.includeWebsites` changes. A change the model made itself (fallback) reloads nothing.
    func includeWebsitesChanged() async {
        if loadedIncludeWebsites == draft.includeWebsites { return }
        await loadCatalog()
    }

    func loadCatalog() async {
        guard !GoalongGlobalPause.isPaused(in: root) else { error = "Pause globale : lecture suspendue."; return }
        let ticket = UUID(); generation = ticket
        let snapshot = draft, root = root, loader = catalogLoader
        loading = true; error = nil
        // Previously selected IDs are kept, never expanded by newly discovered rows.
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try loader(root, snapshot.day, snapshot.includeWebsites) }.value
            guard generation == ticket, draft.day == snapshot.day, draft.includeWebsites == snapshot.includeWebsites else { return }
            // Sites and applications hidden in every share are neither listed nor preselected.
            let hiddenSite = hiddenWebsites(), hiddenApp = hiddenApplications()
            let value = loaded.removingWebsites(where: hiddenSite).removingApplications(where: { hiddenApp($0, $1) })
            catalog = value
            loadedIncludeWebsites = snapshot.includeWebsites
            configuringPresentation = true
            defer { configuringPresentation = false }
            // A restored plan can still list subjects hidden since: drop them so the draft matches what is visible.
            let visibleApps = Set(value.devices.flatMap { $0.applications.map(\.id) })
            let allApps = Set(loaded.devices.flatMap { $0.applications.map(\.id) })
            let prunedSites = draft.websiteDomains.filter { !hiddenSite($0) }
            let prunedApps = draft.applicationIDs.filter { visibleApps.contains($0) || (!allApps.contains($0) && !hiddenApp($0, $0)) }
            if prunedSites != draft.websiteDomains { draft.websiteDomains = prunedSites }
            if prunedApps != draft.applicationIDs { draft.applicationIDs = prunedApps }
            if needsInitialSuggestion && !userChangedSelection {
                draft.deviceIDs = Set(value.devices.prefix(12).map(\.id))
                draft.includeApplications = true
                draft.applicationIDs = Set(value.devices.filter { draft.deviceIDs.contains($0.id) }.flatMap { $0.applications.map(\.id) })
                // Keep the selected calendar date when its archive uses another zone.
                let dateParser = DateFormatter()
                dateParser.calendar = Calendar(identifier: .gregorian)
                dateParser.locale = Locale(identifier: "en_US_POSIX")
                dateParser.dateFormat = "yyyy-MM-dd"
                dateParser.timeZone = TimeZone(identifier: value.timezone)
                let sameCalendarDate = dateParser.date(from: snapshot.day)
                draft.timezone = value.timezone
                if let sameCalendarDate { draft.date = sameCalendarDate }
                needsInitialSuggestion = false
            }
            if snapshot.includeWebsites && needsWebsiteSuggestion && draft.websiteDomains.isEmpty && !value.websites.isEmpty {
                draft.websiteDomains = Set(value.websites.prefix(200).map(\.domain))
                needsWebsiteSuggestion = false
            }
        } catch {
            guard generation == ticket else { return }
            if snapshot.includeWebsites, let fallback = try? await Task.detached(priority: .userInitiated, operation: { try loader(root, snapshot.day, false) }).value {
                guard generation == ticket else { return }
                catalog = fallback.removingApplications(where: { hiddenApplications()($0, $1) })
                loadedIncludeWebsites = false
                configuringPresentation = true
                draft.includeWebsites = false
                configuringPresentation = false
                self.error = readableError(error)
            } else {
                catalog = nil
                self.error = readableError(error)
            }
        }
        if generation == ticket { loading = false }
    }
    func prepare(origin: String, tokenPath: String) async {
        guard !busy, !loading else { return }
        invalidate()
        if let message = draft.validationMessage { error = message; return }
        guard let catalog, draft.deviceIDs.isSubset(of: Set(catalog.devices.map(\.id))) else {
            error = "Un appareil choisi n’est pas disponible pour cette journée. Actualisez ou ajustez la sélection."; return
        }
        let snapshot = draft, target = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticket = UUID(); generation = ticket
        guard sharingRulesReadable() else {
            error = "Les règles de partage sont illisibles. Vérifiez-les dans les réglages avant de préparer l’aperçu."; return
        }
        let hiddenApp = hiddenApplications()
        let catalogNames = Dictionary(catalog.devices.flatMap { $0.applications }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var options = GoalongWebsiteAutoSender.removingHiddenWebsites(snapshot.options, isHidden: hiddenWebsites(),
                                                                       isApplicationHidden: hiddenApp)
        // The catalog also knows the display names, so a rule keyed on the name still applies.
        options.selectedApplicationIDs = options.selectedApplicationIDs?.filter { !hiddenApp($0, catalogNames[$0] ?? $0) }
        if GoalongWebsiteAutoSender.selectsNothing(options) { error = GoalongWebsiteAutoSender.nothingSelectedMessage; return }
        if snapshot.delivery == .daily && catalog.timezone != snapshot.timezone {
            error = "Le fuseau du planning ne correspond pas à cette journée. Choisissez une journée enregistrée dans le fuseau courant avant d’activer la synchronisation."
            return
        }
        guard sourceConsent(options) else { error = "Une source choisie est désactivée. Vérifiez les réglages avant de préparer l’aperçu."; return }
        busy = true
        defer { busy = false }
        let root = root, exporter = exporter
        let privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        let pause = GoalongGlobalPause.load(in: root)
        do {
            try GoalongGlobalPause.revalidate(pause.revision, in: root)
            if !target.isEmpty { _ = try GoalongSiteSubmission.endpoint(origin: target) }
            let fingerprint: String
            if !target.isEmpty && !tokenPath.isEmpty,
               let token = try? GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath)) {
                fingerprint = SHA256Digest.hashHex(Data(token.utf8))
            } else { fingerprint = "" }
            let bytes = try await Task.detached(priority: .userInitiated) { try exporter(root, snapshot.day, options) }.value
            try GoalongGlobalPause.revalidate(pause.revision, in: root)
            _ = try GoalongReadableShareData(payload: bytes)
            guard generation == ticket, draft == snapshot, sourceConsent(options),
                  GoalongPrivacyPolicy.load(in: root).revision == privacyRevision else {
                error = "Les choix ou les autorisations ont changé. Préparez un nouvel aperçu."; return
            }
            preview = Preview(payload: bytes, draft: snapshot, origin: target, tokenPath: tokenPath,
                              credentialFingerprint: fingerprint, createdAt: Date(), privacyRevision: privacyRevision, pauseRevision: pause.revision)
        } catch { self.error = "Aperçu non préparé : \(goalongUserMessage(error))" }
    }
    func confirm(origin: String, tokenPath: String) async {
        guard !busy, reviewed, let approved = preview else { return }
        guard !approved.origin.isEmpty, !approved.tokenPath.isEmpty, !approved.credentialFingerprint.isEmpty else {
            error = "Reliez votre compte Goalong, puis vérifiez à nouveau l’aperçu avant d’envoyer."; return
        }
        guard approved.draft == draft, approved.origin == origin.trimmingCharacters(in: .whitespacesAndNewlines),
              approved.tokenPath == tokenPath, Date().timeIntervalSince(approved.createdAt) >= 0, Date().timeIntervalSince(approved.createdAt) <= 900,
              sourceConsent(approved.draft.options),
              GoalongPrivacyPolicy.load(in: root).revision == approved.privacyRevision else {
            invalidate(); error = "L’aperçu ou les autorisations ont changé. Préparez un nouvel aperçu avant l’envoi."; return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            try GoalongGlobalPause.revalidate(approved.pauseRevision, in: root)
            let token = try GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath))
            guard SHA256Digest.hashHex(Data(token.utf8)) == approved.credentialFingerprint else {
                throw GoalongSiteExportError.invalid("L’accès au compte a changé depuis l’aperçu. Reliez le compte et relisez la sélection.")
            }
            if draft.delivery == .daily {
                try autoSender.enable(origin: approved.origin, tokenPath: approved.tokenPath, options: approved.draft.options,
                                      hour: draft.hour, minute: draft.minute, timeZoneIdentifier: draft.timezone)
                preview = nil; reviewed = false
                rememberSelection()
                status = "Synchronisation activée. Seules les données autorisées de la veille seront envoyées, lorsque l’app est ouverte."
            } else {
                let sender = sender, root = root
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try GoalongGlobalPause.revalidate(approved.pauseRevision, in: root)
                    _ = try GoalongOutgoingPrivacy.validate(approved.payload, root: root, expectedRevision: approved.privacyRevision)
                    if let sender { return try sender(approved.payload, approved.origin, URL(fileURLWithPath: approved.tokenPath), approved.credentialFingerprint) }
                    return try GoalongSiteSubmission.send(payload: approved.payload, origin: approved.origin,
                        tokenFile: URL(fileURLWithPath: approved.tokenPath), expectedTokenFingerprint: approved.credentialFingerprint,
                        privacyRoot: root, expectedPrivacyRevision: approved.privacyRevision)
                }.value
                let object = try JSONSerialization.jsonObject(with: receipt) as? [String: Any] ?? [:]
                preview = nil; reviewed = false
                rememberSelection()
                func count(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
                status = "Reçu par Goalong : \(FrenchCount.count(count("imported"), "ajout", "ajouts")), \(FrenchCount.count(count("updated"), "mise à jour", "mises à jour")), \(FrenchCount.count(count("skipped"), "inchangé", "inchangés")). Aucun envoi quotidien n’a été activé."
            }
        } catch {
            if case GoalongSiteSubmissionError.accessRefused = error {
                autoSender.markAccessRefused(fingerprint: approved.credentialFingerprint)
                NotificationCenter.default.post(name: .goalongWebsiteAccessRefused, object: nil)
            }
            self.error = "Envoi non confirmé : \(goalongUserMessage(error))"
        }
    }
}
#endif
