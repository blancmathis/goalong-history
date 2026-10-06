#if os(macOS)
import AppKit
import BraiseCore
import Combine
import Foundation
import LocalHistoryQueryCLI
import ServiceManagement

@MainActor final class BraiseController: ObservableObject {
    @Published private(set) var preferences: Preferences
    @Published private(set) var active = false
    @Published private(set) var displayCount = 0
    @Published private(set) var nextEvent = ""
    @Published private(set) var errorMessage: String?
    @Published var shortcutAvailable = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginApprovalRequired = false
    var stateChanged: (() -> Void)?
    private let store: BraiseStore
    private let gamma: BraiseGammaDriving
    private let clock: () -> Date
    private let calendar: Calendar
    private let runsTimers: Bool
    private var running = true
    private var boundaryTimer: Timer?
    private var maintenanceTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var saveTask: DispatchWorkItem?

    init(store: BraiseStore, gamma: BraiseGammaDriving, runsTimers: Bool = true,
         clock: @escaping () -> Date = Date.init, calendar: Calendar = .current) throws {
        self.store = store; self.gamma = gamma; self.runsTimers = runsTimers
        self.clock = clock; self.calendar = calendar
        preferences = try store.load()
        gamma.onError = { [weak self] message in
            guard let self, self.running else { return }
            self.preferences.mode = .off; self.preferences.pauseUntil = nil; self.active = false
            self.errorMessage = message; self.saveNow(); self.evaluate()
        }
        gamma.onDisplays = { [weak self] count in self?.displayCount = count }
        if runsTimers {
            refreshLoginStatus()
            GammaController.recoverPending(in: store.directory)
            displayCount = GammaController.displays().count
            observe(NotificationCenter.default, names: [NSApplication.didChangeScreenParametersNotification,
                .NSSystemTimeZoneDidChange, .NSCalendarDayChanged, Notification.Name("NSSystemClockDidChangeNotification")])
            observe(NSWorkspace.shared.notificationCenter, names: [NSWorkspace.didWakeNotification,
                NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification])
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate(); self?.gamma.checkAfterSystemChange() }
            }
            timer.tolerance = 4; RunLoop.main.add(timer, forMode: .common); maintenanceTimer = timer
        }
        evaluate()
    }

    private func observe(_ center: NotificationCenter, names: [Notification.Name]) {
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.evaluate(); self.gamma.checkAfterSystemChange()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.running else { return }; self.gamma.checkAfterSystemChange()
                    }
                }
            }
            observers.append((center, token))
        }
    }

    func update(_ change: (inout Preferences) -> Void) {
        guard running else { return }
        change(&preferences); preferences.sanitize(); errorMessage = nil
        evaluate(); saveSoon()
    }
    func setMode(_ mode: FilterMode) { update { $0.mode = mode; $0.pauseUntil = nil } }
    func emergencyOff() { gamma.restore(); setMode(.off); saveNow() }
    func pause() { update { $0.pauseUntil = clock().addingTimeInterval(15 * 60) } }
    func resume() { update { $0.pauseUntil = nil } }
    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginApprovalRequired = SMAppService.mainApp.status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) throws {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            errorMessage = "Le démarrage de Goalong à la connexion n’a pas pu être modifié."
            refreshLoginStatus(); throw GoalongFocusError.storageFailed
        }
    }
    func saveRule(_ rule: ScheduleRule) throws {
        guard rule.isValid else { throw GoalongFocusError.invalidArgument }
        guard preferences.rules.count < 32 || preferences.rules.contains(where: { $0.id == rule.id }) else { throw GoalongFocusError.invalidArgument }
        update { value in
            if let i = value.rules.firstIndex(where: { $0.id == rule.id }) { value.rules[i] = rule }
            else { value.rules.append(rule) }
        }
    }
    func deleteRule(_ id: UUID) { update { $0.rules.removeAll { $0.id == id } } }
    var isPaused: Bool { preferences.pauseUntil.map { $0 > clock() } ?? false }
    var stateLabel: String { isPaused ? "En pause" : active ? "Filtre actif" : "Couleurs naturelles" }

    func evaluate() {
        guard running else { return }
        let now = clock()
        if let end = preferences.pauseUntil, end <= now { preferences.pauseUntil = nil; saveSoon() }
        let planned = ScheduleEngine.isActive(preferences.rules, at: now, calendar: calendar)
        active = !isPaused && (preferences.mode == .on || (preferences.mode == .auto && planned))
        gamma.set(active: active, intensity: preferences.intensity, brightness: preferences.brightness,
                  animated: runsTimers && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        boundaryTimer?.invalidate(); boundaryTimer = nil
        let next = ScheduleEngine.nextTransition(preferences.rules, after: now, calendar: calendar)
        var events: [Date] = []
        if let end = preferences.pauseUntil { events.append(end) }
        if preferences.mode == .auto, let next { events.append(next.date) }
        if runsTimers, let nearest = events.min() {
            let timer = Timer(fire: nearest, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
            timer.tolerance = 0.1; RunLoop.main.add(timer, forMode: .common); boundaryTimer = timer
        }
        if let end = preferences.pauseUntil { nextEvent = "En pause jusqu’à \(Self.clockText(end))" }
        else {
            switch preferences.mode {
            case .on: nextEvent = "Activé manuellement · sans horaire de fin"
            case .off: nextEvent = "Choisissez Auto pour suivre vos horaires."
            case .auto:
                if let next { nextEvent = "\(next.active ? "Activation" : "Désactivation") \(Self.when(next.date))" }
                else { nextEvent = active ? "Plages continues · filtre actif" : "Aucune plage active" }
            }
        }
        stateChanged?()
    }
    static func clockText(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date) }
    private static func when(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE 'à' HH:mm"; return f.string(from: date)
    }
    private func saveSoon() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.saveNow() }; saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }
    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        do { try store.save(preferences) } catch { errorMessage = "Réglages non enregistrés. Vérifiez l’espace et l’accès au dossier Braise." }
    }
    func persistCommand() throws {
        saveNow(); if errorMessage != nil { throw GoalongFocusError.storageFailed }
    }
    var status: [String: Any] {
        let gains = ChannelGains(intensity: preferences.intensity, brightness: preferences.brightness)
        return ["schema": 1, "module": "braise", "enabled": true, "mode": preferences.mode.rawValue,
                "active": active, "paused": isPaused, "intensity": preferences.intensity,
                "brightness": preferences.brightness, "displayCount": displayCount, "nextEvent": nextEvent,
                "shortcutAvailable": shortcutAvailable, "error": errorMessage ?? "",
                "loginEnabled": loginEnabled, "loginApprovalRequired": loginApprovalRequired,
                "softwareGains": ["red": active ? gains.red : 1, "green": active ? gains.green : 1, "blue": active ? gains.blue : 1]]
    }
    func shutdown() {
        guard running else { return }
        running = false; boundaryTimer?.invalidate(); boundaryTimer = nil
        maintenanceTimer?.invalidate(); maintenanceTimer = nil
        for (center, token) in observers { center.removeObserver(token) }; observers = []
        saveNow(); gamma.restore(); active = false; gamma.onError = nil; gamma.onDisplays = nil; stateChanged = nil
    }
}
#endif
