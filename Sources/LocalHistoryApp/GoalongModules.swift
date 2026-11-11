#if os(macOS)
import Foundation
import AppleScreenTime

/// Optional parts of Goalong, off by default. Off means nothing runs: no controller, timer,
/// observer, window, file or permission request. Key: `goalong.module.<id>.enabled`.
enum GoalongModule: String, CaseIterable, Identifiable {
    case blocking
    case concentration
    case ambiance
    case braise

    var id: String { rawValue }
    /// Réglages › Modules. The red screen (`.braise`) needs no activation: it lives in Goalong's menu, so a
    /// module switch would duplicate its on/off. The case stays only to migrate the old key (BraiseRuntime).
    static let listed: [GoalongModule] = allCases.filter { $0 != .braise && $0 != .concentration }
    /// T-050 lot C: « Garde-fous » is one row, one switch. It carries both parts; their keys and stops stay separate.
    static let guardrailParts: [GoalongModule] = [.blocking, .concentration]
    var defaultsKey: String { "goalong.module.\(rawValue).enabled" }

    var title: String {
        switch self {
        case .blocking: return "Garde-fous"
        case .concentration: return "Garde-fous"
        case .ambiance: return "Ambiance"
        case .braise: return "Écran rouge"
        }
    }

    var summary: String {
        switch self {
        case .concentration: return "Lancer des séances et des Pomodoro, préparer le plan du jour, lire le bilan. Le Terminal peut suivre la séance en cours."
        case .blocking: return "Bloquer des sites et des apps, lancer des séances et des Pomodoro, préparer le plan du jour, lire le bilan, verrouiller, bloquer tout le Mac. Le Terminal peut suivre la séance en cours."
        case .ambiance: return "De la musique pour travailler ou souffler, téléchargée à la demande."
        case .braise: return "Filtre rouge, luminosité et horaires, sans accès supplémentaire."
        }
    }

    var symbol: String {
        switch self {
        case .blocking: return "lock"
        case .concentration: return "scope"
        case .ambiance: return "waveform"
        case .braise: return "sun.horizon"
        }
    }
}

/// Reading a module's switch is cheap and never starts the module.
final class GoalongModuleStore: ObservableObject {
    static let shared = GoalongModuleStore()

    @Published private(set) var enabled: Set<GoalongModule>
    private let defaults: UserDefaults
    var blockingDisableCheck: (() -> Bool)?
    var concentrationDisableCheck: (() -> Bool)?
    var onConcentrationEnabledChange: ((Bool) -> Void)?
    var onBraiseEnabledChange: ((Bool) -> Void)?
    var onBlockingEnabledChange: ((Bool) -> Void)?

    init(defaults: UserDefaults = GoalongDefaults.standard) {
        self.defaults = defaults
        enabled = Set(GoalongModule.allCases.filter { defaults.bool(forKey: $0.defaultsKey) })
    }

    func isEnabled(_ module: GoalongModule) -> Bool { enabled.contains(module) }

    /// True when the module's own check would refuse turning it off. Changes nothing.
    func refusesDisabling(_ module: GoalongModule) -> Bool {
        switch module {
        case .blocking: return blockingDisableCheck?() == false
        case .concentration: return concentrationDisableCheck?() == false
        default: return false
        }
    }

    /// T-050 lot C2: once at launch. Only one part of « Garde-fous » on (an old mixed state): turn the missing part on.
    /// Nothing is ever turned off here.
    func alignGuardrailParts() {
        for module in GuardrailSwitchPlan.partsToTurnOn(enabled: enabled) { setEnabled(module, true) }
    }

    func setEnabled(_ module: GoalongModule, _ value: Bool) {
        guard value != isEnabled(module) else { return }
        if module == .blocking, !value, blockingDisableCheck?() == false { return }
        if module == .concentration, !value, concentrationDisableCheck?() == false { return }
        defaults.set(value, forKey: module.defaultsKey)
        if value { enabled.insert(module) } else { enabled.remove(module) }
        if module == .braise { onBraiseEnabledChange?(value) }
        if module == .blocking { onBlockingEnabledChange?(value) }
        if module == .concentration { onConcentrationEnabledChange?(value) }
        NotificationCenter.default.post(name: .goalongModulesDidChange, object: self)
    }
}

/// T-050 lot C2: the decisions behind the « Garde-fous » switch, pure so a test can pin them.
enum GuardrailSwitchPlan: Equatable {
    /// `stops`: every distinct stop to ask, each once, before anything changes. `parts`: what to switch, in order.
    case go(stops: [JevStopGate.Step], parts: [GoalongModule])
    /// A part refuses turning off: nothing changes, no stop is asked.
    case refused(by: GoalongModule)

    /// Off: Concentration first (its session), then Blocage. On: Blocage, then Concentration.
    /// A part already in the wanted state is left alone.
    @MainActor static func plan(parts: [GoalongModule], turningOn value: Bool, isEnabled: (GoalongModule) -> Bool,
                     refuses: (GoalongModule) -> Bool, step: (GoalongModule) -> JevStopGate.Step) -> GuardrailSwitchPlan {
        let changing = (value ? parts : parts.reversed()).filter { isEnabled($0) != value }
        if !value, let part = changing.first(where: refuses) { return .refused(by: part) }
        var stops: [JevStopGate.Step] = []
        if !value {
            for part in changing {
                let one = step(part)
                if JevStopGate.needsAsking(one), !stops.contains(one) { stops.append(one) }
            }
        }
        return .go(stops: stops, parts: changing)
    }

    /// What to switch once the stops were asked: any refusal changes nothing.
    static func parts(_ plan: GuardrailSwitchPlan, stopAnswers: [Bool]) -> [GoalongModule] {
        guard case .go(let stops, let parts) = plan, stopAnswers.count == stops.count, !stopAnswers.contains(false) else { return [] }
        return parts
    }

    /// Mixed state: exactly one part of « Garde-fous » is on. Returns the missing part(s). Never an « off ».
    static func partsToTurnOn(enabled: Set<GoalongModule>) -> [GoalongModule] {
        let on = GoalongModule.guardrailParts.filter { enabled.contains($0) }
        return on.isEmpty || on.count == GoalongModule.guardrailParts.count ? [] : GoalongModule.guardrailParts.filter { !enabled.contains($0) }
    }
}

extension Notification.Name {
    static let goalongModulesDidChange = Notification.Name("ai.goalong.modules.didChange")
}
#endif
