import Foundation

/// Preferences only: no runtime, directory lookup, observation or audio preparation.
public struct AmbianceSettings {
    public static let enabledKey = "goalong.module.ambiance.enabled"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
    public var volume: Double {
        get { Self.clamp(defaults.object(forKey: "goalong.module.ambiance.volume") as? Double ?? 0.5) }
        nonmutating set { defaults.set(Self.clamp(newValue), forKey: "goalong.module.ambiance.volume") }
    }
    public var ownFiles: [String] {
        get { defaults.stringArray(forKey: "goalong.module.ambiance.ownFiles") ?? [] }
        nonmutating set { defaults.set(newValue, forKey: "goalong.module.ambiance.ownFiles") }
    }
    public var lastSource: String? {
        get { defaults.string(forKey: "goalong.module.ambiance.lastSource") }
        nonmutating set { defaults.set(newValue, forKey: "goalong.module.ambiance.lastSource") }
    }
    static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
}
