#if os(macOS)
import Foundation
import Combine
import LocalHistoryQueryCLI
import LocalHistoryCore

/// A local, explicitly enabled schedule. No daemon, collection or audience change. Missed days
/// are caught up at most 3 days back. Future text is never authorized by a past paragraph index.
@MainActor final class GoalongWebsiteAutoSender: ObservableObject {
    static let shared = GoalongWebsiteAutoSender()
    @Published private(set) var enabled = false
    @Published private(set) var status = "Synchronisation quotidienne désactivée"
    @Published private(set) var lastSuccess: String?
    /// Why the plan stopped by itself. Nil when the plan runs, or when the user paused it.
    @Published private(set) var pauseReason: String?
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
        var pauseReason: String?
        /// Days skipped because no record was saved, comma-separated. Shown until the next received day names them too.
        var missingDay: String?
        /// Day being prepared or sent, and the last attempt before it. Still set at launch: Goalong
        /// quit or crashed during that send, so the day is tried again (the site replaces a day it already has).
        var sendingDay: String?
        var attemptBeforeSending: String?
    }
    var savedConfiguration: Configuration? { configuration() }
    private static let globalPauseStatus = "Pause globale : envoi suspendu, programmation conservée."
    static let exclusionsChangedReason = "Exclusions modifiées : relisez la sélection avant de reprendre."
    static let accessRefusedReason = "Synchronisation en pause : le site a refusé l’accès de ce Mac. Reliez-le avec « Relier mon Mac », puis relisez la sélection."
    static let sharingRulesUnreadableReason = "Synchronisation arrêtée : les règles de partage sont illisibles. Vérifiez-les dans les réglages avant de reprendre."
    static let reboundReason = "Compte relié de nouveau : relisez la sélection, puis reprenez l’envoi quotidien."
    static let unreachableReason = "Synchronisation en pause : le site reste injoignable depuis ce Mac. Vérifiez votre connexion, puis relisez l’aperçu pour reprendre."
    /// Fingerprint of an access the site refused (HTTP 401/403). The account card then offers to pair again.
    static let refusedCredentialKey = "goalong.website.refusedCredentialFingerprint"
    /// Waits before each new try when the site could not be reached. One more failure pauses the plan.
    static let networkRetryDelays: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]
    /// Network failures for one day. In memory only: a restart allows a fresh try.
    private var networkRetry: (day: String, failures: Int, notBefore: Date)?
    private let sharingRulesReadable: () -> Bool
    /// The send started: the site may have received the day. Other errors are local, nothing left this Mac.
    private struct ReceiptUncertain: Error { let underlying: Error }

    static func sourcesAllowed(_ options: GoalongSiteExportOptions) -> Bool {
        GoalongCapabilityConsentStore.shared.isEnabled(.appleScreenTime)
            && ((options.rhythmProject == nil && options.contextualRhythm == nil && !options.includeWebsites)
                || GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))
            && (!options.includeRecap || GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis))
    }

    init(defaults: UserDefaults = .standard, root: URL = AppPaths.applicationSupportDirectory,
         exporter: @escaping (URL, String, GoalongSiteExportOptions) throws -> Data = { try GoalongQueryCLI.siteExportPayload(rootDirectory: $0, day: $1, options: $2) },
         sender: ((Data, String, URL, String?) throws -> Data)? = nil,
         sourceConsent: @escaping @MainActor (GoalongSiteExportOptions) -> Bool = { GoalongWebsiteAutoSender.sourcesAllowed($0) },
         hiddenWebsites: @escaping () -> (String) -> Bool = { SharingRulesStore().hiddenWebsiteFilter() },
         hiddenApplications: @escaping () -> (String?, String) -> Bool = { SharingRulesStore().hiddenApplicationFilter() },
         sharingRulesReadable: @escaping () -> Bool = { !SharingRulesStore().isDamaged },
         beforeStore: @escaping (Configuration) throws -> Void = { _ in }) {
        self.beforeStore = beforeStore
        self.sharingRulesReadable = sharingRulesReadable
        self.hiddenWebsites = hiddenWebsites
        self.hiddenApplications = hiddenApplications
        self.defaults = defaults; self.root = root; self.exporter = exporter; self.sender = sender
        self.sourceConsent = sourceConsent
        var saved = configuration()
        lastSuccess = saved?.lastSuccess
        // Quit or crash during a send: try that day again. The usual checks of the next tick still apply.
        if var value = saved, let day = value.sendingDay {
            if value.lastAttempt == day { value.lastAttempt = value.attemptBeforeSending }
            value.sendingDay = nil; value.attemptBeforeSending = nil
            try? store(value); saved = value
        }
        // Exclusions changed while the app was closed: pause with the reason, and keep it after a restart.
        if var value = saved, value.policyVersion == 3, value.paused != true,
           value.privacyRevision != GoalongPrivacyPolicy.load(in: root).revision {
            value.paused = true; value.pauseReason = Self.exclusionsChangedReason
            try? store(value); saved = value
        }
        enabled = saved?.policyVersion == 3 && saved?.paused != true
            && saved?.privacyRevision == GoalongPrivacyPolicy.load(in: root).revision
        if let saved {
            if saved.policyVersion != 3 {
                status = "Ancienne synchronisation suspendue : relisez la sélection avant de la réactiver."
            } else if enabled {
                status = Self.activeStatus(saved)
            } else if let reason = saved.pauseReason, saved.paused == true {
                pauseReason = reason; status = reason
            } else { status = "Synchronisation en pause · vos choix sont conservés sur ce Mac." }
        }
    }
    private func configuration() -> Configuration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }
    private let beforeStore: (Configuration) throws -> Void
    private func store(_ value: Configuration) throws { try beforeStore(value); defaults.set(try JSONEncoder().encode(value), forKey: key) }
    static func timeLabel(_ value: Configuration) -> String {
        String(format: "%02d:%02d", value.hour ?? 9, value.minute ?? 0) + " · " + (value.timeZoneIdentifier ?? TimeZone.current.identifier)
    }
    private let hiddenWebsites: () -> (String) -> Bool
    /// Sites hidden in every share never leave, even when an older plan still lists them.
    /// Applications hidden in every share are dropped too (matched on their id, as the Screen Time id is the bundle id).
    /// A nil list stays nil and an empty list stays empty: an empty list never means "all".
    nonisolated static func removingHiddenWebsites(_ options: GoalongSiteExportOptions, isHidden: (String) -> Bool,
                                                   isApplicationHidden: ((String?, String) -> Bool)? = nil) -> GoalongSiteExportOptions {
        var value = options
        value.selectedWebsiteDomains = options.selectedWebsiteDomains?.filter { !isHidden($0) }
        if let isApplicationHidden {
            value.selectedApplicationIDs = options.selectedApplicationIDs?.filter { !isApplicationHidden($0, $0) }
        }
        return value
    }
    private let hiddenApplications: () -> (String?, String) -> Bool
    /// True when the options select no application and no site, so a send would carry an empty day.
    nonisolated static func selectsNothing(_ options: GoalongSiteExportOptions) -> Bool {
        !(options.includeApplications && !(options.selectedApplicationIDs ?? []).isEmpty)
            && !(options.includeWebsites && !(options.selectedWebsiteDomains ?? []).isEmpty)
    }
    static let nothingSelectedMessage = "Les applications et sites choisis sont masqués dans tous les partages. Choisissez-en d’autres."
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
        _ = try GoalongGlobalPause.admit(in: root)
        guard !busy else { throw GoalongSiteExportError.invalid("Un envoi est déjà en cours.") }
        _ = try GoalongSiteSubmission.endpoint(origin: origin)
        let token = try GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath))
        guard (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw GoalongSiteExportError.invalid("Choisissez une heure et un fuseau horaire valides.")
        }
        let daily = try Self.dailyOptions(options)
        let selected = Self.removingHiddenWebsites(daily, isHidden: hiddenWebsites(), isApplicationHidden: hiddenApplications())
        guard Self.selectsNothing(daily) || !Self.selectsNothing(selected) else { throw GoalongSiteExportError.invalid(Self.nothingSelectedMessage) }
        guard sourceConsent(selected) else { throw GoalongSiteExportError.invalid("Une source sélectionnée est désactivée dans les réglages.") }
        var value = Configuration(origin: origin, tokenPath: tokenPath, options: selected, hour: hour,
                                  minute: minute, timeZoneIdentifier: timeZoneIdentifier, credentialFingerprint: SHA256Digest.hashHex(Data(token.utf8)))
        value.privacyRevision = GoalongPrivacyPolicy.load(in: root).revision
        guard !GoalongPrivacyPolicy.load(in: root).blocked else { throw GoalongSiteExportError.invalid("Les exclusions sont illisibles.") }
        guard sharingRulesReadable() else { throw GoalongSiteExportError.invalid("Les règles de partage sont illisibles. Vérifiez-les dans les réglages, puis relisez l’aperçu.") }
        try store(value)
        networkRetry = nil
        lastSuccess = nil
        pauseReason = nil
        enabled = true
        status = "Activée · la veille après \(Self.timeLabel(value)). Nouveaux appareils, apps, domaines et récaps exclus."
        start()
    }
    /// A stop the app decided alone passes a `reason`; a user stop clears it.
    func stop(reason: String? = nil) {
        if var saved = configuration() { saved.paused = true; saved.pauseReason = reason; try? store(saved) }
        enabled = false
        pauseReason = reason
        status = reason ?? (busy ? "En pause. Un envoi déjà commencé peut encore aboutir." : "Synchronisation en pause · vos choix sont conservés.")
    }
    private func stopAutomatically(_ message: String) { networkRetry = nil; stop(reason: message) }
    /// Records that the site refused this access, so the account card offers « Relier mon Mac ».
    func markAccessRefused(fingerprint: String?) {
        guard let fingerprint, !fingerprint.isEmpty else { return }
        defaults.set(fingerprint, forKey: Self.refusedCredentialKey)
    }
    /// True when the site refused the access stored in this token file.
    static func accessWasRefused(tokenPath: String, defaults: UserDefaults = .standard) -> Bool {
        guard let refused = defaults.string(forKey: refusedCredentialKey), !tokenPath.isEmpty,
              let token = try? GoalongSiteSubmission.readToken(file: URL(fileURLWithPath: tokenPath)) else { return false }
        return SHA256Digest.hashHex(Data(token.utf8)) == refused
    }
    /// The same account was paired again: the plan follows the new access and waits for a review.
    func rebind(tokenPath: String, credentialFingerprint: String) {
        defaults.removeObject(forKey: Self.refusedCredentialKey)
        guard var saved = configuration() else { return }
        saved.tokenPath = tokenPath; saved.credentialFingerprint = credentialFingerprint
        try? store(saved)
        stopAutomatically(Self.reboundReason)
    }
    func forget() {
        stop()
        networkRetry = nil
        defaults.removeObject(forKey: key)
        lastSuccess = nil
        pauseReason = nil
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        // Minute granularity: a few seconds of delay is fine and lets macOS coalesce wakeups.
        timer?.tolerance = 15
    }
    var hasTimer: Bool { timer != nil }
    func tick(now: Date = Date()) async {
        // Cheap in-memory check first: a disabled plan must not read files every minute.
        guard enabled else { return }
        let pause = GoalongGlobalPause.load(in: root)
        guard !pause.blocksActivity else {
            if enabled { status = Self.globalPauseStatus }
            return
        }
        // The pause ended: drop its message even when this tick sends nothing. Other statuses stay.
        if status == Self.globalPauseStatus, enabled, let saved = configuration(), saved.policyVersion == 3, saved.paused != true {
            status = Self.activeStatus(saved)
        }
        guard !busy, enabled, var current = configuration(), current.policyVersion == 3, current.paused != true,
              let zone = TimeZone(identifier: current.timeZoneIdentifier ?? "") else { return }
        guard current.privacyRevision == GoalongPrivacyPolicy.load(in: root).revision else {
            stopAutomatically(Self.exclusionsChangedReason); return
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minutes >= (current.hour ?? 9) * 60 + (current.minute ?? 0) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = zone
        // Oldest day not yet sent, at most 3 days back; with no history only yesterday. Never a day at or before the last attempt/success.
        let floor = [current.lastSuccess, current.lastAttempt].compactMap { $0 }.max()
        let offsets = floor == nil ? [-1] : [-3, -2, -1]
        let candidates = offsets.compactMap { calendar.date(byAdding: .day, value: $0, to: now) }.map { formatter.string(from: $0) }
        guard let day = candidates.first(where: { floor == nil || $0 > floor! }) else { return }
        guard current.lastAttempt != day else { return }
        if let retry = networkRetry, retry.day == day, now < retry.notBefore { return }
        let previousAttempt = current.lastAttempt
        do {
            guard sharingRulesReadable() else { stopAutomatically(Self.sharingRulesUnreadableReason); return }
            let daily = try Self.dailyOptions(current.options)
            current.options = Self.removingHiddenWebsites(daily, isHidden: hiddenWebsites(), isApplicationHidden: hiddenApplications())
            guard Self.selectsNothing(daily) || !Self.selectsNothing(current.options) else {
                stopAutomatically("Synchronisation arrêtée : les applications et sites choisis sont désormais masqués."); return
            }
            guard sourceConsent(current.options) else {
                stopAutomatically("Synchronisation arrêtée : une source est désactivée."); return
            }
            // Persist before networking. An uncertain receipt never silently retries.
            current.lastAttempt = day
            var sending = current
            sending.sendingDay = day; sending.attemptBeforeSending = previousAttempt
            try store(sending)
            // Every outcome below is handled while the app runs: only a quit or a crash keeps the marker.
            defer { clearSendingDay(of: current) }
            busy = true; status = "Préparation locale du \(GoalongUIFormat.day(key: day))…"
            defer { busy = false }
            let root = root, exporter = exporter, sender = sender, snapshot = current
            let payload = try await Task.detached { try exporter(root, day, snapshot.options) }.value
            guard enabled, configuration()?.identifier == snapshot.identifier,
                  configuration()?.origin == snapshot.origin, configuration()?.tokenPath == snapshot.tokenPath else {
                // Paused or changed during the preparation: nothing was sent, so the day stays to send.
                restoreAttempt(previousAttempt, of: current); return
            }
            guard sourceConsent(snapshot.options) else {
                restoreAttempt(previousAttempt, of: current)
                stopAutomatically("Synchronisation arrêtée : une source est désactivée."); return
            }
            try GoalongGlobalPause.revalidate(pause.revision, in: root)
            _ = try GoalongOutgoingPrivacy.validate(payload, root: root, expectedRevision: snapshot.privacyRevision)
            status = "Envoi du \(GoalongUIFormat.day(key: day))…"
            _ = try await Task.detached {
                try GoalongGlobalPause.revalidate(pause.revision, in: root)
                _ = try GoalongOutgoingPrivacy.validate(payload, root: root, expectedRevision: snapshot.privacyRevision)
                // Local checks of the send (token file, account, exclusions) fail before any request: nothing left.
                var dispatched = sender != nil
                do {
                    if let sender { return try sender(payload, snapshot.origin, URL(fileURLWithPath: snapshot.tokenPath), snapshot.credentialFingerprint) }
                    return try GoalongSiteSubmission.send(payload: payload, origin: snapshot.origin,
                        tokenFile: URL(fileURLWithPath: snapshot.tokenPath), expectedTokenFingerprint: snapshot.credentialFingerprint,
                        privacyRoot: root, expectedPrivacyRevision: snapshot.privacyRevision, willSend: { dispatched = true })
                } catch let error as GoalongSiteSubmissionError { throw error }
                catch let error as GoalongGlobalPause.PauseError { throw error }
                catch where !dispatched { throw error }
                catch { throw ReceiptUncertain(underlying: error) }
            }.value
            guard enabled, configuration()?.identifier == snapshot.identifier else { return }
            let skipped = configuration()?.missingDay
            current.lastSuccess = day
            current.missingDay = nil
            lastSuccess = day
            networkRetry = nil
            do {
                try store(current)
                status = "Journée du \(GoalongUIFormat.day(key: day)) reçue · prochain envoi après \(Self.timeLabel(current))."
                    + (skipped.map { " " + Self.missingDayNotice($0) } ?? "")
            } catch {
                // The site has the day: only the local record failed. Not "nothing was sent", and no resend by itself
                // (the attempt saved before sending already marks the day as tried).
                SupportDiagnostics.shared.failure(error, component: .sharing)
                status = "Journée du \(GoalongUIFormat.day(key: day)) reçue par le site, mais Goalong n’a pas pu l’enregistrer sur ce Mac. Elle ne sera pas renvoyée tant que Goalong reste ouvert."
            }
        } catch where GoalongQueryCLI.isMissingSavedDay(error) {
            // Mac off or Goalong closed that day: no record, and none will come later. Send nothing
            // (never an invented zero), keep the day marked as tried, and keep the plan running.
            networkRetry = nil
            // A weekend skips two days: keep naming each one, not only the last.
            guard var saved = configuration(), saved.identifier == current.identifier else { return }
            saved.missingDay = ((saved.missingDay.map { $0.split(separator: ",").suffix(Self.missingDayLimit - 1).joined(separator: ",") + "," } ?? "") + day); try? store(saved)
            // Paused while the day was read: the pause text stays, the day is named on resume or restart.
            guard enabled else { return }
            status = Self.missingDayNotice(saved.missingDay ?? day) + " L’envoi quotidien continue."
        } catch GoalongSiteSubmissionError.unreachable {
            // Nothing reached the site: try the same day again later, a few times.
            restoreAttempt(previousAttempt, of: current)
            // Paused during the try: no new try is announced on a paused plan.
            guard enabled else { networkRetry = nil; return }
            let failures = (networkRetry?.day == day ? networkRetry?.failures ?? 0 : 0) + 1
            guard failures <= Self.networkRetryDelays.count else { stopAutomatically(Self.unreachableReason); return }
            let delay = Self.networkRetryDelays[failures - 1]
            networkRetry = (day, failures, now.addingTimeInterval(delay))
            status = "Site injoignable : rien n’a été envoyé. Nouvel essai dans \(Int(delay / 60)) min."
        } catch is GoalongGlobalPause.PauseError {
            // The global pause started during the export: nothing left. Keep the plan; the day goes after the pause.
            restoreAttempt(previousAttempt, of: current)
            status = Self.globalPauseStatus
        } catch GoalongSiteSubmissionError.accessRefused {
            SupportDiagnostics.shared.failure(GoalongSiteSubmissionError.accessRefused, component: .sharing)
            markAccessRefused(fingerprint: current.credentialFingerprint)
            stopAutomatically(Self.accessRefusedReason)
            NotificationCenter.default.post(name: .goalongWebsiteAccessRefused, object: nil)
        } catch let failure as ReceiptUncertain {
            // The request may have reached the site: never resend by itself.
            SupportDiagnostics.shared.failure(failure.underlying, component: .sharing)
            stopAutomatically("Synchronisation en pause : \(Self.sentence(failure.underlying)). Vérifiez l’historique du site, puis relisez l’aperçu pour reprendre.")
        } catch {
            // A local step failed before the send: nothing left this Mac, the day stays to send.
            SupportDiagnostics.shared.failure(error, component: .sharing)
            restoreAttempt(previousAttempt, of: current)
            // Some local messages already say it: say it once.
            let reason = Self.sentence(error).replacingOccurrences(of: ". Aucun envoi n’a été effectué", with: "")
            stopAutomatically("Synchronisation en pause : \(reason). Rien n’a été envoyé. Corrigez ce point, puis relisez l’aperçu pour reprendre.")
        }
    }
    private static func activeStatus(_ saved: Configuration) -> String {
        "Activée · la veille à partir de \(timeLabel(saved)), lorsque Goalong est ouvert."
            + (saved.missingDay.map { " " + missingDayNotice($0) } ?? "")
    }
    private static let missingDayShown = 3
    /// What is kept in the saved setting, so it does not grow until the next success.
    private static let missingDayLimit = 30
    static func missingDayNotice(_ days: String) -> String {
        let all = days.split(separator: ",")
        let names = all.prefix(missingDayShown).map { "le " + GoalongUIFormat.day(key: String($0)) }
        // Long absences stay short: the first days, then how many more (only the last 30 are kept).
        let more = all.count - names.count
        let list = more > 0
            ? names.joined(separator: ", ") + " et " + (all.count >= missingDayLimit ? "au moins " : "") + "\(more) autre\(more > 1 ? "s" : "") jour\(more > 1 ? "s" : "")"
            : names.count > 1 ? names.dropLast().joined(separator: ", ") + " et " + names.last! : names.joined()
        return "Aucun relevé enregistré pour \(list) (Mac éteint ou Goalong fermé) : rien n’a été envoyé pour "
            + (all.count > 1 ? "ces jours." : "ce jour.")
    }
    private static func sentence(_ error: Error) -> String {
        goalongUserMessage(error).trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
    }
    private func clearSendingDay(of attempt: Configuration) {
        guard var saved = configuration(), saved.identifier == attempt.identifier, saved.sendingDay != nil else { return }
        saved.sendingDay = nil; saved.attemptBeforeSending = nil
        try? store(saved)
    }
    /// Puts back the last attempt saved before the send, so the same day is tried again.
    private func restoreAttempt(_ previous: String?, of attempt: Configuration) {
        guard var saved = configuration(), saved.identifier == attempt.identifier else { return }
        saved.lastAttempt = previous
        try? store(saved)
    }
    deinit { timer?.invalidate() }
}
#endif
