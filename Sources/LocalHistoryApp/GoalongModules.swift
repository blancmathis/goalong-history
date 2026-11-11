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

extension Notification.Name {
    static let goalongModulesDidChange = Notification.Name("ai.goalong.modules.didChange")
}
#endif
