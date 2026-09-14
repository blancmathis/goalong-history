#if os(macOS)
import Foundation
import Combine
import LocalHistoryCore
import LocalHistoryQueryCLI

struct GoalongWebsiteShareDraft: Equatable {
    enum Delivery: String, CaseIterable { case once, daily }
    var delivery: Delivery = .once
    var date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    var deviceIDs = Set<String>()
    var applicationIDs = Set<String>()
    var websiteDomains = Set<String>()
    var includeApplications = false
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
              includeHourly: includeHourly, includeWebsites: includeWebsites,
              selectedApplicationIDs: applicationIDs.sorted(), selectedWebsiteDomains: websiteDomains.sorted(),
              includeDeviceNames: includeDeviceNames)
    }
    var validationMessage: String? {
        if deviceIDs.isEmpty { return "Sélectionnez au moins un appareil. Rien n’est coché par défaut." }
        if deviceIDs.count > 12 { return "Sélectionnez au maximum douze appareils." }
        if includeApplications && applicationIDs.isEmpty { return "Choisissez les applications à transmettre ou désactivez ce détail." }
        if includeWebsites && websiteDomains.isEmpty { return "Choisissez les domaines à transmettre ou désactivez ce détail." }
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
            invalidate()
            if autoSender.enabled { autoSender.stop(); status = "Synchronisation mise en pause pendant la modification. Relisez puis confirmez vos nouveaux choix." }
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
    let autoSender: GoalongWebsiteAutoSender
    private let root: URL
    private let catalogLoader: (URL, String, Bool) throws -> GoalongSiteSelectionCatalog
    private let exporter: (URL, String, GoalongSiteExportOptions) throws -> Data
    private let sender: (Data, String, URL, String) throws -> Data
    private let sourceConsent: @MainActor (GoalongSiteExportOptions) -> Bool

    init(autoSender: GoalongWebsiteAutoSender? = nil, root: URL = AppPaths.applicationSupportDirectory,
         catalogLoader: @escaping (URL, String, Bool) throws -> GoalongSiteSelectionCatalog = { try GoalongQueryCLI.siteSelectionCatalog(rootDirectory: $0, day: $1, includeWebsites: $2) },
         exporter: @escaping (URL, String, GoalongSiteExportOptions) throws -> Data = { try GoalongQueryCLI.siteExportPayload(rootDirectory: $0, day: $1, options: $2) },
         sender: @escaping (Data, String, URL, String) throws -> Data = { try GoalongSiteSubmission.send(payload: $0, origin: $1, tokenFile: $2, expectedTokenFingerprint: $3) },
         sourceConsent: @escaping @MainActor (GoalongSiteExportOptions) -> Bool = { GoalongWebsiteAutoSender.sourcesAllowed($0) }) {
        let autoSender = autoSender ?? .shared
        self.autoSender = autoSender; self.root = root; self.catalogLoader = catalogLoader
        self.exporter = exporter; self.sender = sender; self.sourceConsent = sourceConsent
        if let saved = autoSender.savedConfiguration, saved.policyVersion == 2 {
            var restored = GoalongWebsiteShareDraft()
            restored.delivery = .daily
            restored.deviceIDs = Set(saved.options.deviceIDs)
            restored.applicationIDs = Set(saved.options.selectedApplicationIDs ?? [])
            restored.websiteDomains = Set(saved.options.selectedWebsiteDomains ?? [])
            restored.includeApplications = saved.options.includeApplications
            restored.includeHourly = saved.options.includeHourly
            restored.includeWebsites = saved.options.includeWebsites
            restored.includeDeviceNames = saved.options.includeDeviceNames ?? false
            restored.hour = saved.hour ?? 9; restored.minute = saved.minute ?? 0
            restored.timezone = saved.timeZoneIdentifier ?? TimeZone.current.identifier
            draft = restored
        }
    }
    func invalidate() { preview = nil; reviewed = false; error = nil; status = nil }
    func connectionChanged() { generation = UUID(); invalidate(); autoSender.stop() }
    func cancelPreparation() { generation = UUID(); loading = false; invalidate() }

    func loadCatalog() async {
        let ticket = UUID(); generation = ticket
        let snapshot = draft, root = root, loader = catalogLoader
        loading = true; error = nil
        // Previously selected IDs are kept, never expanded by newly discovered rows.
        do {
            let value = try await Task.detached(priority: .userInitiated) { try loader(root, snapshot.day, snapshot.includeWebsites) }.value
            guard generation == ticket, draft.day == snapshot.day, draft.includeWebsites == snapshot.includeWebsites else { return }
            catalog = value
        } catch {
            guard generation == ticket else { return }
            catalog = nil
            self.error = "Lecture locale indisponible : \(error)"
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
        let options = snapshot.options
        if snapshot.delivery == .daily && catalog.timezone != snapshot.timezone {
            error = "Le fuseau du planning ne correspond pas à cette journée. Choisissez une journée enregistrée dans le fuseau courant avant d’activer la synchronisation."
            return
        }
        guard sourceConsent(options) else { error = "Une source choisie est désactivée. Vérifiez les réglages avant de préparer l’aperçu."; return }
        busy = true
        defer { busy = false }
        let root = root, exporter = exporter
        do {
            _ = try GoalongSiteSubmission.endpoint(origin: target)
            let token = try GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath))
            let fingerprint = SHA256Digest.hashHex(Data(token.utf8))
            let bytes = try await Task.detached(priority: .userInitiated) { try exporter(root, snapshot.day, options) }.value
            guard generation == ticket, draft == snapshot, sourceConsent(options) else {
                error = "Les choix ou les autorisations ont changé. Préparez un nouvel aperçu."; return
            }
            preview = Preview(payload: bytes, draft: snapshot, origin: target, tokenPath: tokenPath,
                              credentialFingerprint: fingerprint, createdAt: Date())
        } catch { self.error = "Aperçu non préparé : \(error)" }
    }
    func confirm(origin: String, tokenPath: String) async {
        guard !busy, reviewed, let approved = preview else { return }
        guard approved.draft == draft, approved.origin == origin.trimmingCharacters(in: .whitespacesAndNewlines),
              approved.tokenPath == tokenPath, Date().timeIntervalSince(approved.createdAt) <= 900,
              sourceConsent(approved.draft.options) else {
            invalidate(); error = "L’aperçu ou les autorisations ont changé. Préparez un nouvel aperçu avant l’envoi."; return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let token = try GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath))
            guard SHA256Digest.hashHex(Data(token.utf8)) == approved.credentialFingerprint else {
                throw GoalongSiteExportError.invalid("L’accès au compte a changé depuis l’aperçu. Reliez le compte et relisez la sélection.")
            }
            if draft.delivery == .daily {
                try autoSender.enable(origin: approved.origin, tokenPath: approved.tokenPath, options: approved.draft.options,
                                      hour: draft.hour, minute: draft.minute, timeZoneIdentifier: draft.timezone)
                preview = nil; reviewed = false
                status = "Synchronisation activée. Seules les données autorisées de la veille seront envoyées, lorsque l’app est ouverte."
            } else {
                let sender = sender
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try sender(approved.payload, approved.origin, URL(fileURLWithPath: approved.tokenPath), approved.credentialFingerprint)
                }.value
                let object = try JSONSerialization.jsonObject(with: receipt) as? [String: Any] ?? [:]
                preview = nil; reviewed = false
                status = "Reçu par Goalong : \(object["imported"] ?? 0) ajout, \(object["updated"] ?? 0) mise à jour, \(object["skipped"] ?? 0) inchangé. Aucun envoi quotidien n’a été activé."
            }
        } catch { self.error = "Envoi non confirmé : \(error)" }
    }
}
#endif
