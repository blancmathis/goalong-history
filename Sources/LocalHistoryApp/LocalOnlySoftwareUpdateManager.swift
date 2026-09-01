#if os(macOS)
    import Combine
    import Foundation

    enum SoftwareUpdatePresentationAction: Equatable {
        case present
        case prepare
        case wait
        case check
    }

    enum SoftwareUpdateUserRequest: Equatable {
        case presentAvailableUpdate
        case checkForUpdates
    }

    struct SoftwareUpdatePresentationState: Equatable {
        private(set) var detectedVersion: String?
        private(set) var availableVersion: String?
        private(set) var isReady = false
        private(set) var pendingRequest: SoftwareUpdateUserRequest?

        var hasPendingRequest: Bool { pendingRequest != nil }
    }

    /// The single public app deliberately contains no in-process update transport.
    /// Updates are installed manually, so the FDA-capable application process never
    /// links Sparkle or owns an automatic network path.
    @MainActor
    final class SoftwareUpdateManager: ObservableObject {
        static let shared = SoftwareUpdateManager()

        @Published private(set) var isConfigured = false
        @Published private(set) var isChecking = false
        @Published private(set) var presentationState = SoftwareUpdatePresentationState()
        @Published private(set) var automaticallyChecksForUpdates = false
        @Published private(set) var requiresSignedBuild = false
        @Published private(set) var statusMessage =
            "Automatic update checks are not present. Install reviewed releases manually."

        var availableVersion: String? { nil }
        var isPreparingAvailableUpdate: Bool { false }
        var currentVersion: String {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? "development"
        }
        var canCheckForUpdates: Bool { false }

        private init() {}

        func start() {}
        func stop() {}
        func refreshAvailableUpdate() {}
        func checkForUpdates() {}
        func showAvailableUpdate() {}
        func openRollingReleasePage() {}
        func setAutomaticallyChecksForUpdates(_: Bool) {}
    }
#endif
