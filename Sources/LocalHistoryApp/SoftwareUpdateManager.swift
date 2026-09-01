#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import Sparkle

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

        var hasPendingRequest: Bool {
            pendingRequest != nil
        }

        mutating func recordDetected(version: String) {
            detectedVersion = version
        }

        @discardableResult
        mutating func recordReady(version: String) -> Bool {
            detectedVersion = version
            availableVersion = version
            isReady = true

            return pendingRequest != nil
        }

        mutating func requestAvailableUpdate(hasActiveSession: Bool) -> SoftwareUpdatePresentationAction {
            pendingRequest = .presentAvailableUpdate
            if isReady, hasActiveSession {
                return .present
            }

            isReady = false
            return hasActiveSession ? .wait : .prepare
        }

        mutating func requestUpdateCheck(hasActiveSession: Bool) -> SoftwareUpdatePresentationAction {
            pendingRequest = .checkForUpdates
            if isReady, hasActiveSession {
                return .present
            }

            return hasActiveSession ? .wait : .check
        }

        mutating func recordSessionFinished() {
            isReady = false
        }

        mutating func recordNoUpdate() {
            detectedVersion = nil
            availableVersion = nil
            isReady = false
            if pendingRequest == .presentAvailableUpdate {
                pendingRequest = nil
            }
        }

        mutating func recordUserAttention() {
            pendingRequest = nil
        }

        mutating func cancelPendingRequest() {
            pendingRequest = nil
        }

        mutating func clear() {
            self = SoftwareUpdatePresentationState()
        }
    }

    /// Owns the Sparkle lifecycle and exposes a quiet update surface in the dashboard.
    /// Release builds check the rolling main-channel feed immediately at launch. Development/source
    /// builds fail closed because they do not contain the release EdDSA key and must never offer an
    /// older public artifact that could reintroduce retired transcript-vault behavior.
    @MainActor
    final class SoftwareUpdateManager: NSObject, ObservableObject {
        static let shared = SoftwareUpdateManager()

        @Published private(set) var isConfigured = false
        @Published private(set) var isChecking = false
        @Published private(set) var presentationState = SoftwareUpdatePresentationState()
        @Published private(set) var automaticallyChecksForUpdates = false
        @Published private(set) var requiresSignedBuild = false
        @Published private(set) var statusMessage = "Updates are available in update-enabled release builds."

        private var updaterController: SPUStandardUpdaterController?
        private var hasStarted = false
        private var userAttendedCurrentUpdate = false

        var availableVersion: String? {
            presentationState.availableVersion
        }

        var isPreparingAvailableUpdate: Bool {
            presentationState.hasPendingRequest
        }

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
                statusMessage = "In-app updates are disabled in this privacy-audited source build."
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
            // build. Start one quiet update session now so the dashboard button reflects the
            // current Git release without waiting up to a day. Keeping Sparkle's scheduled session
            // alive also lets a click on that button reveal the already-found update immediately,
            // instead of performing a second user-visible feed check.
            DispatchQueue.main.async { [weak self] in
                self?.refreshAvailableUpdate()
            }
        }

        func stop() {
            guard hasStarted else { return }
            updaterController = nil
            hasStarted = false
            isConfigured = false
            isChecking = false
            automaticallyChecksForUpdates = false
            presentationState = SoftwareUpdatePresentationState()
            statusMessage = "Automatic update checks are off."
        }

        func refreshAvailableUpdate() {
            guard let updater = updaterController?.updater, updater.canCheckForUpdates else { return }
            guard !updater.sessionInProgress else { return }
            guard !isChecking else { return }
            isChecking = true
            statusMessage = presentationState.availableVersion == nil
                ? "Checking for updates…"
                : "Preparing the detected update…"
            updater.checkForUpdatesInBackground()
        }

        func checkForUpdates() {
            guard let updater = updaterController?.updater else { return }

            switch presentationState.requestUpdateCheck(hasActiveSession: updater.sessionInProgress) {
            case .present:
                presentReadyUpdate()
            case .wait:
                isChecking = true
                statusMessage = "Finishing the current update check…"
            case .check:
                startUserInitiatedCheck()
            case .prepare:
                break
            }
        }

        func showAvailableUpdate() {
            guard let availableVersion = presentationState.availableVersion else {
                checkForUpdates()
                return
            }
            guard let updater = updaterController?.updater else { return }

            switch presentationState.requestAvailableUpdate(hasActiveSession: updater.sessionInProgress) {
            case .present:
                presentReadyUpdate()
            case .prepare:
                // A dismissed Sparkle alert ends its update session even though the release is
                // still available. Rebuild that session quietly and remember this click. Once
                // Sparkle reports that its alert is ready, the same click presents it automatically.
                statusMessage = "Preparing \(ProductIdentity.displayName) \(availableVersion)…"
                resumePendingRequest()
            case .wait:
                statusMessage = "Preparing \(ProductIdentity.displayName) \(availableVersion)…"
            case .check:
                break
            }
        }

        func openRollingReleasePage() {
            GoalongWorkspaceOpenPolicy.open(
                ProductIdentity.rollingReleasePageURL,
                purpose: .updatePage
            )
        }

        func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
            guard let updater = updaterController?.updater else { return }
            updater.automaticallyChecksForUpdates = enabled
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            statusMessage = automaticallyChecksForUpdates
                ? "Verified update checks run automatically."
                : "Automatic update checks are off."
        }

        private func markDetected(_ item: SUAppcastItem) {
            presentationState.recordDetected(version: item.displayVersionString)
        }

        private func markReady(_ item: SUAppcastItem, presentPendingRequest: Bool = true) {
            let shouldPresent = presentationState.recordReady(version: item.displayVersionString)
            isChecking = false
            userAttendedCurrentUpdate = false
            statusMessage = "\(ProductIdentity.displayName) \(item.displayVersionString) is available."

            if shouldPresent, presentPendingRequest {
                DispatchQueue.main.async { [weak self] in
                    self?.presentReadyUpdate()
                }
            }
        }

        private func startUserInitiatedCheck() {
            guard let updater = updaterController?.updater else {
                presentationState.cancelPendingRequest()
                return
            }
            guard !updater.sessionInProgress, updater.canCheckForUpdates else {
                statusMessage = "The update check is temporarily unavailable."
                presentationState.cancelPendingRequest()
                return
            }

            NSApplication.shared.activate(ignoringOtherApps: true)
            isChecking = true
            statusMessage = "Checking for updates…"
            updater.checkForUpdates()
        }

        private func resumePendingRequest() {
            guard let pendingRequest = presentationState.pendingRequest else { return }

            switch pendingRequest {
            case .presentAvailableUpdate:
                guard let updater = updaterController?.updater else {
                    presentationState.cancelPendingRequest()
                    return
                }
                guard !updater.sessionInProgress else { return }
                guard updater.canCheckForUpdates else {
                    statusMessage = "The detected update is temporarily unavailable. Try again later."
                    presentationState.cancelPendingRequest()
                    return
                }
                refreshAvailableUpdate()
            case .checkForUpdates:
                startUserInitiatedCheck()
            }
        }

        private func presentReadyUpdate() {
            guard let updater = updaterController?.updater else {
                presentationState.cancelPendingRequest()
                return
            }

            guard presentationState.isReady, updater.sessionInProgress else {
                presentationState.recordSessionFinished()
                resumePendingRequest()
                return
            }

            NSApplication.shared.activate(ignoringOtherApps: true)
            updater.checkForUpdates()
        }

        private func markUpToDate() {
            presentationState.recordNoUpdate()
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
            // Sparkle finds the appcast item before its standard user driver has prepared the
            // install alert. Remember the version here, but do not expose a clickable badge yet.
            markDetected(item)
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
            markUpToDate()
        }

        func updater(
            _ updater: SPUUpdater,
            userDidMake choice: SPUUserUpdateChoice,
            forUpdate updateItem: SUAppcastItem,
            state: SPUUserUpdateState
        ) {
            if choice == .skip {
                // Sparkle will intentionally stop offering this build. Remove the dashboard badge
                // at the same time so it never advertises a version the updater will now ignore.
                presentationState.clear()
                statusMessage = "\(ProductIdentity.displayName) \(updateItem.displayVersionString) was skipped."
            }
        }

        func updater(
            _ updater: SPUUpdater,
            didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
            error: (any Error)?
        ) {
            isChecking = false
            if error != nil {
                let hadPendingRequest = presentationState.hasPendingRequest
                presentationState.cancelPendingRequest()
                if hadPendingRequest || presentationState.availableVersion == nil {
                    statusMessage = "The update check could not be completed. Try again later."
                }
                return
            }

            guard presentationState.hasPendingRequest else { return }

            if updateCheck == .updates {
                // A directly initiated check has now produced its native Sparkle result. No queued
                // action remains even when the result was "up to date" rather than an update alert.
                presentationState.cancelPendingRequest()
            } else {
                // A click may arrive while a scheduled/background session is still checking or
                // winding down. Resume that exact request on the next run loop after Sparkle has
                // released the old session, instead of dropping the click.
                DispatchQueue.main.async { [weak self] in
                    self?.resumePendingRequest()
                }
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
            if handleShowingUpdate {
                // User-initiated checks are already being presented by Sparkle. Record the same
                // availability without trying to focus the alert a second time.
                markReady(update, presentPendingRequest: false)
            } else {
                markReady(update)
            }
        }

        func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            userAttendedCurrentUpdate = true
            presentationState.recordUserAttention()
            isChecking = false
        }

        func standardUserDriverWillFinishUpdateSession() {
            isChecking = false
            presentationState.recordSessionFinished()
            guard userAttendedCurrentUpdate else { return }
            userAttendedCurrentUpdate = false
            if let availableVersion = presentationState.availableVersion {
                statusMessage = "\(ProductIdentity.displayName) \(availableVersion) is still available."
            }
        }
    }
#endif
