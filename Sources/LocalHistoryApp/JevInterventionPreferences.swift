#if os(macOS)
import Combine
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let jevInterventionsDidChange = Notification.Name("goalong.jev.interventions.changed")
}

@MainActor final class JevInterventionPreferences: ObservableObject {
    static let shared = JevInterventionPreferences()
    static let storageKey = "goalong.jev.interventions.v1"
    @Published private(set) var settings: JevInterventionSettings
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            if data.count <= 4096, let value = try? JSONDecoder().decode(JevInterventionSettings.self, from: data), value.isValid {
                settings = value
            } else {
                settings = .init()
                error = "Paliers illisibles : effets désactivés. Enregistrez à nouveau vos choix."
            }
        } else { settings = .init() }
    }
    func update(_ edit: (inout JevInterventionSettings) -> Void) {
        var next = settings; edit(&next)
        guard next.isValid, let data = try? JSONEncoder().encode(next) else {
            error = "Choisissez trois paliers croissants entre 1 et 60 minutes, et une intensité de 10 à 40 %."
            return
        }
        defaults.set(data, forKey: Self.storageKey)
        settings = next; error = nil
        NotificationCenter.default.post(name: .jevInterventionsDidChange, object: self)
    }
}
#endif
