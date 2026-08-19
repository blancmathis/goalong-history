#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import Sparkle

    /// Owns the Sparkle lifecycle and exposes a quiet update surface in the dashboard.
    /// Release builds check the rolling main-channel feed immediately at launch. Development/source
    /// builds cannot safely self-update because they do not contain the release EdDSA key; those
    /// builds instead offer a one-time migration to the latest update-enabled release.
    @MainActor
    final class SoftwareUpdateManager: NSObject, ObservableObject {
        static let shared = SoftwareUpdateManager()

        @Published private(set) var isConfigured = false
        @Published private(set) var isChecking = false
        @Published private(set) var availableVersion: String?
        @Published private(set) var automaticallyChecksForUpdates = false
        @Published private(set) var requiresSignedBuild = false
        @Published private(set) var statusMessage = "Updates are available in update-enabled release builds."

        private var updaterController: SPUStandardUpdaterController?
        private var hasStarted = false
        private var userAttendedCurrentUpdate = false

        var currentVersion: String {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? "development"
        }

        var canCheckForUpdates: Bool {
            isConfigured && (updaterController?.updater.canCheckForUpdates ?? false)
        }

        private override init() {
            super.init()
        }

        func start() {
            guard !hasStarted else { return }
            hasStarted = true

            guard Self.hasValidSparkleConfiguration(in: .main) else {
                requiresSignedBuild = true
                statusMessage = "Install the release build once to enable in-app updates."
                return
            }

            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            updaterController = controller
            controller.startUpdater()

            isConfigured = true
            requiresSignedBuild = false
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
            statusMessage = automaticallyChecksForUpdates
                ? "Verified update checks run automatically."
                : "Automatic update checks are off."

            // Sparkle's scheduled interval may not be due yet, especially on a freshly installed
            // build. Perform one quiet check now so the dashboard button reflects the current Git
            // release without waiting up to a day.
            DispatchQueue.main.async { [weak self] in
                self?.refreshAvailableUpdate()
            }
        }

        func refreshAvailableUpdate() {
            guard let updater = updaterController?.updater, updater.canCheckForUpdates else { return }
            guard !isChecking else { return }
            isChecking = true
            statusMessage = "Checking for updates…"
            updater.checkForUpdateInformation()
        }

        func checkForUpdates() {
            guard let updater = updaterController?.updater else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            isChecking = true
            statusMessage = "Checking for updates…"
            updater.checkForUpdates()
        }

        func showAvailableUpdate() {
            guard availableVersion != nil else {
                checkForUpdates()
                return
            }
            guard let updater = updaterController?.updater else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            updater.checkForUpdates()
        }

        func installUpdateEnabledBuild() {
            statusMessage = "Downloading the latest release build…"
            NSWorkspace.shared.open(ProductIdentity.rollingDMGURL)
        }

        func openRollingReleasePage() {
            NSWorkspace.shared.open(ProductIdentity.rollingReleasePageURL)
        }

        func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
            guard let updater = updaterController?.updater else { return }
            updater.automaticallyChecksForUpdates = enabled
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            statusMessage = automaticallyChecksForUpdates
                ? "Verified update checks run automatically."
                : "Automatic update checks are off."
        }

        private func markAvailable(_ item: SUAppcastItem) {
            availableVersion = item.displayVersionString
            isChecking = false
            userAttendedCurrentUpdate = false
            statusMessage = "\(ProductIdentity.displayName) \(item.displayVersionString) is available."
        }

        private func markUpToDate() {
            availableVersion = nil
            isChecking = false
            statusMessage = "\(ProductIdentity.displayName) is up to date."
        }

        private static func hasValidSparkleConfiguration(in bundle: Bundle) -> Bool {
            guard bundle.bundleURL.pathExtension == "app" else { return false }
            guard
                let feedString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                let feedURL = URL(string: feedString),
                feedURL.scheme?.lowercased() == "https"
            else { return false }

            guard
                let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                Data(base64Encoded: publicKey)?.count == 32
            else { return false }

            return true
        }
    }

    extension SoftwareUpdateManager: SPUUpdaterDelegate {
        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            markAvailable(item)
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
            markUpToDate()
        }

        func updater(
            _ updater: SPUUpdater,
            didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
            error: (any Error)?
        ) {
            isChecking = false
            if error != nil, availableVersion == nil, statusMessage == "Checking for updates…" {
                statusMessage = "The update check could not be completed. Try again later."
            }
        }
    }

    extension SoftwareUpdateManager: @preconcurrency SPUStandardUserDriverDelegate {
        var supportsGentleScheduledUpdateReminders: Bool { true }

        func standardUserDriverShouldHandleShowingScheduledUpdate(
            _ update: SUAppcastItem,
            andInImmediateFocus immediateFocus: Bool
        ) -> Bool {
            // Background checks stay quiet; the dashboard indicator is the reminder. Explicit user
            // checks still use Sparkle's complete standard release-notes and installation flow.
            false
        }

        func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool,
            forUpdate update: SUAppcastItem,
            state: SPUUserUpdateState
        ) {
            if !handleShowingUpdate {
                markAvailable(update)
            }
        }

        func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            userAttendedCurrentUpdate = true
        }

        func standardUserDriverWillFinishUpdateSession() {
            isChecking = false
            guard userAttendedCurrentUpdate else { return }
            userAttendedCurrentUpdate = false
            if let availableVersion {
                statusMessage = "\(ProductIdentity.displayName) \(availableVersion) is still available."
            }
        }
    }
#endif
