#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import Sparkle

    /// Owns LocalHistory's Sparkle lifecycle and exposes a deliberately quiet update surface.
    /// Scheduled checks use Sparkle's gentle-reminder API so background checks never steal focus;
    /// the dashboard instead shows a compact button when an update is available.
    @MainActor
    final class SoftwareUpdateManager: NSObject, ObservableObject {
        static let shared = SoftwareUpdateManager()

        @Published private(set) var isConfigured = false
        @Published private(set) var isChecking = false
        @Published private(set) var availableVersion: String?
        @Published private(set) var automaticallyChecksForUpdates = false
        @Published private(set) var statusMessage = "Updates are available in signed release builds."

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
                statusMessage = "Software updates are disabled in this development build."
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
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
            statusMessage = automaticallyChecksForUpdates
                ? "Signed update checks run automatically."
                : "Automatic update checks are off."
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

        func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
            guard let updater = updaterController?.updater else { return }
            updater.automaticallyChecksForUpdates = enabled
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            statusMessage = automaticallyChecksForUpdates
                ? "Signed update checks run automatically."
                : "Automatic update checks are off."
        }

        private func markAvailable(_ item: SUAppcastItem) {
            availableVersion = item.displayVersionString
            isChecking = false
            userAttendedCurrentUpdate = false
            statusMessage = "LocalHistory \(item.displayVersionString) is available."
        }

        private func markUpToDate() {
            availableVersion = nil
            isChecking = false
            statusMessage = "LocalHistory is up to date."
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
            // LocalHistory is a dockless menu-bar app. Scheduled checks stay quiet even immediately
            // after launch; the dashboard indicator is the reminder. Explicit user checks still use
            // Sparkle's complete standard UI, including release notes and installation progress.
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
            if userAttendedCurrentUpdate {
                availableVersion = nil
                userAttendedCurrentUpdate = false
                statusMessage = "The update reminder was dismissed. Sparkle will check again later."
            }
        }
    }
#endif
