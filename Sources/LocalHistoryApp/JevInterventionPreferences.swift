#if os(macOS)
import Combine
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let jevInterventionsDidChange = Notification.Name("goalong.jev.interventions.changed")
}

@MainActor final class JevInterventionPreferences: ObservableObject {
    static let shared = JevInterventionPreferences()
    static let storageKey = "goalong.jev.interventions.v3"
    static let previousStorageKey = "goalong.jev.interventions.v2"
    static let legacyStorageKey = "goalong.jev.interventions.v1"
    @Published private(set) var settings: JevInterventionSettings
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = .init()
        if defaults.object(forKey: Self.storageKey) != nil {
            // Never fall back to an older enabled configuration if the current configuration is unreadable.
            guard let data = defaults.data(forKey: Self.storageKey), data.count <= 4096,
                  let value = try? JSONDecoder().decode(JevInterventionSettings.self, from: data), value.isValid else {
                error = "Paliers illisibles : effets désactivés. Enregistrez à nouveau vos choix."
                return
            }
            settings = value
        } else if let oldKey = [Self.previousStorageKey, Self.legacyStorageKey].first(where: { defaults.object(forKey: $0) != nil }) {
            guard let data = defaults.data(forKey: oldKey), data.count <= 4096,
                  let legacy = try? JSONDecoder().decode(JevInterventionSettings.self, from: data),
                  legacy.schemaVersion == (oldKey == Self.previousStorageKey ? 2 : 1),
                  let value = legacy.migratingLegacy(), let upgraded = try? JSONEncoder().encode(value) else {
                error = "Paliers illisibles : effets désactivés. Enregistrez à nouveau vos choix."
                return
            }
            settings = value
            // Keep the old key intact for rollback; never increase or enable effects on upgrade.
            defaults.set(upgraded, forKey: Self.storageKey)
        }
    }

    func update(_ edit: (inout JevInterventionSettings) -> Void) {
        var next = settings; edit(&next)
        guard next.isValid, let data = try? JSONEncoder().encode(next) else {
            error = "Choisissez deux paliers croissants entre 1 et 60 minutes, une intensité de 10 à 85 % et un dernier palier assombrissement + rouge."
            return
        }
        defaults.set(data, forKey: Self.storageKey)
        settings = next; error = nil
        NotificationCenter.default.post(name: .jevInterventionsDidChange, object: self)
    }
}
#endif
