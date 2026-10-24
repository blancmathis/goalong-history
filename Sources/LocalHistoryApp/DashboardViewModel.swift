#if os(macOS)
    import AppKit
    import Ambiance
    import Combine
    import Foundation
    import LocalHistoryCore
    import UniformTypeIdentifiers

    protocol DashboardScheduledTask: AnyObject {
        func cancel()
    }

    private final class DashboardTimerTask: DashboardScheduledTask {
        private var timer: Timer?

        init(timer: Timer) {
            self.timer = timer
        }

        func cancel() {
            timer?.invalidate()
            timer = nil
        }

        deinit {
            cancel()
        }
    }

    private final class DashboardCancellationToken {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// Owns only the two UI refresh wakeups. It is deliberately independent from the
    /// view model so lifecycle/cadence can be proven with a virtual scheduler in tests.
    final class DashboardRefreshScheduler {
        typealias Schedule = (TimeInterval, @escaping () -> Void) -> DashboardScheduledTask

        static let runtimeInterval: TimeInterval = 5
        static let todayDataInterval: TimeInterval = 60

        private let schedule: Schedule
        private var runtimeTask: DashboardScheduledTask?
        private var dataTask: DashboardScheduledTask?

        init(schedule: @escaping Schedule) {
            self.schedule = schedule
        }

        convenience init() {
            self.init(schedule: Self.scheduleLiveTimer)
        }

        func activate(
            isToday: Bool,
            refreshRuntime: @escaping () -> Void,
            refreshData: @escaping () -> Void
        ) {
            deactivate()
            runtimeTask = schedule(Self.runtimeInterval, refreshRuntime)
            if isToday {
                dataTask = schedule(Self.todayDataInterval, refreshData)
            }
        }

        func deactivate() {
            runtimeTask?.cancel()
            dataTask?.cancel()
            runtimeTask = nil
            dataTask = nil
        }

        var activeTaskCount: Int {
            (runtimeTask == nil ? 0 : 1) + (dataTask == nil ? 0 : 1)
        }

        private static func scheduleLiveTimer(
            interval: TimeInterval,
            action: @escaping () -> Void
        ) -> DashboardScheduledTask {
            let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
            RunLoop.main.add(timer, forMode: .common)
            return DashboardTimerTask(timer: timer)
        }
    }

    final class DashboardViewModel: ObservableObject {
        typealias SaveConfiguration = (RecorderConfig) throws -> RecorderConfig
        typealias DeleteDetails = (Date?, @escaping (Result<Int, Error>) -> Void) -> Void
        typealias DeleteTargetedDetails = (
            TargetedHistoryDeletionRequest,
            @escaping (Result<Int, Error>) -> Void
        ) -> Void

        @Published var selectedSection: DashboardSection = .overview
        @Published var settingsPane: SettingsPane = .home
        /// Where a secondary page (Temps d’écran, Confidentialité, Terminal…) returns:
        /// the page, and Settings pane, it was opened from.
        @Published private(set) var secondaryReturn: DashboardSecondaryReturn?
        @Published var showingWebsiteShare = false
        /// The profile studio outlives any settings pane or page that opens it.
        @MainActor lazy var profileStudio = GoalongProfileStudioHost()
        @Published private(set) var runtime: RuntimePresentation = .unavailable
        /// Free space of the history volume, refreshed at most once a minute while visible.
        @Published private(set) var freeDiskBytes: Int64?
        private var freeDiskCheckedAt: Date?
        @Published private(set) var snapshot: DashboardDaySnapshot
        @Published private(set) var snapshotGeneration: UInt64 = 0
        @Published private(set) var isRefreshing = false
        @Published private(set) var isExportingShare = false
        @Published var selectedSessionID: String?
        @Published var activitySearch = ""
        @Published var activityFilter: ActivityFilter = .all
        @Published var usageSearch = ""
        @Published private(set) var sharingRules: [String: SharingVisibility]
        @Published private(set) var defaultSharingVisibility: SharingVisibility
        @Published var settingsDraft: DashboardSettingsDraft
        @Published var alert: DashboardAlert?
        @Published var showWelcome: Bool
        @Published private(set) var historyDeletionGeneration = 0

        @Published private(set) var deviceID: String
        /// Nil while the identity is degraded and no earlier device ID is known: Screen Time and ChatGPT stay off.
        @Published private(set) var knownDeviceID: String?
        @Published private(set) var deviceTrustTier: String
        @Published private(set) var deviceAlgorithm: String
        @Published private(set) var deviceProtectionTitle: String
        @Published private(set) var deviceProtectionSummary: String
        /// Changed or degraded trust state (rotation, sealing suspended), shown in the integrity section.
        @Published private(set) var trustNotices: [String] = []
        /// Shown in Settings while config.json is unreadable.
        @Published private(set) var configNotice: String?
        /// config.json was unreadable at launch: recording is paused and saves are refused.
        @Published private(set) var configLocked = false
        /// Name of the damaged config.json kept aside by the last reset.
        @Published private(set) var configBackupName: String?
        private var configObserver: NSObjectProtocol?
        private let onReloadConfiguration: () -> Bool
        private let onResetConfiguration: () throws -> String?
        let onRetryKeychain: () -> Void
        private var trustObserver: NSObjectProtocol?
        let agentActivityRuntime: AgentActivityRuntime
        /// The gate is lazy; constructing the dashboard does not create an audio module.
        @MainActor lazy var ambianceModule = AmbianceModule(
            supportDirectory: { AppPaths.applicationSupportDirectory }
        )

        private(set) var selectedDay: Date
        private var savedSettingsDraft: DashboardSettingsDraft

        private let state: CaptureState
        private let permissions: PermissionManager
        private let configManager: ConfigManager
        private let sharingRulesStore: SharingRulesStore
        private let eventTapStatus: () -> Bool
        private let currentSuppression: () -> SuppressionReason?
        private let captureHealthSnapshot: () -> CaptureHealthSnapshot
        private let onBeginCaptureValidation: () -> Void
        private let onTogglePause: () -> Void
        private let onRequestPermissions: () -> Void
        private let onSaveConfiguration: SaveConfiguration
        private let onDeleteDetails: DeleteDetails
        private let onDeleteTargetedDetails: DeleteTargetedDetails
        private let refreshScheduler: DashboardRefreshScheduler
        private let dataReader: DashboardDataReader
        private let shareBuilder = SharePackageBuilder()
        /// Clock, preferences and free-space reader: real ones in the app, fixed ones in tests and the gallery.
        let now: () -> Date
        private let defaults: UserDefaults
        private let availableBytes: () -> Int64?
        /// Activité's reader: the shared one in the app, so reopening the window shows the days already read.
        let analyticsReader: GoalongAnalyticsReader
        private let dataQueue = DispatchQueue(label: "ai.goalong.localhistory.dashboard-data", qos: .userInitiated)
        private let metadataQueue = DispatchQueue(
            label: "ai.goalong.localhistory.dashboard-metadata",
            qos: .utility
        )
        private let shareQueue = DispatchQueue(label: "ai.goalong.localhistory.dashboard-share", qos: .userInitiated)
        @Published private(set) var dashboardIsVisible = false
        private var dataRequestSequence: UInt64 = 0
        private var metadataRequestSequence: UInt64 = 0
        private var activeDataRequest:
            (
                day: Date,
                token: DashboardCancellationToken,
                workItem: DispatchWorkItem
            )?
        private var dataRefreshPending = false
        private var activeMetadataRequest: (token: DashboardCancellationToken, workItem: DispatchWorkItem)?
        private var activeShareExportToken: DashboardCancellationToken?

        init(
            state: CaptureState,
            permissions: PermissionManager,
            configManager: ConfigManager,
            sharingRulesStore: SharingRulesStore,
            agentActivityRuntime: AgentActivityRuntime,
            deviceInfo: DeviceIdentityInfo,
            onRetryKeychain: @escaping () -> Void = {},
            eventTapStatus: @escaping () -> Bool,
            currentSuppression: @escaping () -> SuppressionReason?,
            captureHealthSnapshot: @escaping () -> CaptureHealthSnapshot,
            onBeginCaptureValidation: @escaping () -> Void,
            onTogglePause: @escaping () -> Void,
            onRequestPermissions: @escaping () -> Void,
            onSaveConfiguration: @escaping SaveConfiguration,
            onDeleteDetails: @escaping DeleteDetails,
            onDeleteTargetedDetails: @escaping DeleteTargetedDetails,
            onReloadConfiguration: @escaping () -> Bool = { false },
            onResetConfiguration: @escaping () throws -> String? = { nil },
            refreshScheduler: DashboardRefreshScheduler = DashboardRefreshScheduler(),
            dataReader: DashboardDataReader = DashboardDataReader(),
            now: @escaping () -> Date = Date.init,
            defaults: UserDefaults = .standard,
            availableBytes: @escaping () -> Int64? = { StorageHealth.availableBytes() },
            analyticsReader: GoalongAnalyticsReader = .shared
        ) {
            self.state = state
            self.permissions = permissions
            self.configManager = configManager
            self.sharingRulesStore = sharingRulesStore
            self.agentActivityRuntime = agentActivityRuntime
            self.sharingRules = sharingRulesStore.rules
            self.defaultSharingVisibility = sharingRulesStore.defaultVisibility
            self.onRetryKeychain = onRetryKeychain
            self.deviceID = deviceInfo.deviceID
            self.knownDeviceID = deviceInfo.knownDeviceID
            self.deviceTrustTier = deviceInfo.trustTier
            self.deviceAlgorithm = deviceInfo.algorithm
            self.deviceProtectionTitle = deviceInfo.protectionTitle
            self.deviceProtectionSummary = deviceInfo.protectionSummary
            self.eventTapStatus = eventTapStatus
            self.currentSuppression = currentSuppression
            self.captureHealthSnapshot = captureHealthSnapshot
            self.onBeginCaptureValidation = onBeginCaptureValidation
            self.onTogglePause = onTogglePause
            self.onRequestPermissions = onRequestPermissions
            self.onSaveConfiguration = onSaveConfiguration
            self.onDeleteDetails = onDeleteDetails
            self.onDeleteTargetedDetails = onDeleteTargetedDetails
            self.onReloadConfiguration = onReloadConfiguration
            self.onResetConfiguration = onResetConfiguration
            self.refreshScheduler = refreshScheduler
            self.dataReader = dataReader
            self.now = now
            self.defaults = defaults
            self.availableBytes = availableBytes
            self.analyticsReader = analyticsReader

            let today = Calendar.current.startOfDay(for: now())
            selectedDay = today
            snapshot = .empty(day: today)
            let draft = DashboardSettingsDraft(config: configManager.config)
            settingsDraft = draft
            savedSettingsDraft = draft
            showWelcome = !defaults.bool(forKey: "didShowLocalHistoryConsentOnboardingV5")
            refreshTrustNotices()
            trustObserver = NotificationCenter.default.addObserver(
                forName: DeviceTrustState.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refreshTrustNotices()
            }
            refreshConfigStatus()
            configObserver = NotificationCenter.default.addObserver(
                forName: .goalongConfigStatusDidChange, object: configManager, queue: .main
            ) { [weak self] _ in
                self?.refreshConfigStatus()
            }
        }

        func refreshConfigStatus() {
            configNotice = configManager.statusNotice
            configLocked = configManager.isFailClosed
            configBackupName = configNotice == nil ? configManager.lastDamagedBackupName : nil
        }

        /// The active config changed outside Settings (reload, reset): show what is applied.
        func configurationDidChange() {
            let draft = DashboardSettingsDraft(config: configManager.config)
            settingsDraft = draft
            savedSettingsDraft = draft
            refreshConfigStatus()
            refreshRuntime()
        }

        func reloadConfigurationFromSettings() {
            guard onReloadConfiguration() else {
                refreshConfigStatus()
                alert = DashboardAlert(kind: .error, title: "Configuration non rechargée",
                                       message: configManager.statusNotice ?? ConfigManager.reloadFailedNotice)
                return
            }
            Task { @MainActor in GoalongToastCenter.shared.show("Configuration rechargée") }
        }

        func resetConfigurationFromSettings() {
            do {
                _ = try onResetConfiguration()
                refreshConfigStatus()
                Task { @MainActor in GoalongToastCenter.shared.show("Réglages réinitialisés") }
            } catch {
                alert = DashboardAlert(kind: .error, title: "Les réglages n’ont pas pu être réinitialisés",
                                       message: Self.userFacingMessage(error))
            }
        }

        /// Re-reads the settings from the config file after a manual reload, so the
        /// window never keeps (and later writes back) values the file no longer has.
        func reloadSettings(from config: RecorderConfig) {
            let draft = DashboardSettingsDraft(config: config)
            settingsDraft = draft
            savedSettingsDraft = draft
            refreshRuntime()
        }

        func refreshTrustNotices() {
            trustNotices = [
                DeviceTrustState.shared.sealingSuspendedNotice,
                DeviceIdentityRotation.load(defaults: defaults)?.notice,
            ].compactMap { $0 }
        }

        func updateDeviceInfo(_ info: DeviceIdentityInfo) {
            deviceID = info.deviceID
            knownDeviceID = info.knownDeviceID
            deviceTrustTier = info.trustTier
            deviceAlgorithm = info.algorithm
            deviceProtectionTitle = info.protectionTitle
            deviceProtectionSummary = info.protectionSummary
        }

        deinit {
            if let trustObserver { NotificationCenter.default.removeObserver(trustObserver) }
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            refreshScheduler.deactivate()
            cancelDataRequest()
            cancelMetadataRequest()
            cancelShareExport()
        }

        var isTodaySelected: Bool {
            Calendar.current.isDate(selectedDay, inSameDayAs: now())
        }

        var filteredSessions: [ActivitySession] {
            let query = activitySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return snapshot.sessions.filter { session in
                let filterMatches: Bool
                switch activityFilter {
                case .all:
                    filterMatches = true
                case .work:
                    filterMatches = session.isWork == true
                case .privateOrSuppressed:
                    filterMatches = session.suppressionReason != nil
                case .flagged:
                    filterMatches = session.isFlagged
                }
                let searchMatches = query.isEmpty || session.searchableText.contains(query)
                return filterMatches && searchMatches
            }
        }

        var selectedSession: ActivitySession? {
            guard let selectedSessionID else { return filteredSessions.first }
            return filteredSessions.first(where: { $0.id == selectedSessionID }) ?? filteredSessions.first
        }

        var filteredTrackedUsage: [TrackedUsageItem] {
            let query = usageSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return snapshot.trackedUsage }
            return snapshot.trackedUsage.filter { $0.searchableText.contains(query) }
        }

        func sharingVisibility(for subjectID: String) -> SharingVisibility {
            sharingRules[subjectID] ?? defaultSharingVisibility
        }

        func setSharingVisibility(_ visibility: SharingVisibility, for subjectID: String) {
            do {
                sharingRules = try sharingRulesStore.set(visibility, for: subjectID)
            } catch {
                alert = DashboardAlert(
                    kind: .error,
                    title: "La règle de partage n’a pas pu être enregistrée",
                    message: Self.userFacingMessage(error)
                )
            }
        }

        func setDefaultSharingVisibility(_ visibility: SharingVisibility) {
            do {
                let document = try sharingRulesStore.setDefault(visibility)
                defaultSharingVisibility = document.defaultVisibility
                sharingRules = document.rules
            } catch {
                alert = DashboardAlert(
                    kind: .error,
                    title: "La règle de partage par défaut n’a pas pu être enregistrée",
                    message: Self.userFacingMessage(error)
                )
            }
        }

        var settingsHaveChanges: Bool {
            settingsDraft != savedSettingsDraft
        }

        func selectDay(_ date: Date) {
            let normalized = Calendar.current.startOfDay(for: date)
            guard normalized != selectedDay else { return }
            selectedDay = normalized
            selectedSessionID = nil
            updateRefreshSchedule()
            refreshData(force: true)
        }

        /// Opens Réglages on one pane. `selectSection(.settings)` resets the pane, so it is set after.
        func openSettingsPane(_ pane: SettingsPane) {
            selectSection(.settings)
            settingsPane = pane
        }

        func selectSection(_ section: DashboardSection) {
            // Jev has no page of its own any more: its key and settings live in Réglages › Jev.
            if section == .monitoring {
                openSettingsPane(.jev)
                return
            }
            let previousSection = selectedSection
            if section.isSecondary {
                // Re-selecting the same secondary page (e.g. reopening the window) keeps its origin.
                if !previousSection.isSecondary {
                    secondaryReturn = DashboardSecondaryReturn(section: previousSection, pane: settingsPane)
                }
            } else {
                secondaryReturn = nil
            }
            if section == .settings { settingsPane = .home }
            selectedSection = section
            if dashboardIsVisible, section == .agentActivity {
                agentActivityRuntime.scanNow(
                    forceFullDiscovery: false,
                    analyzeSelectedDay: true
                )
            }
        }

        func openRecordingSettings() {
            selectSection(.settings)
            settingsPane = .recording
        }

        func openApplicationsSettings() {
            selectSection(.settings)
            settingsPane = .applications
        }

        /// Back action of every secondary page.
        func returnFromSecondaryPage() {
            let destination = secondaryReturn
                ?? DashboardSecondaryReturn(section: selectedSection.defaultReturnSection, pane: .home)
            selectSection(destination.section)
            if destination.section == .settings { settingsPane = destination.pane }
        }

        var secondaryReturnTitle: String {
            switch secondaryReturn?.section ?? selectedSection.defaultReturnSection {
            case .settings: return "Retour aux réglages"
            case .history: return "Retour à l’historique"
            case .monitoring: return "Retour à la surveillance"
            default: return "Retour à Activité"
            }
        }

        /// A secondary page keeps the sidebar on the destination it was opened from.
        var highlightedSidebarSection: DashboardSection {
            guard selectedSection.isSecondary else { return selectedSection.sidebarParent }
            return (secondaryReturn?.section ?? selectedSection.defaultReturnSection).sidebarParent
        }

        func refreshEverything() {
            guard dashboardIsVisible else { return }
            refreshRuntime()
            refreshData(force: true)
            refreshMetadataIfNeeded(force: false)
            if selectedSection == .agentActivity {
                agentActivityRuntime.scanNow(analyzeSelectedDay: true)
            }
        }

        func dashboardDidBecomeVisible() {
            guard !dashboardIsVisible else { return }
            dashboardIsVisible = true
            agentActivityRuntime.dashboardDidBecomeVisible()
            refreshRuntime()
            refreshData(force: true)
            refreshMetadataIfNeeded(force: false)
            if selectedSection == .agentActivity {
                agentActivityRuntime.scanNow(
                    forceFullDiscovery: false,
                    analyzeSelectedDay: true
                )
            }
            updateRefreshSchedule()
        }

        /// Tests: waits until the data and metadata queues are idle, then lets queued main-thread work run.
        func waitForPendingWorkForTesting() {
            dataQueue.sync {}
            metadataQueue.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        func dashboardDidBecomeHidden(discardContents: Bool = true) {
            guard dashboardIsVisible else {
                if discardContents { discardVisibleSnapshot() }
                return
            }
            dashboardIsVisible = false
            refreshScheduler.deactivate()
            dataRequestSequence &+= 1
            metadataRequestSequence &+= 1
            cancelDataRequest()
            cancelMetadataRequest()
            cancelShareExport()
            discardShareCache()
            dataRefreshPending = false
            isRefreshing = false
            if discardContents { discardVisibleSnapshot() }
            agentActivityRuntime.dashboardDidBecomeHidden()
            let reader = dataReader
            dataQueue.async {
                reader.discardTransientCaches()
            }
        }

        private func discardVisibleSnapshot() {
            snapshot = .empty(day: selectedDay)
            snapshotGeneration &+= 1
        }

        func togglePause() {
            onTogglePause()
            refreshRuntime()
        }

        func requestPermissions() {
            onRequestPermissions()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.refreshRuntime()
            }
        }

        func beginCaptureValidation() {
            onBeginCaptureValidation()
            refreshRuntime()
        }

        func openAccessibilitySettings() {
            permissions.openAccessibilitySettings()
        }

        func openInputMonitoringSettings() {
            permissions.openInputMonitoringSettings()
        }

        func dismissWelcome() {
            defaults.set(true, forKey: "didShowLocalHistoryConsentOnboardingV5")
            showWelcome = false
        }

        func openDataFolder() {
            GoalongWorkspaceOpenPolicy.open(
                AppPaths.applicationSupportDirectory,
                purpose: .localFile
            )
        }

        func openConfiguration() {
            GoalongWorkspaceOpenPolicy.open(AppPaths.configFile, purpose: .localFile)
        }

        func openTodayJSON() {
            let file = AppPaths.eventFileURL(for: selectedDay)
            if FileManager.default.fileExists(atPath: file.path) {
                GoalongWorkspaceOpenPolicy.open(file, purpose: .localFile)
            } else {
                GoalongWorkspaceOpenPolicy.open(AppPaths.eventsDirectory, purpose: .localFile)
            }
        }

        func revealTodayJSON() {
            let file = AppPaths.eventFileURL(for: selectedDay)
            if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                GoalongWorkspaceOpenPolicy.open(AppPaths.eventsDirectory, purpose: .localFile)
            }
        }

        func openDiagnostics() {
            Task { @MainActor in SupportRequestController.shared.present() }
        }

        func selectSession(_ id: String) {
            selectedSessionID = id
        }

        func exportSharePackage() {
            guard snapshot.sealedMinutes > 0 else {
                alert = DashboardAlert(
                    kind: .information,
                    title: "Rien à exporter",
                    message: "Aucune minute scellée n’est encore disponible pour ce jour."
                )
                return
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(AppPaths.localDayString(for: selectedDay)).signed-share.json"
            guard panel.runModal() == .OK, let destination = panel.url else { return }

            let day = selectedDay
            let rules = sharingRules
            let defaultVisibility = defaultSharingVisibility
            activeShareExportToken?.cancel()
            let token = DashboardCancellationToken()
            activeShareExportToken = token
            isExportingShare = true

            shareQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let privacyRoot = AppPaths.applicationSupportDirectory
                    let privacy = GoalongPrivacyPolicy.load(in: privacyRoot)
                    let package = try self.shareBuilder.build(
                        for: day,
                        sharingRules: rules,
                        defaultVisibility: defaultVisibility,
                        privacy: privacy,
                        cancellation: { token.isCancelled }
                    )
                    guard !token.isCancelled else { throw ShareBuildError.cancelled }
                    guard GoalongPrivacyPolicy.load(in: privacyRoot).revision == privacy.revision else {
                        throw ShareBuildError.exclusionsChanged
                    }
                    guard package.verificationReport().isLocallyValid else {
                        throw ShareBuildError.brokenSeal(package.minutes.first?.anchorSequence ?? 0)
                    }
                    try self.shareBuilder.write(
                        package,
                        to: destination,
                        cancellation: { token.isCancelled }
                    )
                    DispatchQueue.main.async {
                        guard self.activeShareExportToken === token else { return }
                        self.activeShareExportToken = nil
                        self.isExportingShare = false
                        self.alert = DashboardAlert(
                            kind: .information,
                            title: "Paquet signé exporté",
                            message:
                                "Goalong a vérifié chaque signature de l’appareil et la chaîne d’intégrité avant l’export. Le paquet suit vos règles d’apps et de sites ; les champs masqués restent sur ce Mac."
                        )
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.activeShareExportToken === token else { return }
                        self.activeShareExportToken = nil
                        self.isExportingShare = false
                        if let buildError = error as? ShareBuildError,
                            case .cancelled = buildError
                        {
                            return
                        }
                        self.alert = DashboardAlert(
                            kind: .error,
                            title: "Échec de l’export",
                            message: Self.userFacingMessage(error)
                        )
                    }
                }
            }
        }

        func saveSettings(showConfirmation: Bool = true) {
            if !GoalongBuildCapabilities.permitsRemoteVerification {
                settingsDraft.verificationEnabled = false
                settingsDraft.verificationServerURL = ""
                settingsDraft.enableAppAttest = false
            }
            if settingsDraft.verificationEnabled {
                let raw = settingsDraft.verificationServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isValidVerificationURL(raw) else {
                    alert = DashboardAlert(
                        kind: .error,
                        title: "Serveur de vérification invalide",
                        message: "Utilisez une adresse HTTPS. HTTP n’est accepté qu’en développement local."
                    )
                    return
                }
            }

            do {
                try settingsDraft.validatePrivacyRules()
                let requested = settingsDraft.applying(to: configManager.config)
                let applied = try onSaveConfiguration(requested)
                let refreshed = DashboardSettingsDraft(config: applied)
                settingsDraft = refreshed
                savedSettingsDraft = refreshed
                refreshRuntime()
                if showConfirmation {
                    Task { @MainActor in GoalongToastCenter.shared.show("Réglages enregistrés") }
                }
            } catch {
                alert = DashboardAlert(
                    kind: .error,
                    title: "Les réglages n’ont pas pu être enregistrés",
                    message: Self.userFacingMessage(error)
                )
            }
        }

        /// Immediate controls always read back the persisted state. A failed save
        /// restores the previous value instead of leaving a falsely reassuring switch.
        @discardableResult
        func applyRecordingChoice(_ next: DashboardSettingsDraft) -> Bool {
            let previous = savedSettingsDraft
            settingsDraft = next
            alert = nil
            saveSettings(showConfirmation: false)
            guard alert == nil else {
                settingsDraft = savedSettingsDraft
                return false
            }
            if previous != savedSettingsDraft {
                GoalongRecordingSetup.rememberChanges(from: previous, to: savedSettingsDraft)
                NotificationCenter.default.post(name: .goalongRecordingChoicesDidChange, object: nil)
            }
            return true
        }

        /// Save the whole local recording choice before permitting source activation.
        /// Preferences are read back and durably flushed; on error retain the previous
        /// profile rather than marking an unrecorded proposal as reviewed.
        @discardableResult
        func applyRecordingSetup(_ proposal: GoalongRecordingSetup.Proposal,
                                 defaults: UserDefaults = .standard,
                                 flushPreferences: (() -> Bool)? = nil,
                                 notifyRuntime: Bool = true) -> Bool {
            let original = configManager.config
            let keys = [ActivityAnalysisPreferences.richContextEnabledKey,
                        GoalongRecordingSetup.reviewedKey, GoalongRecordingSetup.preparedKey,
                        GoalongRecordingSetup.explicitChoicesKey]
            let prior = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
            var configurationChanged = false
            alert = nil
            do {
                try proposal.settings.validatePrivacyRules()
                let applied = try onSaveConfiguration(proposal.settings.applying(to: original))
                configurationChanged = true
                let saved = DashboardSettingsDraft(config: applied)
                guard RecordingSignal.allCases.allSatisfy({ saved[keyPath: $0.keyPath] == proposal.settings[keyPath: $0.keyPath] }) else {
                    throw PrivacyScopeInput.invalid("Le profil enregistré ne correspond pas aux options choisies.")
                }
                defaults.set(proposal.visibleText, forKey: ActivityAnalysisPreferences.richContextEnabledKey)
                var explicit: [String: Bool] = [:]
                for signal in RecordingSignal.allCases { explicit[signal.rawValue] = saved[keyPath: signal.keyPath] }
                explicit["visibleText"] = proposal.visibleText
                defaults.set(explicit, forKey: GoalongRecordingSetup.explicitChoicesKey)
                defaults.set(true, forKey: GoalongRecordingSetup.reviewedKey)
                defaults.set(true, forKey: GoalongRecordingSetup.preparedKey)
                guard (flushPreferences?() ?? defaults.synchronize()),
                      defaults.bool(forKey: ActivityAnalysisPreferences.richContextEnabledKey) == proposal.visibleText,
                      defaults.bool(forKey: GoalongRecordingSetup.reviewedKey) else {
                    throw PrivacyScopeInput.invalid("Les préférences n’ont pas été enregistrées. Réessayez.")
                }
                settingsDraft = saved; savedSettingsDraft = saved
                if notifyRuntime { ActivityAnalysisRuntime.shared.richContextPreferenceDidChange() }
                NotificationCenter.default.post(name: .goalongRecordingChoicesDidChange, object: nil)
                refreshRuntime()
                return true
            } catch {
                for key in keys {
                    if let value = prior[key] ?? nil { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
                _ = defaults.synchronize()
                var rollbackError: String?
                if configurationChanged {
                    do {
                        let restored = try onSaveConfiguration(original)
                        savedSettingsDraft = DashboardSettingsDraft(config: restored)
                    } catch { rollbackError = error.localizedDescription }
                }
                settingsDraft = savedSettingsDraft
                alert = DashboardAlert(kind: .error, title: "Enregistrement non confirmé",
                    message: error.localizedDescription + (rollbackError.map { " Vérifiez le profil actuel : " + $0 } ?? " Vos choix précédents sont conservés."))
                return false
            }
        }

        /// The Privacy screen reports persisted choices, never an unsaved editor draft.
        var appliedSettings: DashboardSettingsDraft { savedSettingsDraft }

        @discardableResult
        func saveOnboardingRecordingChoices() -> Bool {
            do {
                try settingsDraft.validatePrivacyRules()
                let applied = try onSaveConfiguration(settingsDraft.applying(to: configManager.config))
                settingsDraft = DashboardSettingsDraft(config: applied)
                savedSettingsDraft = settingsDraft
                refreshRuntime()
                return true
            } catch {
                alert = DashboardAlert(kind: .error, title: "Les choix n’ont pas pu être enregistrés", message: error.localizedDescription)
                return false
            }
        }

        func discardSettingsChanges() {
            settingsDraft = savedSettingsDraft
        }

        func deleteDetails(since cutoff: Date?) {
            onDeleteDetails(cutoff) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let count):
                        self.alert = DashboardAlert(
                            kind: .information,
                            title: "Détails locaux supprimés",
                            message: cutoff == nil
                                ? "\(FrenchCount.count(count, "élément local", "éléments locaux")) \(FrenchCount.word(count, "supprimé", "supprimés")). Les sceaux et reçus sont conservés : ces périodes restent visibles comme privées."
                                : "\(FrenchCount.count(count, "événement détaillé", "événements détaillés")) \(FrenchCount.word(count, "supprimé", "supprimés")). Les sceaux et reçus sont conservés."
                        )
                        self.refreshData(force: true)
                    case .failure(let error):
                        self.alert = DashboardAlert(
                            kind: .error,
                            title: "Échec de la suppression",
                            message: Self.userFacingMessage(error)
                        )
                    }
                }
            }
        }

        func deleteComputerHistoryEpisode(_ episode: ComputerHistoryEpisode, day: Date) {
            deleteTargetedDetails(
                .computerHistoryEpisode(id: episode.id, day: day),
                successMessage:
                    "L’élément choisi et ses détails locaux ont été supprimés. Les sceaux et reçus sont conservés."
            )
        }

        func deleteActivitySession(_ session: ActivitySession) {
            deleteTargetedDetails(
                .activitySession(session),
                successMessage:
                    "La session choisie et ses détails locaux ont été supprimés. Les sceaux et reçus sont conservés."
            )
        }

        static func removedItemsLabel(_ count: Int) -> String {
            count <= 1 ? "\(count) élément local supprimé." : "\(count) éléments locaux supprimés."
        }

        var mostRecentActivitySession: ActivitySession? {
            snapshot.sessions.first
        }

        func deleteTargetedDetails(
            _ request: TargetedHistoryDeletionRequest,
            successMessage: String
        ) {
            onDeleteTargetedDetails(request) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let count):
                        self.historyDeletionGeneration &+= 1
                        self.selectedSessionID = nil
                        self.alert = DashboardAlert(
                            kind: .information,
                            title: "Élément supprimé",
                            message: "\(successMessage) \(Self.removedItemsLabel(count))"
                        )
                        self.refreshData(force: true)
                    case .failure(let error):
                        self.alert = DashboardAlert(
                            kind: .error,
                            title: "Échec de la suppression",
                            message: Self.userFacingMessage(error)
                        )
                    }
                }
            }
        }

        private func updateRefreshSchedule() {
            guard dashboardIsVisible else {
                refreshScheduler.deactivate()
                return
            }
            refreshScheduler.activate(
                isToday: isTodaySelected,
                refreshRuntime: { [weak self] in self?.refreshRuntime() },
                refreshData: { [weak self] in
                    guard let self else { return }
                    self.refreshData(force: false)
                    self.refreshMetadataIfNeeded(force: false)
                }
            )
        }

        /// Read on demand by the diagnostics panel; never published, see RuntimePresentation.==.
        func liveCaptureHealthSnapshot() -> CaptureHealthSnapshot { captureHealthSnapshot() }

        private func refreshRuntime() {
            guard dashboardIsVisible else { return }
            let status = permissions.snapshot
            let tap = eventTapStatus()
            let healthSnapshot = captureHealthSnapshot()
            let health = CaptureHealthEvaluator.assess(healthSnapshot, now: now())
            let runtimeState: RuntimeStateKind
            switch health.state {
            case .paused:
                runtimeState = .paused
            case .excludedPrivateOrSecure:
                runtimeState = currentSuppression().map(RuntimeStateKind.suppressed) ?? .recording
            case .ready, .healthyButIdle:
                runtimeState = .recording
            case .permissionRequired, .permissionAppearsEnabledButStaleForBuild,
                .accessibilityContextUnavailable:
                runtimeState = .permissionsMissing
            case .inputTapUnavailable, .awaitingInputEvidence:
                runtimeState = .inputTapUnavailable
            case .storageUnavailable:
                runtimeState = .storageUnavailable(healthSnapshot.storageFailureKind ?? .unavailable)
            }

            if freeDiskCheckedAt.map({ now().timeIntervalSince($0) >= 60 }) ?? true {
                freeDiskCheckedAt = now()
                let free = availableBytes()
                if free != freeDiskBytes { freeDiskBytes = free }
            }

            let next = RuntimePresentation(
                state: runtimeState,
                accessibilityGranted: status.accessibility,
                inputMonitoringGranted: status.inputMonitoring,
                eventTapRunning: tap,
                verificationEnabled: GoalongBuildCapabilities.permitsRemoteVerification
                    && configManager.config.verificationEnabled == true,
                verificationServer: GoalongBuildCapabilities.permitsRemoteVerification
                    ? configManager.config.verificationServerURL
                    : nil,
                captureHealth: health
            )
            if next != runtime { runtime = next }
        }

        private func refreshData(force: Bool) {
            guard dashboardIsVisible else { return }
            if let activeDataRequest {
                if activeDataRequest.day == selectedDay {
                    // One active pass plus one latest-state catch-up keeps repeated
                    // UI/timer requests from building an unbounded queue.
                    dataRefreshPending = true
                    return
                }
                cancelDataRequest()
                dataRefreshPending = false
            }
            // The 60 s timer pass (force == false) stays silent: toggling the spinner would
            // republish the whole dashboard twice a minute for no visible gain.
            if force, !isRefreshing { isRefreshing = true }
            dataRequestSequence &+= 1
            let requestSequence = dataRequestSequence
            let day = selectedDay
            let token = DashboardCancellationToken()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let next = self.dataReader.snapshot(
                    for: day,
                    cancellation: { token.isCancelled }
                )
                DispatchQueue.main.async {
                    guard self.dataRequestSequence == requestSequence else { return }
                    self.activeDataRequest = nil
                    if self.isRefreshing { self.isRefreshing = false }
                    let shouldCatchUp = self.dataRefreshPending
                    self.dataRefreshPending = false
                    guard self.dashboardIsVisible, !token.isCancelled, let next else { return }
                    guard self.selectedDay == day else {
                        self.refreshData(force: true)
                        return
                    }
                    self.snapshot = next
                    self.snapshotGeneration &+= 1
                    if let selected = self.selectedSessionID,
                        !self.filteredSessions.contains(where: { $0.id == selected })
                    {
                        self.selectedSessionID = self.filteredSessions.first?.id
                    }
                    if shouldCatchUp {
                        self.refreshData(force: force)
                    }
                }
            }
            activeDataRequest = (day, token, workItem)
            dataQueue.async(execute: workItem)
        }

        private func refreshMetadataIfNeeded(force: Bool) {
            guard dashboardIsVisible, dataReader.metadataNeedsRefresh(force: force) else { return }
            if activeMetadataRequest != nil {
                guard force else { return }
                cancelMetadataRequest()
            }

            metadataRequestSequence &+= 1
            let requestSequence = metadataRequestSequence
            let token = DashboardCancellationToken()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let updated = self.dataReader.refreshMetadataIfNeeded(
                    force: force,
                    cancellation: { token.isCancelled }
                )
                DispatchQueue.main.async {
                    guard self.metadataRequestSequence == requestSequence else { return }
                    self.activeMetadataRequest = nil
                    guard self.dashboardIsVisible, !token.isCancelled, updated else { return }
                    self.snapshot = self.dataReader.applyingCachedMetadata(to: self.snapshot)
                    self.snapshotGeneration &+= 1
                }
            }
            activeMetadataRequest = (token, workItem)
            metadataQueue.async(execute: workItem)
        }

        private func cancelDataRequest() {
            activeDataRequest?.token.cancel()
            activeDataRequest?.workItem.cancel()
            activeDataRequest = nil
        }

        private func cancelMetadataRequest() {
            activeMetadataRequest?.token.cancel()
            activeMetadataRequest?.workItem.cancel()
            activeMetadataRequest = nil
        }

        private func cancelShareExport() {
            activeShareExportToken?.cancel()
            activeShareExportToken = nil
            isExportingShare = false
        }

        private func discardShareCache() {
            let builder = shareBuilder
            shareQueue.async {
                builder.discardTransientCaches()
            }
        }

        /// A French message for an alert: the error's own description, never a Swift dump.
        static func userFacingMessage(_ error: Error) -> String {
            GoalongUserFacingError.message(error)
        }

        private static func isValidVerificationURL(_ raw: String) -> Bool {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
            if scheme == "https" { return url.host != nil }
            return scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
        }
    }
#endif
