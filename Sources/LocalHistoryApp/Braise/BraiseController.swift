#if os(macOS)
import AppKit
import BraiseCore
import Combine
import Foundation
import LocalHistoryQueryCLI
import ServiceManagement

/// A command that takes red away (T-048 B2). Outside a range it acts at once; during a range it is
/// a weakening and follows the rule of an active block (docs/BLOCKING.md « Range lock »).
enum RedScreenWeakening: Equatable {
    case manualOff, pause, emergency
    case intensity(Double)
}

enum RedScreenGuardResult: Equatable {
    case applied
    /// A protected range runs: the page asks for the text or the password, then applies the command.
    case needsStop(lock: BlockLock, end: Date)
    /// « Verrouillé »: nothing stops it before `until`.
    case locked(until: Date)
}

enum RedScreenStopResult: Equatable {
    case stopped
    case wrongText
    case password(BlockingPasswordResult)
    case locked(until: Date)
}

/// A range change refused while a protected range runs, or an invalid range.
struct RedScreenRefusal: LocalizedError, Equatable {
    var message: String
    var isLock: Bool
    var errorDescription: String? { message }
}

@MainActor final class BraiseController: ObservableObject {
    @Published private(set) var preferences: Preferences
    @Published private(set) var ranges: RedScreenProgram
    /// The range windows in progress (scheduled or held), minus the ones stopped for today.
    @Published private(set) var windows: [RedScreenWindow] = []
    @Published private(set) var active = false
    /// What is on screen: the strongest of the manual red and the ranges in progress.
    @Published private(set) var appliedIntensity = 0.0
    /// The command waiting for a stop (text or password) on the page.
    @Published private(set) var pendingStop: RedScreenWeakening?
    /// Shown next to the sliders when a protected range stopped them at its intensity (« … : 80 % au moins »).
    @Published private(set) var sliderNotice: String?
    @Published private(set) var displayCount = 0
    @Published private(set) var nextEvent = ""
    @Published private(set) var errorMessage: String?
    /// Set once when unreadable settings were reset at start.
    @Published private(set) var recoveryNotice: String?
    @Published var shortcutAvailable = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginApprovalRequired = false
    /// « Verrou de luminosité » (T-048 D2): the screens as the driver sees them, read at start and on screen changes.
    @Published private(set) var brightnessDisplays: [BrightnessDisplay] = []
    /// The hardware brightness held now (manual lock and ranges in progress, darkest wins), nil = not held.
    @Published private(set) var brightnessTarget: Double?
    /// The brightness change waiting for the stop of a protected lock (text or password) on the page.
    @Published private(set) var pendingBrightness: BrightnessLockChange?
    /// Shown next to the brightness slider when the protection stopped it at its level.
    @Published private(set) var brightnessNotice: String?
    /// What the editor's sliders show on screen while they move (T-050 A2), nil = the real state.
    @Published private(set) var preview: Preview?
    /// Said under the slider when what runs keeps the preview from where the slider is.
    @Published private(set) var previewNotice: String?
    var stateChanged: (() -> Void)?
    /// A protected range needs the page (Garde-fous › Écran rouge) to be stopped.
    var onStopRequired: (() -> Void)?
    private let store: BraiseStore
    private let gamma: BraiseGammaDriving
    private let brightnessDriver: DisplayBrightnessDriving
    private let enforcer: BrightnessEnforcer
    private let clock: () -> Date
    /// The clock of the blocks (`BlockingClock`): counts during sleep, ignores wall clock changes.
    private let continuous: () -> Double
    private let bootID: () -> String
    private let calendar: Calendar
    private let runsTimers: Bool
    private let passwordAvailable: @MainActor () -> Bool
    private let checkPassword: @MainActor (String) -> BlockingPasswordResult
    private var running = true
    private var boundaryTimer: Timer?
    private var maintenanceTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var saveTask: DispatchWorkItem?
    /// The preview ends by itself at this time; nil while the slider is held.
    private(set) var previewUntil: Date?
    private var previewTimer: Timer?
    /// The screens' hardware levels before the first brightness preview, also in `preview-brightness.json` for a crash.
    private var previewBrightnessBefore: [UInt32: Double]?

    init(store: BraiseStore, gamma: BraiseGammaDriving, runsTimers: Bool = true,
         clock: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
         continuous: @escaping () -> Double = BlockingClock.continuous, boot: @escaping () -> String = BlockingClock.bootID,
         brightness: DisplayBrightnessDriving = NoDisplayBrightness(),
         hasPassword: @escaping @MainActor () -> Bool = { BlockingRuntime.shared.controller?.hasPassword ?? false },
         verifyPassword: @escaping @MainActor (String) -> BlockingPasswordResult = {
             BlockingRuntime.shared.controller?.verifyRedScreenPassword($0)
                 ?? .refused(reason: "Les blocages sont arrêtés : aucun mot de passe n’est disponible.")
         }) throws {
        self.store = store; self.gamma = gamma; self.runsTimers = runsTimers
        self.clock = clock; self.calendar = calendar; self.continuous = continuous; self.bootID = boot
        self.passwordAvailable = hasPassword; self.checkPassword = verifyPassword
        self.brightnessDriver = brightness; self.enforcer = BrightnessEnforcer(driver: brightness, runsTimer: runsTimers)
        let loaded = try store.loadRecovering()
        preferences = loaded.preferences
        let loadedRanges = try store.loadRanges(migratingFrom: loaded.preferences)
        ranges = loadedRanges.ranges
        let notices = [loaded.notice, loadedRanges.notice].compactMap { $0 }
        recoveryNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
        gamma.onError = { [weak self] message in
            guard let self, self.running else { return }
            // A technical fault always gives the colors back now, protected ranges included.
            self.preferences.mode = .off; self.preferences.pauseUntil = nil; self.active = false
            for window in self.windows { self.ranges.skips[window.rangeID] = window.end; self.ranges.holds[window.rangeID] = nil }
            self.ranges.raise = nil
            self.errorMessage = message; self.saveNow(); self.evaluate()
        }
        gamma.onDisplays = { [weak self] count in self?.displayCount = count }
        // A crashed run's tables come back before anything else (its guardian restored them too).
        gamma.recoverPending()
        displayCount = gamma.onlineDisplayCount()
        brightnessDisplays = brightness.displays()
        // A crashed run's brightness preview comes back too, unless something holds the screens.
        let crashed = store.loadPreviewBrightness()
        if !crashed.isEmpty {
            if BrightnessLockRules.target(manual: ranges.brightnessLock, windows: []) == nil {
                for (id, level) in crashed { _ = brightness.setBrightness(level, of: id) }
            }
            store.savePreviewBrightness(nil)
        }
        if migrateLegacy() { saveRangesNow() }
        if runsTimers {
            refreshLoginStatus()
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
                // The default calendar follows the system zone; drop the cached zone first so evaluate() sees the new one.
                if name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.handleSystemChange()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.running else { return }; self.gamma.checkAfterSystemChange()
                    }
                }
            }
            observers.append((center, token))
        }
    }

    /// A screen plugged or unplugged, a wake, a clock change: red on reaches every screen; red off touches none.
    func handleSystemChange() {
        guard running else { return }
        let screens = brightnessDriver.displays()
        if screens != brightnessDisplays { brightnessDisplays = screens }
        evaluate(); gamma.checkAfterSystemChange()
    }

    /// Comfort settings (brightness) and the manual intensity outside a range. Weakening commands go through `guardWeakening`.
    func update(_ change: (inout Preferences) -> Void) {
        guard running else { return }
        change(&preferences); preferences.sanitize(); errorMessage = nil
        evaluate(); saveSoon()
    }
    var hasBlockingPassword: Bool { passwordAvailable() }
    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginApprovalRequired = status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) throws {
        // Same path as Settings and onboarding: consent, preference and lock bookkeeping change together.
        let manager = LaunchAtLoginManager()
        let ok = manager.setUserPreference(enabled, surface: .settings)
        errorMessage = manager.message
        refreshLoginStatus()
        if !ok { throw GoalongFocusError.storageFailed }
    }

    // MARK: Manual red and the B1 commands

    /// The manual switch. On: red at the manual intensity. Off: never drops the ranges; during a range it is a weakening.
    @discardableResult func setManual(_ on: Bool) -> RedScreenGuardResult {
        guard on else { return guardWeakening(.manualOff) }
        update { $0.mode = .on; $0.pauseUntil = nil }; return .applied
    }
    /// T-050 A3, once at start. « Suivre mes horaires » is gone: ranges that were not followed come back paused (their
    /// holds did not run and are dropped), so no red starts by surprise. A brightness lock with no protection in progress
    /// becomes a rule « Toujours » at its level; a protected one stays as it is: « En cours »
    /// shows it with its stop, and the first start after its protection converts it. True = the ranges changed.
    private func migrateLegacy() -> Bool {
        var changed = false
        if !ranges.follows {
            let known = Set(ranges.program.ranges.map(\.id))
            ranges.disabled.formUnion(known)
            ranges.holds = ranges.holds.filter { !known.contains($0.key) }
            ranges.follows = true; changed = true
        }
        // Only a lock that was never protected moves: a protected one (even past its wall end, the continuous clock
        // decides) stays in « En cours » with its stop, and moves at a later launch once it is free.
        if let lock = ranges.brightnessLock, lock.effectiveLock == .free || lock.end == nil,
           ranges.program.ranges.count < RedScreenProgram.maximumRanges {
            let range = BlockProgramRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440)
            ranges.program.ranges.append(range)
            ranges.intensities[range.id] = 0
            var levels = ranges.brightness ?? [:]; levels[range.id] = BrightnessLockRules.clamp(lock.level)
            ranges.brightness = levels
            ranges.brightnessLock = nil; changed = true
        }
        return changed
    }
    /// ⌃⌥⌘R, « Rétablir les couleurs ».
    @discardableResult func emergencyOff() -> RedScreenGuardResult { guardWeakening(.emergency) }
    @discardableResult func pause() -> RedScreenGuardResult { guardWeakening(.pause) }
    func resume() { update { $0.pauseUntil = nil } }
    /// The intensity command (CLI). During a range, below the range's intensity is a weakening; at or above it the range is
    /// strengthened until its end.
    @discardableResult func setIntensity(_ value: Double) -> RedScreenGuardResult {
        guardWeakening(.intensity(min(1, max(0, value.isFinite ? value : 1))))
    }
    /// Reading of the continuous clock the holds follow (`BlockingClock.continuous` by default: sleep counts).
    var continuousNow: Double { continuous() }
    /// The sliders (menu, panel, page) send one value per notch. During a protected range they never open the page or a
    /// sheet: they stop at the range's intensity and say so in place; going lower is « Arrêter la plage… » on the page.
    @discardableResult func slideIntensity(_ value: Double) -> RedScreenGuardResult {
        guard running else { return .applied }
        var wanted = min(1, max(0, value.isFinite ? value : 1))
        refreshWindows(clock())
        var notice: String?
        if let strong = protectedWindow, let floor = windows.filter(\.isProtected).map(\.intensity).max(), wanted < floor - 0.0001 {
            wanted = floor
            notice = "Plage protégée jusqu’à \(Self.clockText(strong.end)) : \(GoalongUIFormat.percent(floor * 100)) au moins"
        }
        if sliderNotice != notice { sliderNotice = notice }
        // Held at the floor, the value on screen may not change: redraw so the page's thumb goes back to it.
        if notice != nil { objectWillChange.send() }
        return guardWeakening(.intensity(wanted))
    }

    /// Outside a range: at once. Free ranges only: they stop for today, then the command applies.
    /// A protected range: « Verrouillé » refuses with its end; « Difficile » and « Mot de passe » open the page.
    func guardWeakening(_ action: RedScreenWeakening) -> RedScreenGuardResult {
        guard running else { return .applied }
        let now = clock()
        refreshWindows(now)
        var relevant = windows
        switch action {
        case .intensity(let value): relevant = relevant.filter { $0.intensity > value + 0.0001 }
        case .pause: relevant = relevant.filter(\.isProtected)
        default: break
        }
        if let strong = RedScreenRules.strongest(relevant) {
            if strong.lock == .locked {
                errorMessage = Self.lockedText(until: strong.end, now: now); stateChanged?()
                return .locked(until: strong.end)
            }
            pendingStop = action; errorMessage = nil; stateChanged?(); onStopRequired?()
            return .needsStop(lock: strong.lock, end: strong.end)
        }
        if !relevant.isEmpty { skip(relevant); saveRangesNow() }
        apply(action)
        return .applied
    }

    /// The page's stop: text or password per the strongest protected range in progress, then the waiting command.
    func stopActiveRanges(typed: String? = nil, challenge: String? = nil, password: String? = nil) -> RedScreenStopResult {
        guard running else { return .stopped }
        let now = clock()
        refreshWindows(now)
        if let strong = RedScreenRules.strongest(windows) {
            switch strong.lock {
            case .locked:
                errorMessage = Self.lockedText(until: strong.end, now: now); stateChanged?()
                return .locked(until: strong.end)
            case .typing:
                guard let typed, let challenge, !challenge.isEmpty, typed == challenge else { return .wrongText }
            case .password:
                let result = checkPassword(password ?? "")
                guard result == .ok else { return .password(result) }
            case .free: break
            }
        }
        var targets = windows
        if case .intensity(let value)? = pendingStop { targets = targets.filter { $0.intensity > value + 0.0001 } }
        skip(targets); saveRangesNow()
        if let action = pendingStop { pendingStop = nil; apply(action) } else { evaluate() }
        return .stopped
    }
    func cancelStop() { pendingStop = nil; stateChanged?() }

    private func skip(_ list: [RedScreenWindow]) {
        for window in list {
            ranges.skips[window.rangeID] = max(window.end, ranges.skips[window.rangeID] ?? window.end)
            ranges.holds[window.rangeID] = nil
        }
    }

    private func apply(_ action: RedScreenWeakening) {
        switch action {
        case .manualOff: update { $0.mode = .off; $0.pauseUntil = nil }
        case .pause: update { $0.pauseUntil = clock().addingTimeInterval(15 * 60) }
        case .emergency: gamma.restore(); update { $0.mode = .off; $0.pauseUntil = nil }; saveNow()
        case .intensity(let value):
            // Read after the skips above: a range just stopped is no longer in progress.
            refreshWindows(clock())
            if let until = windows.map(\.end).max() {
                // During a range the slider strengthens the ranges in progress until their end only; the manual red
                // (switch and its intensity) is left as it was, so nothing stays red after the range.
                ranges.raise = RedScreenProgram.Raise(intensity: value, until: until); saveRangesNow()
                if preferences.mode == .on { update { $0.intensity = value } } else { errorMessage = nil; evaluate() }
            } else {
                if ranges.raise != nil { ranges.raise = nil; saveRangesNow() }
                update { $0.intensity = value }
            }
        }
    }

    // MARK: Preview (T-050 A2)

    /// The editor's sliders, on screen while they move. Never weaker than what runs: the red never below the effect in
    /// progress, the brightness never above a held level.
    struct Preview: Equatable {
        var red: Double?
        var brightness: Double?
    }
    /// How long the preview stays after the slider is let go.
    static let previewHold: TimeInterval = 2

    /// `holding`: the slider is held, the preview stays until the next call. Let go: it ends `previewHold` later.
    func showPreview(red: Double? = nil, brightness: Double? = nil, holding: Bool) {
        guard running else { return }
        let value = Preview(red: red.map { min(1, max(0, $0.isFinite ? $0 : 1)) },
                            brightness: canControlBrightness ? brightness.map(BrightnessLockRules.clamp) : nil)
        if value.brightness != nil, previewBrightnessBefore == nil {
            var levels: [UInt32: Double] = [:]
            for display in brightnessDisplays where display.controllable { levels[display.id] = brightnessDriver.brightness(of: display.id) }
            previewBrightnessBefore = levels
            // Written before the screens move: a crash during the preview finds them at the next start.
            store.savePreviewBrightness(levels)
        }
        if preview != value { preview = value }
        previewTimer?.invalidate(); previewTimer = nil
        previewUntil = holding ? nil : clock().addingTimeInterval(Self.previewHold)
        if runsTimers, !holding {
            let timer = Timer(timeInterval: Self.previewHold + 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            RunLoop.main.add(timer, forMode: .common); previewTimer = timer
        }
        evaluate()
    }

    /// The real state comes back now: the editor closes, « Annuler », another « Quand ».
    func endPreview() {
        guard running, preview != nil || previewBrightnessBefore != nil else { return }
        dropPreview(); evaluate()
    }

    private func dropPreview() {
        previewTimer?.invalidate(); previewTimer = nil
        previewUntil = nil
        if preview != nil { preview = nil }
        if previewNotice != nil { previewNotice = nil }
    }

    /// What the screens show with the preview: the strongest red and the darkest brightness of the real state and the
    /// preview. Sets `previewNotice` when the real state wins over the slider.
    private func previewed(target: Double?) -> (active: Bool, intensity: Double, brightness: Double?) {
        guard let preview else { return (active, appliedIntensity, target) }
        var notices: [String] = []
        var shownActive = active, shownIntensity = appliedIntensity, shownBrightness = target
        if let red = preview.red {
            if active, appliedIntensity > red + 0.0001 {
                notices.append("L’écran rouge est déjà à \(GoalongUIFormat.percent(appliedIntensity * 100)) : l’aperçu ne descend pas plus bas.")
            }
            shownIntensity = max(active ? appliedIntensity : 0, red); shownActive = true
        }
        if let level = preview.brightness {
            if let target, level > target + BrightnessLockRules.tolerance {
                notices.append("La luminosité est bloquée à \(GoalongUIFormat.percent(target * 100)) : l’aperçu ne monte pas plus haut.")
            }
            shownBrightness = min(target ?? level, level)
        }
        let notice = notices.isEmpty ? nil : notices.joined(separator: " ")
        if previewNotice != notice { previewNotice = notice }
        return (shownActive, shownIntensity, shownBrightness)
    }

    // MARK: Brightness lock (T-048 D2)

    /// Turns the lock on or changes it (`nil` = off). While protected, only stricter changes apply at once; a weaker one
    /// follows the stop rule (« Verrouillé » refuses, « Difficile » and « Mot de passe » open the page).
    @discardableResult func setBrightnessLock(_ wanted: BrightnessLockState?) throws -> RedScreenGuardResult {
        guard running else { return .applied }
        let now = clock()
        var next = wanted
        if var value = next {
            value.level = BrightnessLockRules.clamp(value.level)
            if value.effectiveLock == .free { value.lock = nil; value.end = nil }
            if value.end != nil, value.end == ranges.brightnessLock?.end {
                // Same protection kept (level lowered): its continuous deadline stays.
                value.deadline = ranges.brightnessLock?.deadline; value.boot = ranges.brightnessLock?.boot
            } else { value.deadline = nil; value.boot = nil }
            if ranges.brightnessLock == nil || value.effectiveLock != .free {
                guard canControlBrightness else {
                    throw RedScreenRefusal(message: "Goalong ne peut régler la luminosité d’aucun écran de ce Mac.", isLock: false)
                }
            }
            if value.effectiveLock != .free {
                guard let end = value.end, end > now.addingTimeInterval(59) else {
                    throw RedScreenRefusal(message: "Choisissez une fin de protection à venir.", isLock: false)
                }
                guard end <= now.addingTimeInterval(BrightnessLockRules.maximumProtection) else {
                    throw RedScreenRefusal(message: "24 h de protection au maximum.", isLock: false)
                }
                if value.effectiveLock == .password, !passwordAvailable(), ranges.brightnessLock?.effectiveLock != .password {
                    throw RedScreenRefusal(message: "Créez d’abord un mot de passe de blocage (Blocages › Protection).", isLock: false)
                }
            }
            next = value
        }
        refreshWindows(now)
        if BrightnessLockRules.weakening(from: ranges.brightnessLock, to: next, now: now, hasPassword: passwordAvailable()) != nil,
           let held = brightnessProtection {
            if held.lock == .locked {
                errorMessage = Self.lockedText(until: held.end, now: now); stateChanged?()
                return .locked(until: held.end)
            }
            pendingBrightness = next.map { .set($0) } ?? .off; errorMessage = nil; stateChanged?(); onStopRequired?()
            return .needsStop(lock: held.lock, end: held.end)
        }
        applyBrightness(next)
        return .applied
    }

    /// The slider: lowering is free; raising during a protection stops at the locked level and says so in place.
    @discardableResult func slideBrightnessLock(_ value: Double) -> RedScreenGuardResult {
        guard running, var lock = ranges.brightnessLock else { return .applied }
        var wanted = BrightnessLockRules.clamp(value)
        var notice: String?
        if let held = brightnessProtection, wanted > lock.level + BrightnessLockRules.tolerance {
            wanted = lock.level
            notice = "Verrou protégé jusqu’à \(Self.clockText(held.end)) : \(GoalongUIFormat.percent(lock.level * 100)) au plus"
        }
        if brightnessNotice != notice { brightnessNotice = notice }
        if notice != nil { objectWillChange.send(); return .applied }
        lock.level = wanted
        return (try? setBrightnessLock(lock)) ?? .applied
    }

    /// The page's stop of a protected brightness lock: text or password, then the waiting change (or the protection ends).
    func stopBrightnessLock(typed: String? = nil, challenge: String? = nil, password: String? = nil) -> RedScreenStopResult {
        guard running else { return .stopped }
        let now = clock()
        refreshWindows(now)
        if let held = brightnessProtection {
            switch held.lock {
            case .locked:
                errorMessage = Self.lockedText(until: held.end, now: now); stateChanged?()
                return .locked(until: held.end)
            case .typing:
                guard let typed, let challenge, !challenge.isEmpty, typed == challenge else { return .wrongText }
            case .password:
                let result = checkPassword(password ?? "")
                guard result == .ok else { return .password(result) }
            case .free: break
            }
        }
        let change = pendingBrightness; pendingBrightness = nil
        switch change {
        case .off?: applyBrightness(nil)
        case .set(let value)?: applyBrightness(value)
        case nil:
            var value = ranges.brightnessLock
            value?.lock = nil; value?.end = nil; value?.deadline = nil; value?.boot = nil
            applyBrightness(value)
        }
        return .stopped
    }
    func cancelBrightnessStop() { pendingBrightness = nil; stateChanged?() }

    private func applyBrightness(_ value: BrightnessLockState?) {
        ranges.brightnessLock = value; errorMessage = nil; brightnessNotice = nil
        saveRangesNow(); evaluate()
    }

    /// The current hardware level of the first controllable screen (the lock's starting point), nil when none.
    func currentHardwareBrightness() -> Double? {
        brightnessDisplays.first(where: \.controllable).flatMap { brightnessDriver.brightness(of: $0.id) }
    }

    // MARK: Ranges

    /// Adds or replaces a range. While a protected range runs, only stricter changes pass (docs/BLOCKING.md).
    func saveRange(_ range: BlockProgramRange, intensity: Double, enabled: Bool = true, brightness: Double?? = .none) throws {
        try saveRanges([RangeWrite(range: range, intensity: intensity, enabled: enabled, brightness: brightness)])
    }

    /// One range to add or replace. `brightness`: `.none` keeps the range's level, `.some(nil)` removes it.
    struct RangeWrite {
        var range: BlockProgramRange
        var intensity: Double
        var enabled = true
        var brightness: Double?? = .none
    }

    /// Several ranges at once (a rule of the page « Blocages »): every range is checked, then the whole change
    /// against the protected range in progress, then one write. All pass or nothing is written.
    func saveRanges(_ writes: [RangeWrite], deleting removed: Set<UUID> = []) throws {
        try commitRanges(try staged(writes, deleting: removed))
    }

    /// The refusal `saveRanges` would give, without writing (the page checks every engine before the first write).
    func checkRanges(_ writes: [RangeWrite], deleting removed: Set<UUID> = []) throws {
        guard running else { throw Self.stopped }
        let next = try staged(writes, deleting: removed)
        if let message = refusal(for: next) { throw RedScreenRefusal(message: message, isLock: true) }
    }

    private static let stopped = RedScreenRefusal(message: "L’écran rouge est arrêté. Relancez Goalong pour modifier ses plages.", isLock: false)

    /// The ranges after `writes` and `removed`, from the live state: holds, skips and the other ranges stay as they are.
    private func staged(_ writes: [RangeWrite], deleting removed: Set<UUID>) throws -> RedScreenProgram {
        var next = ranges
        for id in removed {
            next.program.ranges.removeAll { $0.id == id }; next.intensities[id] = nil; next.disabled.remove(id); next.brightness?[id] = nil
            // A hold of no range is a one-time window: a deleted range never leaves one behind.
            next.holds[id] = nil; next.skips[id] = nil
        }
        for write in writes {
            let range = write.range
            guard RedScreenProgram.isUsable(range) else { throw RedScreenRefusal(message: "Choisissez au moins un jour et deux heures différentes.", isLock: false) }
            if range.effectiveLock == .password, !passwordAvailable(), ranges.program.ranges.first(where: { $0.id == range.id })?.effectiveLock != .password {
                throw RedScreenRefusal(message: "Créez d’abord un mot de passe de blocage (Blocages › Protection).", isLock: false)
            }
            if let i = next.program.ranges.firstIndex(where: { $0.id == range.id }) { next.program.ranges[i] = range }
            else {
                guard next.program.ranges.count < RedScreenProgram.maximumRanges else {
                    throw RedScreenRefusal(message: "32 plages au maximum.", isLock: false)
                }
                next.program.ranges.append(range)
            }
            next.intensities[range.id] = min(1, max(0, write.intensity.isFinite ? write.intensity : 1))
            if case .some(let level) = write.brightness {
                if level != nil, next.brightness(of: range.id) == nil, !canControlBrightness {
                    throw RedScreenRefusal(message: "Goalong ne peut régler la luminosité d’aucun écran de ce Mac.", isLock: false)
                }
                var levels = next.brightness ?? [:]; levels[range.id] = level.map(BrightnessLockRules.clamp)
                next.brightness = levels.isEmpty ? nil : levels
            }
            if write.enabled { next.disabled.remove(range.id) } else { next.disabled.insert(range.id) }
        }
        return next
    }

    // MARK: One-time window (page « Blocages », « Maintenant »)

    /// The longest one-time window: « Jusqu’à… » means the next occurrence of a time of day.
    static let maximumHoldSeconds: TimeInterval = 24 * 3_600

    /// Red (and a brightness ceiling) from now to `end`, with a block's stop rule. It is a hold of no range: the
    /// file format stays, « Suivre mes horaires » is not touched, and the guard, « Quitter », the slider, the pause,
    /// ⌃⌥⌘R, the stop and a technical fault all follow the ranges' path. Its end is on the continuous clock at once.
    @discardableResult
    func holdNow(intensity: Double, brightness: Double? = nil, until end: Date, lock: BlockLock) throws -> UUID {
        if let refusal = holdRefusal(intensity: intensity, brightness: brightness, until: end, lock: lock) { throw refusal }
        let now = clock()
        let length = end.timeIntervalSince(now)
        refreshWindows(now)
        let id = UUID()
        ranges.holds[id] = RedScreenProgram.Hold(end: end, lock: lock, intensity: min(1, max(0, intensity.isFinite ? intensity : 1)),
                                                 deadline: continuous() + length, boot: bootID(),
                                                 brightness: brightness.map(BrightnessLockRules.clamp))
        errorMessage = nil; saveRangesNow(); evaluate()
        return id
    }

    /// The weakest red a one-time window may hold when it locks no brightness: below it the window changes nothing.
    static let minimumHoldIntensity = 0.05

    /// Why `holdNow` would refuse, read without writing: « Maintenant » checks its red part before it starts the lists.
    /// It covers every refusal of `holdNow`: a plan of two engines never writes one half.
    func holdRefusal(intensity: Double = 1, brightness: Double? = nil, until end: Date, lock: BlockLock) -> RedScreenRefusal? {
        guard running else { return Self.stopped }
        let now = clock()
        let length = end.timeIntervalSince(now)
        guard brightness != nil || (intensity.isFinite && intensity >= Self.minimumHoldIntensity) else {
            return RedScreenRefusal(message: "Choisissez un rouge ou une luminosité.", isLock: false)
        }
        guard length >= 60 else { return RedScreenRefusal(message: "Choisissez une fin dans au moins une minute.", isLock: false) }
        guard length <= Self.maximumHoldSeconds else { return RedScreenRefusal(message: "Une fenêtre ponctuelle dure 24 h au plus.", isLock: false) }
        if lock == .password, !passwordAvailable() {
            return RedScreenRefusal(message: "Créez d’abord un mot de passe de blocage (Blocages › Protection).", isLock: false)
        }
        if brightness != nil, !canControlBrightness {
            return RedScreenRefusal(message: "Goalong ne peut régler la luminosité d’aucun écran de ce Mac.", isLock: false)
        }
        // Counted on the state brought to now, without a write: a window that has just ended frees its place.
        let known = Set(ranges.program.ranges.map(\.id))
        guard brought(now).value.holds.keys.filter({ !known.contains($0) }).count < Self.maximumOneTimeWindows else {
            return RedScreenRefusal(message: "\(Self.maximumOneTimeWindows) fenêtres ponctuelles au plus en même temps.", isLock: false)
        }
        return nil
    }

    /// The one-time windows in progress: holds that belong to no range.
    var oneTimeWindows: [RedScreenWindow] {
        let known = Set(ranges.program.ranges.map(\.id))
        return windows.filter { !known.contains($0.rangeID) }
    }
    static let maximumOneTimeWindows = 8

    func deleteRange(_ id: UUID) throws {
        var next = ranges
        next.program.ranges.removeAll { $0.id == id }; next.intensities[id] = nil; next.disabled.remove(id); next.brightness?[id] = nil
        next.holds[id] = nil; next.skips[id] = nil
        try commitRanges(next)
    }
    func setRangeEnabled(_ id: UUID, _ enabled: Bool) throws {
        guard let range = ranges.program.ranges.first(where: { $0.id == id }) else { throw RedScreenRefusal(message: "Plage introuvable.", isLock: false) }
        if enabled, !RedScreenProgram.isUsable(range) { throw RedScreenRefusal(message: "Cette plage n’a pas de jour ou dure zéro minute.", isLock: false) }
        var next = ranges
        if enabled { next.disabled.remove(id) } else { next.disabled.insert(id) }
        try commitRanges(next)
    }
    /// The refusal text of a change, nil when allowed (the editor shows it before saving).
    /// Read-only: the editor asks it from its body, where publishing or writing ranges.json is not allowed.
    func refusal(for next: RedScreenProgram) -> String? {
        let now = clock()
        let current = brought(now)
        guard let strong = RedScreenRules.strongest(current.windows),
              let reason = RedScreenRules.weakening(from: current.value, to: next, hasPassword: passwordAvailable()) else { return nil }
        return "Plage protégée en cours (\(strong.lock.title.lowercased())) : \(reason) \(Self.lockedText(until: strong.end, now: now))"
    }
    private func commitRanges(_ next: RedScreenProgram) throws {
        // A stopped engine says so: a silent no-op would let the page show a rule that was never written.
        guard running else { throw Self.stopped }
        if let message = refusal(for: next) { throw RedScreenRefusal(message: message, isLock: true) }
        var value = next; value.sanitize()
        ranges = value; errorMessage = nil; saveRangesNow(); evaluate()
    }

    // MARK: Evaluation

    /// The ranges brought to `now`, without touching any state: each hold ends on the continuous clock of the blocks
    /// (`BlockingClock`, counts during sleep, ignores clock changes) within its boot, and on the wall clock after a reboot
    /// (the blocks' rule without a sample of this boot); stale skips and raise dropped; protected windows held.
    private func brought(_ now: Date) -> (value: RedScreenProgram, windows: [RedScreenWindow]) {
        let up = continuous(), boot = bootID()
        var value = ranges
        for (id, hold) in value.holds {
            if hold.boot == boot, let deadline = hold.deadline {
                let remaining = deadline - up
                if remaining <= 0 { value.holds[id] = nil }
                // The end shown follows the continuous clock: a clock set forward or back moves it, the time left stays.
                else if abs(hold.end.timeIntervalSince(now) - remaining) > 1 { value.holds[id]?.end = now.addingTimeInterval(remaining) }
            } else if hold.end <= now { value.holds[id] = nil }
        }
        for (id, date) in value.skips where date <= now { value.skips[id] = nil }
        if let raise = value.raise, raise.until <= now { value.raise = nil }
        if var lock = value.brightnessLock, let end = lock.end {
            // Same clock as a range hold: continuous within the boot, wall after a reboot.
            var over = false
            if lock.boot == boot, let deadline = lock.deadline {
                let remaining = deadline - up
                if remaining <= 0 { over = true }
                else if abs(end.timeIntervalSince(now) - remaining) > 1 { lock.end = now.addingTimeInterval(remaining) }
            } else if end <= now { over = true }
            else if lock.effectiveLock != .free { lock.boot = boot; lock.deadline = up + end.timeIntervalSince(now) }
            // The protection is over: the lock stays on at its level, « Libre ».
            if over { lock.lock = nil; lock.end = nil; lock.deadline = nil; lock.boot = nil }
            value.brightnessLock = lock
        }
        let windows = RedScreenRules.activeWindows(value, at: now, calendar: calendar, hasPassword: passwordAvailable())
        for window in windows where window.isProtected {
            let held = value.holds[window.rangeID]
            var merged = held ?? RedScreenProgram.Hold(end: window.end, lock: window.lock, intensity: window.intensity, brightness: window.brightness)
            merged.lock = [window.lock, merged.lock].max { $0.strength < $1.strength }!
            merged.intensity = max(window.intensity, merged.intensity)
            merged.brightness = [window.brightness, merged.brightness].compactMap { $0 }.min()
            if held?.boot != boot || held?.deadline == nil || window.end > merged.end.addingTimeInterval(1) {
                merged.end = max(merged.end, window.end)
                merged.boot = boot; merged.deadline = up + merged.end.timeIntervalSince(now)
            }
            if held != merged { value.holds[window.rangeID] = merged }
        }
        return (value, windows)
    }

    /// Applies `brought(now)`: ranges.json is written when a hold, skip or raise changed.
    private func refreshWindows(_ now: Date) {
        let current = brought(now)
        if current.value != ranges { ranges = current.value; saveRangesNow() }
        // Published only when it changes: an equal value set again would ask every view for a new body.
        if current.windows != windows { windows = current.windows }
    }

    var isPaused: Bool { preferences.pauseUntil.map { $0 > clock() } ?? false }
    var stateLabel: String { isPaused ? "En pause" : active ? "Filtre actif" : "Couleurs naturelles" }
    /// The protected range in progress, if any.
    var protectedWindow: RedScreenWindow? { RedScreenRules.strongest(windows) }
    /// End of the latest protected range in progress (wall frame; a hold's end follows the continuous clock).
    /// Until then Goalong's guard is armed exactly as for a severe block (T-048 B4).
    var guardUntil: Date? { (windows.filter(\.isProtected).map(\.end) + [brightnessProtection?.end].compactMap { $0 }).max() }
    /// The strongest stop rule among the protected ranges and the brightness lock (the guard and « Quitter » read it).
    var guardLock: BlockLock {
        ([protectedWindow?.lock, brightnessProtection?.lock].compactMap { $0 }).max { $0.strength < $1.strength } ?? .free
    }
    /// The brightness lock's protection in progress (stop rule, end), nil when off or « Libre ».
    var brightnessProtection: (lock: BlockLock, end: Date)? {
        BrightnessLockRules.protection(ranges.brightnessLock, now: clock(), hasPassword: passwordAvailable())
    }
    var brightnessLock: BrightnessLockState? { ranges.brightnessLock }
    /// The controller's clock (the page's countdowns; the gallery freezes it).
    var now: Date { clock() }
    /// The driver loaded and at least one screen can be set.
    var canControlBrightness: Bool { brightnessDriver.isAvailable && brightnessDisplays.contains(where: \.controllable) }
    /// Corrections made by the lock since start (diagnostics, tests).
    var brightnessCorrections: Int { enforcer.corrections }
    /// One pass of the lock now (tests: the timer does not run without `runsTimers`).
    func enforceBrightnessNow() { enforcer.tick() }

    func evaluate() {
        guard running else { return }
        let now = clock()
        if let end = preferences.pauseUntil, end <= now { preferences.pauseUntil = nil; saveSoon() }
        if let end = previewUntil, end <= now { dropPreview() }
        refreshWindows(now)
        let paused = isPaused
        let manual = preferences.mode == .on && !paused
        // A pause hides the manual red and the free ranges, never a protected range.
        let shown = windows.filter { !paused || $0.isProtected }
        var rangeIntensity = shown.map(\.intensity).max()
        // The slider's raise strengthens the ranges in progress only (point 4 of review B2).
        if let raise = ranges.raise, raise.until > now, let level = rangeIntensity { rangeIntensity = max(level, raise.intensity) }
        if protectedWindow == nil, sliderNotice != nil { sliderNotice = nil }
        if brightnessProtection == nil, brightnessNotice != nil { brightnessNotice = nil }
        let target = BrightnessLockRules.target(manual: ranges.brightnessLock, windows: shown)
        if brightnessTarget != target { brightnessTarget = target }
        active = manual || rangeIntensity != nil
        appliedIntensity = max(manual ? preferences.intensity : 0, rangeIntensity ?? 0)
        let screen = previewed(target: target)
        enforcer.update(target: screen.brightness, displays: brightnessDisplays.filter(\.controllable).map(\.id))
        if screen.brightness == nil, preview?.brightness == nil, let before = previewBrightnessBefore {
            // Nothing holds the screens after the preview: they go back to where they were.
            for (id, level) in before { _ = brightnessDriver.setBrightness(level, of: id) }
        }
        if preview?.brightness == nil, previewBrightnessBefore != nil { previewBrightnessBefore = nil; store.savePreviewBrightness(nil) }
        gamma.set(active: screen.active, intensity: screen.active ? screen.intensity : preferences.intensity, brightness: preferences.brightness,
                  animated: preview == nil && runsTimers && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        boundaryTimer?.invalidate(); boundaryTimer = nil
        var events: [Date] = []
        if let end = preferences.pauseUntil { events.append(end) }
        if let next = RedScreenRules.nextBoundary(ranges, after: now, calendar: calendar) { events.append(next) }
        if let end = brightnessProtection?.end { events.append(end) }
        if runsTimers, let nearest = events.min() {
            let timer = Timer(fire: nearest, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
            timer.tolerance = 0.1; RunLoop.main.add(timer, forMode: .common); boundaryTimer = timer
        }
        nextEvent = eventText(now: now, paused: paused, manual: manual)
        stateChanged?()
    }

    private func eventText(now: Date, paused: Bool, manual: Bool) -> String {
        if let strong = protectedWindow { return "Plage protégée jusqu’à \(Self.clockText(strong.end))" }
        if paused, let end = preferences.pauseUntil { return "En pause jusqu’à \(Self.clockText(end))" }
        if let window = windows.max(by: { $0.end < $1.end }) { return "Plage en cours jusqu’à \(Self.clockText(window.end))" }
        if manual { return "Activé manuellement, sans horaire de fin" }
        let next = BlockingSchedule.windows(of: ranges.enabledProgram, at: now, calendar: calendar, endPolicy: .last)
            .filter { $0.start > now }.map(\.start).min()
        if let next { return "Prochaine plage \(Self.when(next))" }
        return "Aucune plage prévue"
    }

    /// « Verrouillé jusqu’à 07:00 (encore 2 h 05). »
    nonisolated static func lockedText(until end: Date, now: Date) -> String {
        "Verrouillé jusqu’à \(GoalongUIFormat.time(end)) (encore \(remainingText(end.timeIntervalSince(now))))."
    }
    nonisolated static func remainingText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d", minutes / 60, minutes % 60)
    }
    static func clockText(_ date: Date) -> String { GoalongUIFormat.time(date) }
    private static func when(_ date: Date) -> String { whenText(date, now: GoalongToday.now) }
    /// The weekday alone is clear for the next six days. A week away it is today's weekday again: add the date.
    nonisolated static func whenText(_ date: Date, now: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                   to: Calendar.current.startOfDay(for: date)).day ?? 0
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = days >= 7 ? "EEEE d MMMM" : "EEEE"; return "\(f.string(from: date)) à \(GoalongUIFormat.time(date))"
    }
    private func saveSoon() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.saveNow() }; saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }
    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        do { try store.save(preferences) } catch { errorMessage = "Réglages non enregistrés. Vérifiez l’espace et l’accès au dossier Braise." }
        saveRangesNow()
    }
    private func saveRangesNow() {
        do { try store.saveRanges(ranges) } catch { errorMessage = "Plages non enregistrées. Vérifiez l’espace et l’accès au dossier Braise." }
    }
    func persistCommand() throws {
        saveNow(); if errorMessage != nil { throw GoalongFocusError.storageFailed }
    }
    func probe() -> [[String: Any]] { gamma.probe() }
    var status: [String: Any] {
        let gains = ChannelGains(intensity: appliedIntensity, brightness: preferences.brightness)
        let guardWindow = protectedWindow
        return ["schema": 1, "module": "braise", "enabled": true, "mode": preferences.mode.rawValue,
                "follows": ranges.follows, "ranges": ranges.program.ranges.count, "rangesActive": windows.count,
                "protectedLock": guardWindow?.lock.rawValue ?? "", "protectedUntil": guardWindow.map { ISO8601DateFormatter().string(from: $0.end) } ?? "",
                "appliedIntensity": appliedIntensity,
                "active": active, "paused": isPaused, "intensity": preferences.intensity,
                "brightness": preferences.brightness, "displayCount": displayCount, "nextEvent": nextEvent,
                "shortcutAvailable": shortcutAvailable, "error": errorMessage ?? "",
                "loginEnabled": loginEnabled, "loginApprovalRequired": loginApprovalRequired,
                "brightnessLock": ranges.brightnessLock?.level ?? -1, "brightnessTarget": brightnessTarget ?? -1,
                "brightnessLockProtectedUntil": brightnessProtection.map { ISO8601DateFormatter().string(from: $0.end) } ?? "",
                "brightnessControllableDisplays": brightnessDisplays.filter(\.controllable).count,
                "softwareGains": ["red": active ? gains.red : 1, "green": active ? gains.green : 1, "blue": active ? gains.blue : 1]]
    }
    func shutdown() {
        guard running else { return }
        running = false; boundaryTimer?.invalidate(); boundaryTimer = nil
        maintenanceTimer?.invalidate(); maintenanceTimer = nil
        for (center, token) in observers { center.removeObserver(token) }; observers = []
        dropPreview()
        if let before = previewBrightnessBefore {
            for (id, level) in before { _ = brightnessDriver.setBrightness(brightnessTarget ?? level, of: id) }
            previewBrightnessBefore = nil; store.savePreviewBrightness(nil)
        }
        enforcer.stop(); saveNow(); gamma.restore(); active = false; gamma.onError = nil; gamma.onDisplays = nil; stateChanged = nil
    }
}
#endif
