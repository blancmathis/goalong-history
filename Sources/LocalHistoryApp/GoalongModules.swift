#if os(macOS)
import Foundation

/// Optional parts of Goalong, off by default. Off means nothing runs: no controller, timer,
/// observer, window, file or permission request. Key: `goalong.module.<id>.enabled`.
enum GoalongModule: String, CaseIterable, Identifiable {
    case blocking

    var id: String { rawValue }
    var defaultsKey: String { "goalong.module.\(rawValue).enabled" }

    var title: String {
        switch self {
        case .blocking: return "Blocage"
        }
    }

    var summary: String {
        switch self {
        case .blocking: return "Bloquer des sites et des apps, verrouiller un blocage, geler le Mac."
        }
    }

    var symbol: String {
        switch self {
        case .blocking: return "lock"
        }
    }
}

/// Reading a module's switch is cheap and never starts the module.
final class GoalongModuleStore: ObservableObject {
    static let shared = GoalongModuleStore()

    @Published private(set) var enabled: Set<GoalongModule>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = Set(GoalongModule.allCases.filter { defaults.bool(forKey: $0.defaultsKey) })
    }

    func isEnabled(_ module: GoalongModule) -> Bool { enabled.contains(module) }

    func setEnabled(_ module: GoalongModule, _ value: Bool) {
        guard value != isEnabled(module) else { return }
        defaults.set(value, forKey: module.defaultsKey)
        if value { enabled.insert(module) } else { enabled.remove(module) }
        NotificationCenter.default.post(name: .goalongModulesDidChange, object: self)
    }
}

extension Notification.Name {
    static let goalongModulesDidChange = Notification.Name("ai.goalong.modules.didChange")
}
#endif
