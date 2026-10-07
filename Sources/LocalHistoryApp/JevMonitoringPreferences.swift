#if os(macOS)
import Combine
import Foundation

enum JevMonitoringScope: String, Codable, CaseIterable {
    case always, sessionsOnly
    func permits(sessionActive: Bool) -> Bool { self == .always || sessionActive }
}

extension Notification.Name {
    static let jevMonitoringScopeDidChange = Notification.Name("goalong.jev.scope.changed")
    static let goalongFocusSessionDidChange = Notification.Name("goalong.focus.session.changed")
}

/// A missing pre-scope setting keeps the old behavior; corrupt/unknown settings fail closed.
@MainActor final class JevMonitoringPreferences: ObservableObject {
    static let shared = JevMonitoringPreferences()
    static let storageKey = "goalong.jev.scope.v1"
    private struct Document: Codable { var schema = 1; var scope: JevMonitoringScope }
    @Published private(set) var scope: JevMonitoringScope = .always
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= 1024,
              let value = try? JSONDecoder().decode(Document.self, from: data), value.schema == 1 else {
            scope = .sessionsOnly
            error = "Périmètre de surveillance illisible : enregistrez à nouveau votre choix."
            return
        }
        scope = value.scope
    }
    func setScope(_ value: JevMonitoringScope) {
        guard let data = try? JSONEncoder().encode(Document(scope: value)) else { return }
        defaults.set(data, forKey: Self.storageKey)
        scope = value; error = nil
        NotificationCenter.default.post(name: .jevMonitoringScopeDidChange, object: self)
    }
}
#endif
