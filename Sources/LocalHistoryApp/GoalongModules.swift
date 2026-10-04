#if os(macOS)
import Foundation

/// Optional parts of Goalong, off by default. Off means nothing runs: no controller, timer,
/// observer, window, file or permission request. Key: `goalong.module.<id>.enabled`.
enum GoalongModule: String, CaseIterable, Identifiable {
    case blocking
    case concentration
    case ambiance

    var id: String { rawValue }
    var defaultsKey: String { "goalong.module.\(rawValue).enabled" }

    var title: String {
        switch self {
        case .blocking: return "Blocage"
        case .concentration: return "Concentration"
        case .ambiance: return "Ambiance"
        }
    }

    var summary: String {
        switch self {
        case .concentration: return "Séances, Pomodoro, plan du jour et bilan, statut."
        case .blocking: return "Bloquer des sites et des apps, verrouiller un blocage, geler le Mac."
        case .ambiance: return "De la musique pour travailler ou souffler, téléchargée à la demande."
        }
    }

    var symbol: String {
        switch self {
        case .blocking: return "lock"
        case .concentration: return "scope"
        case .ambiance: return "waveform"
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
    var onBlockingEnabledChange: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard) {
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
        if module == .blocking { onBlockingEnabledChange?(value) }
        if module == .concentration { onConcentrationEnabledChange?(value) }
        NotificationCenter.default.post(name: .goalongModulesDidChange, object: self)
    }
}

extension Notification.Name {
    static let goalongModulesDidChange = Notification.Name("ai.goalong.modules.didChange")
}
#endif
