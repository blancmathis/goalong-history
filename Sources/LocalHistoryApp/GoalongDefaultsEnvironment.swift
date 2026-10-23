import SwiftUI

/// The preferences a view reads outside `@AppStorage`. The app keeps `.standard`; tests and the gallery pass their own
/// suite with `.environment(\.goalongDefaults, suite)`, next to `.defaultAppStorage(suite)`.
private struct GoalongDefaultsKey: EnvironmentKey {
    static let defaultValue = UserDefaults.standard
}

extension EnvironmentValues {
    var goalongDefaults: UserDefaults {
        get { self[GoalongDefaultsKey.self] }
        set { self[GoalongDefaultsKey.self] = newValue }
    }
}
