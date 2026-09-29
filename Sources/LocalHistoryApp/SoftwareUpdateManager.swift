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
        @Published private(set) var statusMessage = "Les mises à jour sont disponibles dans les versions publiées."
        @Published private(set) var lastCheckResult: SupportState = .unknown
        @Published private(set) var lastCheckedAt: Date? = UserDefaults.standard.object(forKey: SoftwareUpdateManager.lastCheckedKey) as? Date
        /// Set on the first launch after an update so the app can confirm it worked.
        @Published private(set) var updatedFromVersion: String?
        static let lastCheckedKey = "goalong.updates.lastCheckedAt.v1"
        static let lastSeenVersionKey = "goalong.updates.lastSeenVersion.v1"

        private let updateWindows = SoftwareUpdateWindowCoordinator()

        func registerDashboardWindow(_ window: NSWindow) { updateWindows.registerDashboard(window) }
        func dashboardWasShown() { updateWindows.dashboardWasShown() }

        private var updaterController: SPUStandardUpdaterController?
        private var hasStarted = false
        private(set) var isRelaunchingForUpdate = false
        private var lastBackgroundCheck: Date?
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
            // A click during a background session must be queued, never discarded.
            // Unconfigured source builds show an explanation instead of an inert menu.
            true
        }

        private override init() {
            super.init()
        }

        func start() {
            guard !hasStarted else { return }
            hasStarted = true
            noteLaunchedVersion()

            guard Self.hasValidSparkleConfiguration(in: .main) else {
                requiresSignedBuild = true
                statusMessage = "Cette version a été compilée sans configuration de mise à jour valide. Installez une fois la version Community ou recompilez avec la clé publique incluse dans le dépôt. Aucun abonnement Apple n’est nécessaire."
                return
            }

            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            updaterController = controller
            // Do not send Sparkle's optional system profile. The feed contains no activity data.
            controller.updater.sendsSystemProfile = false
            controller.updater.automaticallyDownloadsUpdates = false
            do {
                try controller.updater.start()
            } catch {
                SupportDiagnostics.shared.failure(error, component: .updates)
                updaterController = nil
                statusMessage = "Le module de mise à jour n’a pas pu démarrer (\(Self.errorSummary(error))). Téléchargez la dernière version depuis la page des versions."
                return
            }

            isConfigured = true
            requiresSignedBuild = false
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
            statusMessage = automaticallyChecksForUpdates
                ? "Vérification automatique activée."
                : "Vérification automatique désactivée."

            // Sparkle's scheduled interval may not be due yet, especially on a freshly installed
            // build. Start one quiet update session now so the dashboard button reflects the
            // current Git release without waiting for the hourly interval. Keeping Sparkle's scheduled session
            // alive also lets a click on that button reveal the already-found update immediately,
            // instead of performing a second user-visible feed check.
            DispatchQueue.main.async { [weak self] in
                self?.refreshAvailableUpdate()
            }
        }

        func stop() {
            guard hasStarted else { return }
            // Sparkle still owns installer/XPC state during applicationWillTerminate.
            // Keep its controller alive until process exit when it is handing off a
            // user-approved update. Do not add a competing relauncher or unregister
            // the native login item during replacement.
            guard !isRelaunchingForUpdate else { return }
            updateWindows.finish()
            updaterController = nil
            hasStarted = false
            lastBackgroundCheck = nil
            isConfigured = false
            isChecking = false
            automaticallyChecksForUpdates = false
            presentationState = SoftwareUpdatePresentationState()
            statusMessage = "Vérification automatique désactivée."
        }

        /// Compares the running version with the one seen at the previous launch. A change
        /// after an in-app update is confirmed once in the interface.
        private func noteLaunchedVersion() {
            let defaults = UserDefaults.standard
            let previous = defaults.string(forKey: Self.lastSeenVersionKey)
            defaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
            if let previous, previous != currentVersion, previous.compare(currentVersion, options: .numeric) == .orderedAscending {
                updatedFromVersion = previous
            }
        }

        func acknowledgeUpdateConfirmation() {
            updatedFromVersion = nil
        }

        func refreshAvailableUpdate() {
            guard automaticallyChecksForUpdates else { return }
            guard Self.shouldCheckInBackground(lastCheck: lastBackgroundCheck, now: Date()) else { return }
            beginBackgroundCheck()
        }

        static func shouldCheckInBackground(lastCheck: Date?, now: Date) -> Bool {
            guard let lastCheck else { return true }
            return now.timeIntervalSince(lastCheck) >= 3600
        }

        private func beginBackgroundCheck() {
            guard let updater = updaterController?.updater, updater.canCheckForUpdates else { return }
            guard !updater.sessionInProgress else { return }
            guard !isChecking else { return }
            lastBackgroundCheck = Date()
            isChecking = true
            statusMessage = presentationState.availableVersion == nil
                ? "Recherche de mises à jour…"
                : "Préparation de la mise à jour…"
            SupportDiagnostics.shared.record(.updateCheckStarted, component: .updates, values: [.userChoice: .flag(false)])
            updater.checkForUpdatesInBackground()
        }

        func checkForUpdates() {
            if !hasStarted { start() }
            guard let updater = updaterController?.updater, isConfigured else {
                let alert = NSAlert()
                alert.messageText = "Mises à jour indisponibles dans cette version"
                alert.informativeText = statusMessage
                alert.addButton(withTitle: "Voir les versions")
                alert.addButton(withTitle: "Annuler")
                NSApplication.shared.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { openRollingReleasePage() }
                return
            }

            updateWindows.beginExplicitPresentation()
            switch presentationState.requestUpdateCheck(hasActiveSession: updater.sessionInProgress) {
            case .present:
                presentReadyUpdate()
            case .wait:
                isChecking = true
                statusMessage = "Fin de la vérification en cours…"
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

            updateWindows.beginExplicitPresentation()
            switch presentationState.requestAvailableUpdate(hasActiveSession: updater.sessionInProgress) {
            case .present:
                presentReadyUpdate()
            case .prepare:
                // A dismissed Sparkle alert ends its update session even though the release is
                // still available. Rebuild that session quietly and remember this click. Once
                // Sparkle reports that its alert is ready, the same click presents it automatically.
                statusMessage = "Préparation de \(ProductIdentity.displayName) \(availableVersion)…"
                resumePendingRequest()
            case .wait:
                statusMessage = "Préparation de \(ProductIdentity.displayName) \(availableVersion)…"
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
            lastBackgroundCheck = nil
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            statusMessage = automaticallyChecksForUpdates
                ? "Vérification automatique activée."
                : "Vérification automatique désactivée."
            SupportDiagnostics.shared.record(.updateChanged, component: .updates,
                values: [.automaticChecks: .flag(automaticallyChecksForUpdates)])
            if automaticallyChecksForUpdates { refreshAvailableUpdate() }
        }

        private func markDetected(_ item: SUAppcastItem) {
            presentationState.recordDetected(version: item.displayVersionString)
        }

        private func markReady(_ item: SUAppcastItem, presentPendingRequest: Bool = true) {
            let shouldPresent = presentationState.recordReady(version: item.displayVersionString)
            isChecking = false
            userAttendedCurrentUpdate = false
            statusMessage = "\(ProductIdentity.displayName) \(item.displayVersionString) est disponible."

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
                statusMessage = "La vérification est momentanément indisponible. Réessayez dans un instant."
                presentationState.cancelPendingRequest()
                return
            }

            updateWindows.beginExplicitPresentation()
            NSApplication.shared.activate(ignoringOtherApps: true)
            isChecking = true
            statusMessage = "Recherche de mises à jour…"
            SupportDiagnostics.shared.record(.updateCheckStarted, component: .updates, values: [.userChoice: .flag(true)])
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
                    statusMessage = "La mise à jour détectée est momentanément indisponible. Réessayez plus tard."
                    presentationState.cancelPendingRequest()
                    return
                }
                // This is a user click, not an automatic check; honor it even when checks are off.
                beginBackgroundCheck()
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

            updateWindows.beginExplicitPresentation()
            NSApplication.shared.activate(ignoringOtherApps: true)
            updater.checkForUpdates()
        }

        private func markUpToDate() {
            presentationState.recordNoUpdate()
            isChecking = false
            statusMessage = "\(ProductIdentity.displayName) est à jour."
            recordCheckResult(.upToDate)
        }

        private func recordCheckResult(_ result: SupportState, error: (any Error)? = nil) {
            lastCheckResult = result
            let now = Date()
            lastCheckedAt = now
            UserDefaults.standard.set(now, forKey: Self.lastCheckedKey)
            var values: [SupportKey: SupportValue] = [.updateResult: .state(result)]
            if let version = presentationState.availableVersion, SupportSymbol.isSafe(version, for: .availableVersion) {
                values[.availableVersion] = .symbol(version)
            }
            if let error { values.merge(SupportDiagnostics.errorValues(error)) { _, new in new } }
            SupportDiagnostics.shared.record(.updateCheckFinished, component: .updates,
                                             level: result == .failed ? .warning : .info, values: values)
        }

        /// Plain-language cause for the most common update failures; codes stay in the journal.
        static func errorSummary(_ error: any Error) -> String {
            let error = error as NSError
            if error.domain == NSURLErrorDomain {
                switch error.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                    return "pas de connexion Internet"
                case NSURLErrorTimedOut: return "le serveur n’a pas répondu à temps"
                case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost:
                    return "le serveur des mises à jour est injoignable"
                default: return "erreur réseau \(error.code)"
                }
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain {
                return errorSummary(underlying)
            }
            if error.domain == SUSparkleErrorDomain {
                switch Int32(error.code) {
                case SUError.appcastError.rawValue, SUError.appcastParseError.rawValue:
                    return "la liste des versions est illisible"
                case SUError.signatureError.rawValue, SUError.validationError.rawValue:
                    return "la signature de la mise à jour n’a pas pu être vérifiée ; rien n’a été installé"
                case SUError.downloadError.rawValue: return "le téléchargement a échoué"
                case SUError.installationError.rawValue, SUError.installationCanceledError.rawValue:
                    return "l’installation n’a pas abouti ; la version actuelle est conservée"
                case SUError.runningFromDiskImageError.rawValue:
                    return "Goalong est ouvert depuis l’image disque ; glissez-le d’abord dans Applications"
                case SUError.installationWriteNoPermissionError.rawValue:
                    return "macOS n’autorise pas Goalong à remplacer l’app dans Applications"
                default: return "code Sparkle \(error.code)"
                }
            }
            return "code \(error.code)"
        }

        static func isNoUpdateResult(_ error: any Error) -> Bool {
            let error = error as NSError
            return error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)
        }

        static let releasePublicEDKey = "unzWUzbW9prJnXXU9IU3WiXeutTek3kRah73Y8dh/LA="
        static let releaseFeedURL = "https://github.com/blancmathis/goalong-history/releases/download/latest-main/community-appcast.xml"

        private static func hasValidSparkleConfiguration(in bundle: Bundle) -> Bool {
            hasValidSparkleConfiguration(info: bundle.infoDictionary ?? [:], isApp: bundle.bundleURL.pathExtension == "app")
        }

        static func hasValidSparkleConfiguration(info: [String: Any], isApp: Bool) -> Bool {
            guard isApp, info["SUFeedURL"] as? String == releaseFeedURL,
                  let key = info["SUPublicEDKey"] as? String,
                  key == releasePublicEDKey,
                  info["SUSignedFeedFailureExpirationInterval"] as? Int == 0,
                  info["SURequireSignedFeed"] as? Bool == true,
                  info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
                  info["SUAllowsAutomaticUpdates"] as? Bool == false,
                  info["SUEnableSystemProfiling"] as? Bool == false else { return false }
            return true
        }

    }

    extension SoftwareUpdateManager: SPUUpdaterDelegate {
        func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
            var values: [SupportKey: SupportValue] = [.state: .state(.relaunchPrepared), .version: .symbol(currentVersion)]
            if let version = presentationState.availableVersion, SupportSymbol.isSafe(version, for: .availableVersion) {
                values[.availableVersion] = .symbol(version)
            }
            SupportDiagnostics.shared.record(.updateChanged, component: .updates, values: values)
            isRelaunchingForUpdate = true
        }

        func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
            isRelaunchingForUpdate = false
            if !Self.isNoUpdateResult(error) {
                SupportDiagnostics.shared.failure(error, component: .updates)
            }
        }

        func feedURLString(for updater: SPUUpdater) -> String? {
            // Ignore any obsolete user-default feed override from pre-Community builds.
            Self.releaseFeedURL
        }

        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            // Sparkle finds the appcast item before its standard user driver has prepared the
            // install alert. Remember the version here, but do not expose a clickable badge yet.
            markDetected(item)
            recordCheckResult(.updateAvailable)
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
            let recorded: SupportState
            switch choice {
            case .install: recorded = .install
            case .skip: recorded = .skip
            case .dismiss: recorded = .later
            @unknown default: recorded = .unknown
            }
            SupportDiagnostics.shared.record(.updateChoice, component: .updates, values: [.userChoice: .state(recorded)])
            if choice == .skip {
                // Sparkle will intentionally stop offering this build. Remove the dashboard badge
                // at the same time so it never advertises a version the updater will now ignore.
                presentationState.clear()
                statusMessage = "\(ProductIdentity.displayName) \(updateItem.displayVersionString) a été ignorée."
            }
        }

        func updater(
            _ updater: SPUUpdater,
            didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
            error: (any Error)?
        ) {
            isChecking = false
            lastBackgroundCheck = Date()
            if let error, !Self.isNoUpdateResult(error) {
                let hadPendingRequest = presentationState.hasPendingRequest
                presentationState.cancelPendingRequest()
                statusMessage = "La vérification n’a pas abouti : \(Self.errorSummary(error)). Votre version actuelle continue de fonctionner."
                recordCheckResult(.failed, error: error)
                if hadPendingRequest && updateCheck != .updates {
                    // A click that was queued behind a background check must still get a visible
                    // result on a network/signature failure, without interrupting passive checks.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let alert = NSAlert()
                        alert.messageText = "Impossible de vérifier les mises à jour"
                        alert.informativeText = self.statusMessage
                        alert.addButton(withTitle: "Réessayer")
                        alert.addButton(withTitle: "Annuler")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        if alert.runModal() == .alertFirstButtonReturn { self.checkForUpdates() }
                    }
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
                updateWindows.beginExplicitPresentation()
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

        func standardUserDriverAllowsMinimizableStatusWindow() -> Bool { false }

        func standardUserDriverWillFinishUpdateSession() {
            updateWindows.finish()
            isChecking = false
            presentationState.recordSessionFinished()
            guard userAttendedCurrentUpdate else { return }
            userAttendedCurrentUpdate = false
            if let availableVersion = presentationState.availableVersion {
                statusMessage = "\(ProductIdentity.displayName) \(availableVersion) reste disponible."
            }
        }
    }
#endif
