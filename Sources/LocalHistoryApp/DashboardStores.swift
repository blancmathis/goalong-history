#if os(macOS)
    import Foundation
    import LocalHistoryCore

    // R14b: the dashboard's state, split by what changes together. A view observes only the objects it reads, so a
    // publication re-evaluates only the views that show it. Rule (`make audit`): a view reads one of these objects
    // only through an `@ObservedObject` (or `@EnvironmentObject`) of its own, never as `model.<object>.<property>`:
    // an unobserved read would leave the screen frozen. Each setter publishes only a changed value.

    /// What the dashboard identifies this Mac as (rare: rotation, degraded keychain).
    final class DashboardDeviceState: ObservableObject {
        @Published private(set) var deviceID: String
        /// Nil while the identity is degraded and no earlier device ID is known: Screen Time and ChatGPT stay off.
        @Published private(set) var knownDeviceID: String?
        @Published private(set) var deviceTrustTier: String
        @Published private(set) var deviceAlgorithm: String
        @Published private(set) var deviceProtectionTitle: String
        /// No view reads it (searched by name): it does not publish.
        private(set) var deviceProtectionSummary: String
        /// Changed or degraded trust state (rotation, sealing suspended), shown in the integrity section.
        @Published private(set) var trustNotices: [String] = []

        init(_ info: DeviceIdentityInfo) {
            deviceID = info.deviceID
            knownDeviceID = info.knownDeviceID
            deviceTrustTier = info.trustTier
            deviceAlgorithm = info.algorithm
            deviceProtectionTitle = info.protectionTitle
            deviceProtectionSummary = info.protectionSummary
        }

        func update(_ info: DeviceIdentityInfo) {
            if deviceID != info.deviceID { deviceID = info.deviceID }
            if knownDeviceID != info.knownDeviceID { knownDeviceID = info.knownDeviceID }
            if deviceTrustTier != info.trustTier { deviceTrustTier = info.trustTier }
            if deviceAlgorithm != info.algorithm { deviceAlgorithm = info.algorithm }
            if deviceProtectionTitle != info.protectionTitle { deviceProtectionTitle = info.protectionTitle }
            deviceProtectionSummary = info.protectionSummary
        }

        func setTrustNotices(_ notices: [String]) {
            if trustNotices != notices { trustNotices = notices }
        }
    }

    /// The dashboard's alert, and the signed export running behind it.
    final class DashboardAlertCenter: ObservableObject {
        /// Set by the model on an error; a view's `.alert(item:)` clears it.
        @Published var alert: DashboardAlert?
        @Published private(set) var isExportingShare = false

        func setExportingShare(_ exporting: Bool) {
            if isExportingShare != exporting { isExportingShare = exporting }
        }
    }
#endif
