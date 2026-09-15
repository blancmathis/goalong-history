#if os(macOS)
import Foundation
import Combine
import LocalHistoryQueryCLI
import LocalHistoryCore

/// A local, explicitly enabled schedule. No daemon, collection, audience change or
/// backfill is performed. Future text is never authorized by a past paragraph index.
@MainActor final class GoalongWebsiteAutoSender: ObservableObject {
    static let shared = GoalongWebsiteAutoSender()
    @Published private(set) var enabled = false
    @Published private(set) var status = "Synchronisation quotidienne désactivée"
    @Published private(set) var lastSuccess: String?
    private var timer: Timer?
    private var busy = false
    private let defaults: UserDefaults
    private let root: URL
    private let exporter: (URL, String, GoalongSiteExportOptions) throws -> Data
    private let sender: ((Data, String, URL, String?) throws -> Data)?
    private let sourceConsent: @MainActor (GoalongSiteExportOptions) -> Bool
    private let key = "goalong.website.autoSend.v1"
    struct Configuration: Codable {
        var origin: String
        var tokenPath: String
        var options: GoalongSiteExportOptions
        var lastAttempt: String?
        var hour: Int?
        var minute: Int? = 0
        var timeZoneIdentifier: String? = TimeZone.current.identifier
        var policyVersion: Int? = 3
        var privacyRevision: String?
        var identifier: String? = UUID().uuidString
        var lastSuccess: String?
        var paused: Bool? = false
        var credentialFingerprint: String?
    }
    var savedConfiguration: Configuration? { configuration() }

    static func sourcesAllowed(_ options: GoalongSiteExportOptions) -> Bool {
        GoalongCapabilityConsentStore.shared.isEnabled(.appleScreenTime)
            && ((options.rhythmProject == nil && options.contextualRhythm == nil && !options.includeWebsites)
                || GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))
            && (!options.includeRecap || GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis))
    }

    init(defaults: UserDefaults = .standard, root: URL = AppPaths.applicationSupportDirectory,
         exporter: @escaping (URL, String, GoalongSiteExportOptions) throws -> Data = { try GoalongQueryCLI.siteExportPayload(rootDirectory: $0, day: $1, options: $2) },
         sender: ((Data, String, URL, String?) throws -> Data)? = nil,
         sourceConsent: @escaping @MainActor (GoalongSiteExportOptions) -> Bool = { GoalongWebsiteAutoSender.sourcesAllowed($0) }) {
        self.defaults = defaults; self.root = root; self.exporter = exporter; self.sender = sender
        self.sourceConsent = sourceConsent
        let saved = configuration()
        lastSuccess = saved?.lastSuccess
        enabled = saved?.policyVersion == 3 && saved?.paused != true
            && saved?.privacyRevision == GoalongPrivacyPolicy.load(in: root).revision
        if let saved {
            if saved.policyVersion != 3 {
                status = "Ancienne synchronisation suspendue : relisez la sélection avant de la réactiver."
            } else if enabled {
                status = "Activée · la veille à partir de \(Self.timeLabel(saved)), lorsque Goalong est ouvert."
            } else { status = "Synchronisation en pause · vos choix sont conservés sur ce Mac." }
        }
    }
    private func configuration() -> Configuration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }
    private func store(_ value: Configuration) throws { defaults.set(try JSONEncoder().encode(value), forKey: key) }
    static func timeLabel(_ value: Configuration) -> String {
        String(format: "%02d:%02d", value.hour ?? 9, value.minute ?? 0) + " · " + (value.timeZoneIdentifier ?? TimeZone.current.identifier)
    }
    static func dailyOptions(_ options: GoalongSiteExportOptions) throws -> GoalongSiteExportOptions {
        guard !options.deviceIDs.isEmpty, options.deviceIDs.count <= 12,
              Set(options.deviceIDs).count == options.deviceIDs.count else {
            throw GoalongSiteExportError.invalid("Choisissez explicitement entre un et douze appareils.")
        }
        guard !options.includeApplications || options.selectedApplicationIDs != nil,
              !options.includeWebsites || options.selectedWebsiteDomains != nil else {
            throw GoalongSiteExportError.invalid("Choisissez les applications et domaines autorisés dans la nouvelle fenêtre de partage.")
        }
        var selected = options
        selected.strictSelection = true
        selected.includeHourly = false
        // Today's free text and positional recap indices cannot authorize tomorrow's text.
        selected.includeRecap = false
        selected.recapText = nil
        selected.recapSectionIndices = nil
        selected.contextualRhythm = nil
        selected.rhythmProject = nil
        selected.rhythmApplications = []
        selected.includeRhythmTimeline = false
        selected.includeRhythmTimes = false
        selected.includeRhythmContext = false
        if !selected.maskedApplications.isEmpty { selected.includeWebsites = false }
        return selected
    }
    func enable(origin: String, tokenPath: String, options: GoalongSiteExportOptions, hour: Int = 9,
                minute: Int = 0, timeZoneIdentifier: String = TimeZone.current.identifier) throws {
        guard !busy else { throw GoalongSiteExportError.invalid("Un envoi est déjà en cours.") }
        _ = try GoalongSiteSubmission.endpoint(origin: origin)
        let token = try GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath))
        guard (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw GoalongSiteExportError.invalid("Choisissez une heure et un fuseau horaire valides.")
        }
        let selected = try Self.dailyOptions(options)
        guard sourceConsent(selected) else { throw GoalongSiteExportError.invalid("Une source sélectionnée est désactivée dans les réglages.") }
        var value = Configuration(origin: origin, tokenPath: tokenPath, options: selected, hour: hour,
                                  minute: minute, timeZoneIdentifier: timeZoneIdentifier, credentialFingerprint: SHA256Digest.hashHex(Data(token.utf8)))
        value.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        guard !GoalongPrivacyPolicy.load(in: root).blocked else { throw GoalongSiteExportError.invalid("Les exclusions sont illisibles.") }
        try store(value)
        lastSuccess = nil
        enabled = true
        status = "Activée · la veille après \(Self.timeLabel(value)). Nouveaux appareils, apps, domaines et récaps exclus."
        start()
    }
    func stop() {
        if var saved = configuration() { saved.paused = true; try? store(saved) }
        enabled = false
        status = busy ? "En pause. Un envoi déjà commencé peut encore aboutir." : "Synchronisation en pause · vos choix sont conservés."
    }
    func forget() {
        stop()
        defaults.removeObject(forKey: key)
        lastSuccess = nil
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }
    func tick(now: Date = Date()) async {
        guard !busy, enabled, var current = configuration(), current.policyVersion == 3, current.paused != true,
              let zone = TimeZone(identifier: current.timeZoneIdentifier ?? "") else { return }
        guard current.privacyRevision == GoalongPrivacyPolicy.load(in: root).revision else {
            stop(); status = "Exclusions modifiées : vérifiez la sélection avant de reprendre."; return
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minutes >= (current.hour ?? 9) * 60 + (current.minute ?? 0),
              let previous = calendar.date(byAdding: .day, value: -1, to: now) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = zone
        let day = formatter.string(from: previous)
        guard current.lastAttempt != day else { return }
        do {
            current.options = try Self.dailyOptions(current.options)
            guard sourceConsent(current.options) else {
                stop(); status = "Synchronisation arrêtée : une source est désactivée."; return
            }
            // Persist before networking. An uncertain receipt never silently retries.
            current.lastAttempt = day
            try store(current)
            busy = true; status = "Préparation locale du \(day)…"
            defer { busy = false }
            let root = root, exporter = exporter, sender = sender, snapshot = current
            let payload = try await Task.detached { try exporter(root, day, snapshot.options) }.value
            guard enabled, configuration()?.identifier == snapshot.identifier,
                  configuration()?.origin == snapshot.origin, configuration()?.tokenPath == snapshot.tokenPath else { return }
            guard sourceConsent(snapshot.options) else {
                stop(); status = "Synchronisation arrêtée : une source est désactivée."; return
            }
            _ = try GoalongOutgoingPrivacy.validate(payload, root: root, expectedRevision: snapshot.privacyRevision)
            status = "Envoi du \(day)…"
            _ = try await Task.detached {
                _ = try GoalongOutgoingPrivacy.validate(payload, root: root, expectedRevision: snapshot.privacyRevision)
                if let sender { return try sender(payload, snapshot.origin, URL(fileURLWithPath: snapshot.tokenPath), snapshot.credentialFingerprint) }
                return try GoalongSiteSubmission.send(payload: payload, origin: snapshot.origin,
                    tokenFile: URL(fileURLWithPath: snapshot.tokenPath), expectedTokenFingerprint: snapshot.credentialFingerprint,
                    privacyRoot: root, expectedPrivacyRevision: snapshot.privacyRevision)
            }.value
            guard enabled, configuration()?.identifier == snapshot.identifier else { return }
            current.lastSuccess = day
            try store(current)
            lastSuccess = day
            status = "Journée du \(day) reçue · prochain envoi après \(Self.timeLabel(current))."
        } catch {
            stop()
            status = "Synchronisation en pause : \(error). Vérifiez l’historique du site, puis relisez l’aperçu pour reprendre."
        }
    }
    deinit { timer?.invalidate() }
}
#endif
