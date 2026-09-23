#if os(macOS)
import AppKit
import Combine
import Foundation
import LocalHistoryCore

struct JevRecentCheck: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let verdict: JevVerdict
    let inputTokens: Int
}

@MainActor final class JevMonitor: ObservableObject {
    static let shared = JevMonitor()
    static let excerptKey = "goalong.jev.visibleExcerpt.v1"
    @Published private(set) var status = "Surveillance désactivée"
    @Published private(set) var hasKey = false
    @Published private(set) var timedBreak: JevTimedBreak?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var procrastinationSeconds = 0
    @Published private(set) var lastInputTokens: Int?
    @Published private(set) var lastRequestBytes = 0
    @Published private(set) var lastPayload = ""
    @Published private(set) var recentChecks: [JevRecentCheck] = []
    @Published private(set) var error: String?
    private var apiKey = ""
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var request: Task<Void, Never>?
    private var epoch = UUID()
    private var streak = JevStreak()
    private var boundary = Date()
    private var previousUptime = ProcessInfo.processInfo.systemUptime
    private var previousWall = Date()
    private var circuitOpen = false
    @Published private(set) var breakStorageInvalid = false
    private var sessionAvailable = true
    private var retryAfter = Date.distantPast
    private var settingsSignature = ""
    private var started = false
    private let inbox = JevIngress.shared

    var enabled: Bool { GoalongCapabilityConsentStore.shared.isEnabled(.jevMonitoring) }
    var includeText: Bool {
        UserDefaults.standard.bool(forKey: Self.excerptKey)
            && UserDefaults.standard.bool(forKey: ActivityAnalysisPreferences.richContextEnabledKey)
    }
    private init() {
        do {
            if let data = try JevLocalFiles.read("api-key"), let key = String(data: data, encoding: .utf8) {
                apiKey = key; hasKey = Self.validKey(key)
            }
            if let data = try JevLocalFiles.read("break.json") {
                let value = try JSONDecoder().decode(JevTimedBreak.self, from: data)
                guard value.isValid else { throw JevError.invalidResponse }
                timedBreak = value; remainingSeconds = value.remaining(at: Date())
            }
        } catch { self.error = "Réglages Jev illisibles : surveillance suspendue."; breakStorageInvalid = true }
    }
    func start() {
        guard !started else { return }; started = true
        let center = NotificationCenter.default
        for name in [Notification.Name.goalongGlobalPauseDidChange, .goalongCapabilityConsentDidChange,
                     .goalongExclusionsDidChange, .jevInterventionsDidChange,
                     NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reconfigure() }
            })
        }
        observers.append(center.addObserver(forName: .jevBoundaryChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.cancelPending(); self?.status = "Contexte protégé : Jev suspendu"
            }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.settingsSignature != self.signature else { return }
                self.reconfigure()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sessionAvailable = false; self?.reconfigure() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sessionAvailable = true; self?.reconfigure() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        })
        reconfigure()
    }
    private var signature: String {
        "\(enabled)|\(GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory))|\(BackgroundContinuityPreferences().manuallyPaused)|\(includeText)"
    }
    private var gate: String? {
        if timedBreak != nil || breakStorageInvalid { return "Pause Jev : aucun appel ni rappel" }
        if !enabled { return "Surveillance désactivée" }
        if !hasKey { return "Ajoutez votre clé TypeSafe pour utiliser Jev" }
        if circuitOpen { return "Jev suspendu après erreur : vérifiez la connexion" }
        if GoalongGlobalPause.isPaused() { return "Arrêt de confidentialité : suivi et Jev suspendus" }
        if !GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory) { return "Activez l’historique de ce Mac pour utiliser Jev" }
        if BackgroundContinuityPreferences().manuallyPaused { return "Enregistrement en pause : aucun appel Jev" }
        if !sessionAvailable { return "Mac inactif ou verrouillé : aucun appel Jev" }
        if GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory).blocked { return "Exclusions illisibles : aucun appel Jev" }
        return nil
    }
    func setEnabled(_ value: Bool) {
        if !GoalongCapabilityConsentStore.shared.set(.jevMonitoring, enabled: value, surface: .settings) {
            error = "Le choix Jev n’a pas pu être enregistré."
        }
        reconfigure()
    }
    func setIncludeText(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.excerptKey)
        reconfigure()
    }
    func saveKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validKey(key) else { error = "La clé TypeSafe doit être une valeur ASCII sans espace (8 à 1 024 caractères)."; return }
        do {
            try JevLocalFiles.write(Data(key.utf8), name: "api-key")
            apiKey = key; hasKey = true; circuitOpen = false; error = nil
            reconfigure()
        } catch { self.error = error.localizedDescription }
    }
    func removeKey() {
        cancelPending(); inbox.configure(enabled: false)
        do {
            try JevLocalFiles.write(nil, name: "api-key")
            apiKey = ""; hasKey = false; circuitOpen = false; error = nil
        } catch { self.error = error.localizedDescription; circuitOpen = true }
        reconfigure()
    }
    private static func validKey(_ value: String) -> Bool {
        (8...1024).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    func startBreak(minutes: Int) {
        guard let value = JevTimedBreak(minutes: minutes, now: Date()) else { return }
        // Suspend before touching disk: a failed save must never leave monitoring on.
        cancelPending(); inbox.configure(enabled: false)
        timedBreak = value; remainingSeconds = value.remaining(at: Date())
        do {
            try JevLocalFiles.write(try JSONEncoder().encode(value), name: "break.json")
            breakStorageInvalid = false; error = nil
        } catch { breakStorageInvalid = true; self.error = error.localizedDescription }
        reconfigure()
    }
    func endBreak() {
        do {
            try JevLocalFiles.write(nil, name: "break.json")
            timedBreak = nil; remainingSeconds = 0; breakStorageInvalid = false; error = nil
        } catch { breakStorageInvalid = true; self.error = error.localizedDescription }
        reconfigure()
    }
    func retry() { circuitOpen = false; retryAfter = .distantPast; error = nil; reconfigure() }
    func dismissWarning() {
        streak.dismissWarning()
        JevWarningPanel.shared.dismissPopup()
    }
    private func resetInterventions() {
        streak.reset(); procrastinationSeconds = 0
        JevWarningPanel.shared.hide(resetPosition: true)
    }
    private func cancelPending() {
        epoch = UUID(); request?.cancel(); request = nil; resetInterventions()
        lastPayload = ""; JevWarningPanel.shared.hide()
    }
    func reconfigure() {
        cancelPending(); timer?.invalidate(); timer = nil
        settingsSignature = signature
        boundary = Date(); previousWall = boundary; previousUptime = ProcessInfo.processInfo.systemUptime
        let available = gate == nil
        inbox.configure(enabled: available, includeText: includeText)
        status = gate ?? "En attente d’activité · vérification toutes les 15 s"
        if timedBreak != nil && !breakStorageInvalid {
            scheduleTimer(seconds: 1)
        } else if available { scheduleTimer(seconds: 15) }
    }
    private func scheduleTimer(seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = seconds == 15 ? 0.1 : 0.2
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func tick() {
        let now = Date()
        if let timedBreak {
            remainingSeconds = timedBreak.remaining(at: now)
            if remainingSeconds == 0, !breakStorageInvalid { endBreak() }
            return
        }
        guard gate == nil else { reconfigure(); return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let clockJump = abs(now.timeIntervalSince(previousWall) - (uptime - previousUptime)) > 2
        previousWall = now; previousUptime = uptime
        let end = boundary.addingTimeInterval(15)
        guard !clockJump, now >= end, now.timeIntervalSince(end) < 3 else { reconfigure(); return }
        let start = boundary; boundary = end
        guard request == nil else { cancelPending(); status = "Analyse trop lente : série remise à zéro"; return }
        guard let window = inbox.take(start: start, end: end), window.hasActivity else {
            resetInterventions(); status = "Aucune nouvelle activité observable · aucun appel"; return
        }
        guard now >= retryAfter else { resetInterventions(); return }
        let body: Data
        do { body = try JevPayload.build(window) }
        catch { resetInterventions(); status = "Fenêtre trop complexe : classement indéterminé"; return }
        let policy = GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory)
        let pause = GoalongGlobalPause.load()
        guard !policy.blocked, !pause.blocksActivity, gate == nil else { reconfigure(); return }
        let token = epoch, generation = inbox.generation, key = apiKey
        lastRequestBytes = body.count; lastPayload = String(data: body, encoding: .utf8) ?? ""
        status = "Classification des 15 dernières secondes…"
        request = Task { @MainActor [weak self] in
            guard let self, self.gate == nil, self.epoch == token,
                  self.inbox.generation == generation,
                  GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory).revision == policy.revision,
                  GoalongGlobalPause.load().revision == pause.revision else { return }
            do {
                let decision = try await JevTransport().classify(body: body, key: key)
                guard !Task.isCancelled, self.epoch == token else { return }
                self.request = nil
                guard self.gate == nil, self.inbox.generation == generation,
                      Date().timeIntervalSince(end) < 15,
                      GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory).revision == policy.revision,
                      GoalongGlobalPause.load().revision == pause.revision else {
                    self.resetInterventions(); return
                }
                self.lastInputTokens = decision.inputTokens
                self.recentChecks.insert(JevRecentCheck(start: start, end: end, verdict: decision.verdict,
                                                      inputTokens: decision.inputTokens), at: 0)
                self.recentChecks = Array(self.recentChecks.prefix(120))
                let warn = self.streak.accept(decision.verdict, start: start, end: end)
                switch decision.verdict {
                case .productive: self.status = "Activité classée productive"; self.resetInterventions()
                case .unknown: self.status = "Activité indéterminée · aucune alerte"; self.resetInterventions()
                case .procrastination:
                    self.status = "Procrastination détectée · \(JevInterventionSettings.duration(self.streak.observedSeconds))"
                }
                self.procrastinationSeconds = self.streak.observedSeconds
                if decision.verdict == .procrastination {
                    JevWarningPanel.shared.update(seconds: self.streak.observedSeconds,
                        appearance: self.streak.appearanceCount, present: warn,
                        settings: JevInterventionPreferences.shared.settings)
                }
            } catch {
                guard self.epoch == token, !Task.isCancelled else { return }
                self.request = nil; self.resetInterventions()
                self.error = (error as? JevError)?.errorDescription ?? "Connexion Jev indisponible. Aucun classement inventé."
                self.status = self.error ?? "Jev indisponible"
                if let error = error as? JevError {
                    switch error {
                    case .authentication, .budget: self.circuitOpen = true; self.reconfigure()
                    case .rateLimited(let seconds): self.retryAfter = Date().addingTimeInterval(Double(seconds))
                    default: self.retryAfter = Date().addingTimeInterval(30)
                    }
                } else { self.retryAfter = Date().addingTimeInterval(30) }
            }
        }
    }
    private func stop() {
        cancelPending(); timer?.invalidate(); timer = nil; inbox.configure(enabled: false)
    }
}
#endif
