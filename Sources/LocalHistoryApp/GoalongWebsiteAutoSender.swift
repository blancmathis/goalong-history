#if os(macOS)
import Foundation
import Combine
import LocalHistoryQueryCLI

/// Opt-in schedule scoped to reviewed fields and one destination. No background
/// service is installed: only the running application checks the previous day.
@MainActor final class GoalongWebsiteAutoSender: ObservableObject {
    static let shared = GoalongWebsiteAutoSender()
    @Published private(set) var enabled = false
    @Published private(set) var status = "Envoi automatique désactivé"
    private var timer: Timer?
    private var busy = false
    private let defaults: UserDefaults
    private let root: URL
    private let exporter: (URL, String, GoalongSiteExportOptions) throws -> Data
    private let sender: (Data, String, URL) throws -> Data
    private let sourceConsent: (GoalongSiteExportOptions) -> Bool
    private let key = "goalong.website.autoSend.v1"
    struct Configuration: Codable {
        var origin: String
        var tokenPath: String
        var options: GoalongSiteExportOptions
        var lastAttempt: String?
    }
    init(defaults: UserDefaults = .standard, root: URL = AppPaths.applicationSupportDirectory,
         exporter: @escaping (URL, String, GoalongSiteExportOptions) throws -> Data = { try GoalongQueryCLI.siteExportPayload(rootDirectory: $0, day: $1, options: $2) },
         sender: @escaping (Data, String, URL) throws -> Data = { try GoalongSiteSubmission.send(payload: $0, origin: $1, tokenFile: $2) },
         sourceConsent: @escaping (GoalongSiteExportOptions) -> Bool = { options in
             GoalongCapabilityConsentStore.shared.isEnabled(.appleScreenTime) && (options.rhythmProject == nil || GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))
         }) {
        self.defaults = defaults; self.root = root; self.exporter = exporter; self.sender = sender
        self.sourceConsent = sourceConsent
        enabled = configuration() != nil
        status = enabled ? "Activé : la veille après 9 h, lorsque Goalong est ouvert" : "Envoi automatique désactivé"
    }
    private func configuration() -> Configuration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }
    private func store(_ value: Configuration) throws { defaults.set(try JSONEncoder().encode(value), forKey: key) }
    func enable(origin: String, tokenPath: String, options: GoalongSiteExportOptions) throws {
        guard !busy, !options.deviceIDs.isEmpty else { throw GoalongSiteExportError.invalid("Préparez d’abord l’aperçu et choisissez vos appareils.") }
        _ = try GoalongSiteSubmission.endpoint(origin: origin)
        _ = try GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath))
        var selected = options
        selected.includeRecap = false; selected.recapText = nil; selected.includeWebsites = false
        try store(Configuration(origin: origin, tokenPath: tokenPath, options: selected))
        enabled = true
        status = "Activé : la veille après 9 h, app ouverte. Aucun récap ni domaine."
        start()
    }
    func stop() {
        defaults.removeObject(forKey: key)
        enabled = false
        status = busy ? "Désactivé. L’envoi déjà commencé peut encore aboutir." : "Envoi automatique désactivé"
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }
    func tick(now: Date = Date()) async {
        guard !busy, var configuration = configuration(), Calendar.current.component(.hour, from: now) >= 9,
              let previous = Calendar.current.date(byAdding: .day, value: -1, to: now) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current
        let day = formatter.string(from: previous)
        guard configuration.lastAttempt != day else { return }
        // Persist the attempt before networking. Uncertain receipt never triggers an automatic retry.
        configuration.lastAttempt = day
        do { try store(configuration) } catch { stop(); status = "L’automatisation n’a pas pu enregistrer son état."; return }
        busy = true; status = "Préparation de la journée du \(day)…"
        let root = root, exporter = exporter, sender = sender
        do {
            let payload = try await Task.detached { try exporter(root, day, configuration.options) }.value
            guard enabled, self.configuration()?.origin == configuration.origin,
                  self.configuration()?.tokenPath == configuration.tokenPath else { busy = false; return }
            guard sourceConsent(configuration.options) else { stop(); busy = false; status = "Automatisation arrêtée : une source est désactivée."; return }
            status = "Envoi de la journée du \(day)…"
            _ = try await Task.detached { try sender(payload, configuration.origin, URL(fileURLWithPath: configuration.tokenPath)) }.value
            if enabled { status = "Journée du \(day) reçue. Prochain envoi demain après 9 h." }
        } catch {
            stop()
            status = "Automatisation arrêtée : \(error). Vérifiez les imports du site avant de la réactiver."
        }
        busy = false
    }
}
#endif
