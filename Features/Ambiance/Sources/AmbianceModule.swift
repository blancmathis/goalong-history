import Foundation

/// Cheap app-model gate. The directory closure and controller factory are never
/// evaluated while disabled. Turning off also cancels pending pack installation.
@MainActor public final class AmbianceModule {
    public let settings: AmbianceSettings
    private let supportDirectory: () -> URL
    private var storage: AmbianceController?
    public init(settings: AmbianceSettings = AmbianceSettings(), supportDirectory: @escaping () -> URL) {
        self.settings = settings; self.supportDirectory = supportDirectory
    }
    public var controller: AmbianceController? {
        guard settings.isEnabled else {
            storage?.shutdown(); storage = nil
            return nil
        }
        if storage == nil { storage = AmbianceController(settings: settings, supportDirectory: supportDirectory()) }
        return storage
    }
    public func setEnabled(_ enabled: Bool) {
        if !enabled { storage?.shutdown(); storage = nil }
        settings.isEnabled = enabled
    }
}
