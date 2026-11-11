import AppleScreenTime
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

        /// Status only: no data wakeup while the window lacks the keyboard.
        func activateRuntimeOnly(refreshRuntime: @escaping () -> Void) {
            deactivate()
            runtimeTask = schedule(Self.runtimeInterval, refreshRuntime)
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

    /// One signed-file export: the day, the sharing rules read when it started, and the chosen file.
    struct ShareExportJob {
        let day: Date
        let sharingRules: [String: SharingVisibility]
        let defaultVisibility: SharingVisibility
        let destination: URL
    }

    typealias ShareExportWriter = (_ job: ShareExportJob, _ cancellation: @escaping () -> Bool) throws -> Void

    /// R14b: the model acts; no view observes it. Each view observes the stores its body reads (`navigationStore`,
    /// `snapshotStore`…), so a publication re-evaluates only the views that show it.
    final class DashboardViewModel {
        typealias SaveConfiguration = (RecorderConfig) throws -> RecorderConfig
        typealias DeleteDetails = (Date?, @escaping (Result<Int, Error>) -> Void) -> Void
        typealias DeleteTargetedDetails = (
            TargetedHistoryDeletionRequest,
            @escaping (Result<Int, Error>) -> Void
        ) -> Void

        /// R14b: page, Settings pane, day, welcome and sheet. A view reads it through its own `@ObservedObject`.
        let navigationStore: DashboardNavigation
        // R14b: shortcuts for this file only (a view reads the store, so it observes it). An unchanged value
        // publishes nothing.
        private var selectedSection: DashboardSection {
            get { navigationStore.selectedSection }
            set { if navigationStore.selectedSection != newValue { navigationStore.selectedSection = newValue } }
        }
        private var settingsPane: SettingsPane {
            get { navigationStore.settingsPane }
            set { if navigationStore.settingsPane != newValue { navigationStore.settingsPane = newValue } }
        }
        private var showingWebsiteShare: Bool {
            get { navigationStore.showingWebsiteShare }
            set { if navigationStore.showingWebsiteShare != newValue { navigationStore.showingWebsiteShare = newValue } }
        }
        private var showWelcome: Bool {
            get { navigationStore.showWelcome }
            set { if navigationStore.showWelcome != newValue { navigationStore.showWelcome = newValue } }
        }
        private var selectedDay: Date {
            get { navigationStore.selectedDay }
            set { navigationStore.setSelectedDay(newValue) }
        }
        private var secondaryReturn: DashboardSecondaryReturn? {
            get { navigationStore.secondaryReturn }
            set { navigationStore.setSecondaryReturn(newValue) }
        }
        /// The profile studio outlives any settings pane or page that opens it.
        @MainActor lazy var profileStudio = GoalongProfileStudioHost()
        /// R14b: the recording status, the free space and the window's visibility. A view reads them through its own
        /// `@ObservedObject`.
        let runtimeStore = DashboardRuntimeState()
        private var freeDiskCheckedAt: Date?
        /// R14b: the selected day's data. A view reads it through its own `@ObservedObject`.
        let snapshotStore: DashboardSnapshotStore
        // R14b: shortcuts for this file only (a view reads the store, so it observes it).
        private var runtime: RuntimePresentation { runtimeStore.runtime }
        private var freeDiskBytes: Int64? { runtimeStore.freeDiskBytes }
        private var snapshot: DashboardDaySnapshot { snapshotStore.snapshot }
        private var snapshotGeneration: UInt64 { snapshotStore.snapshotGeneration }
        private var isRefreshing: Bool { snapshotStore.isRefreshing }
        private var historyDeletionGeneration: Int { snapshotStore.historyDeletionGeneration }
        private var dashboardIsVisible: Bool { runtimeStore.dashboardIsVisible }
        private var dashboardStatusIsVisible: Bool { runtimeStore.dashboardStatusIsVisible }
        // R14b: no view reads these three (searched by name in Sources and Tests): they do not publish.
        var selectedSessionID: String?
        var activitySearch = ""
        var activityFilter: ActivityFilter = .all
        /// R14b: settings draft, sharing rules and config.json state. A view reads it through its own `@ObservedObject`.
        let settingsStore: DashboardSettingsState
        // R14b: shortcuts for this file only (a view reads the store, so it observes it). An unchanged value
        // publishes nothing.
        private var usageSearch: String {
            get { settingsStore.usageSearch }
            set { if settingsStore.usageSearch != newValue { settingsStore.usageSearch = newValue } }
        }
        private var settingsDraft: DashboardSettingsDraft {
            get { settingsStore.settingsDraft }
            set { if settingsStore.settingsDraft != newValue { settingsStore.settingsDraft = newValue } }
        }
        private var sharingRules: [String: SharingVisibility] {
            get { settingsStore.sharingRules }
            set { settingsStore.setSharing(rules: newValue) }
        }
        private var defaultSharingVisibility: SharingVisibility {
            get { settingsStore.defaultSharingVisibility }
            set { settingsStore.setSharing(rules: settingsStore.sharingRules, defaultVisibility: newValue) }
        }
        private var savedSettingsDraft: DashboardSettingsDraft {
            get { settingsStore.savedSettingsDraft }
            set { settingsStore.setSavedSettingsDraft(newValue) }
        }
        private var configNotice: String? { settingsStore.configNotice }
        private var configLocked: Bool { settingsStore.configLocked }
        private var configBackupName: String? { settingsStore.configBackupName }
        /// R14b: the alert and the export flag. A view reads them through its own `@ObservedObject`.
        let alertStore = DashboardAlertCenter()
        // R14b: shortcuts for this file only. Setting the same alert, or nil over nil, publishes nothing.
        private var alert: DashboardAlert? {
            get { alertStore.alert }
            set { if newValue?.id != alertStore.alert?.id { alertStore.alert = newValue } }
        }
        private var isExportingShare: Bool {
            get { alertStore.isExportingShare }
            set { alertStore.setExportingShare(newValue) }
        }

        /// R14b: what this Mac is identified as. A view reads it through its own `@ObservedObject`.
        let deviceStore: DashboardDeviceState
        // R14b: shortcuts for this file only (a view reads the store, so it observes it).
        private var deviceID: String { deviceStore.deviceID }
        private var knownDeviceID: String? { deviceStore.knownDeviceID }
        private var deviceTrustTier: String { deviceStore.deviceTrustTier }
        private var deviceAlgorithm: String { deviceStore.deviceAlgorithm }
        private var deviceProtectionTitle: String { deviceStore.deviceProtectionTitle }
        private var deviceProtectionSummary: String { deviceStore.deviceProtectionSummary }
        private var trustNotices: [String] { deviceStore.trustNotices }
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

        /// The date of `selectedDay`. A time zone change moves `selectedDay` to this date's new midnight.
        private var selectedCalendarDay: GoalongCalendarDay
        /// The « aujourd’hui » this model last saw; `followToday` compares it with the clock.
        private var seenToday: GoalongCalendarDay
        private var clockObservers: [NSObjectProtocol] = []

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
        /// Builds, verifies and writes the signed file; tests inject a slow or failing writer.
        private let shareExportWriter: ShareExportWriter?
        private let revealExportedFile: (URL) -> Void
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
        /// The recording status is fresh: the banner and the page bodies show it only then.
        private var recordingStatusIsLive: Bool { runtimeStore.recordingStatusIsLive }
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
            defaults: UserDefaults = GoalongDefaults.standard,
            availableBytes: @escaping () -> Int64? = { StorageHealth.availableBytes() },
            analyticsReader: GoalongAnalyticsReader = .shared,
            shareExportWriter: ShareExportWriter? = nil,
            revealExportedFile: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        ) {
            self.shareExportWriter = shareExportWriter
            self.revealExportedFile = revealExportedFile
            self.state = state
            self.permissions = permissions
            self.configManager = configManager
            self.sharingRulesStore = sharingRulesStore
            self.agentActivityRuntime = agentActivityRuntime
            self.onRetryKeychain = onRetryKeychain
            self.deviceStore = DashboardDeviceState(deviceInfo)
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
            navigationStore = DashboardNavigation(
                day: today, showWelcome: !defaults.bool(forKey: "didShowLocalHistoryConsentOnboardingV5"), now: now)
            selectedCalendarDay = GoalongCalendarDay(today)
            seenToday = selectedCalendarDay
            snapshotStore = DashboardSnapshotStore(day: today)
            settingsStore = DashboardSettingsState(
                draft: DashboardSettingsDraft(config: configManager.config), sharingRules: sharingRulesStore.rules,
                defaultSharingVisibility: sharingRulesStore.defaultVisibility)
            refreshTrustNotices()
            trustObserver = NotificationCenter.default.addObserver(
                forName: DeviceTrustState.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refreshTrustNotices()
            }
            refreshConfigStatus()
            for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
                clockObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    // Read the new zone, not the cached one.
                    if name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                    self?.followToday()
                })
            }
            configObserver = NotificationCenter.default.addObserver(
                forName: .goalongConfigStatusDidChange, object: configManager, queue: .main
            ) { [weak self] _ in
                self?.refreshConfigStatus()
            }
        }

        func refreshConfigStatus() {
            let notice = configManager.statusNotice
            settingsStore.setConfigStatus(notice: notice, locked: configManager.isFailClosed,
                backupName: notice == nil ? configManager.lastDamagedBackupName : nil)
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
            deviceStore.setTrustNotices([
                DeviceTrustState.shared.sealingSuspendedNotice,
                DeviceIdentityRotation.load(defaults: defaults)?.notice,
            ].compactMap { $0 })
        }

        func updateDeviceInfo(_ info: DeviceIdentityInfo) {
            deviceStore.update(info)
        }

        deinit {
            if let trustObserver { NotificationCenter.default.removeObserver(trustObserver) }
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
            refreshScheduler.deactivate()
            cancelDataRequest()
            cancelMetadataRequest()
            cancelShareExport()
        }

        private var isTodaySelected: Bool { navigationStore.isTodaySelected }

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

        private var settingsHaveChanges: Bool { settingsStore.settingsHaveChanges }

        /// After midnight or a time zone change, a page left on the old « aujourd’hui » moves to the new one.
        /// A day chosen by the user keeps its date: after a time zone change it moves to that date's new midnight.
        /// Also called by the 60 s pass, which catches a sleep across midnight.
        func followToday() {
            let today = GoalongCalendarDay(now())
            guard today != seenToday || selectedDay != selectedCalendarDay.start() else { return }
            let wasOnToday = selectedCalendarDay == seenToday
            seenToday = today
            if wasOnToday { show(today) } else if !show(selectedCalendarDay) { updateRefreshSchedule() }
        }


        func selectDay(_ date: Date) {
            show(GoalongCalendarDay(date))
        }

        /// Shows `day` at its midnight in the current zone. False when that is already shown.
        @discardableResult
        private func show(_ day: GoalongCalendarDay) -> Bool {
            let start = day.start()
            selectedCalendarDay = day
            guard start != selectedDay else { return false }
            selectedDay = start
            selectedSessionID = nil
            updateRefreshSchedule()
            refreshData(force: true)
            return true
        }

        /// Opens Réglages on one pane. `selectSection(.settings)` resets the pane, so it is set after.
        func openSettingsPane(_ pane: SettingsPane) {
            selectSection(.settings)
            settingsPane = pane
        }

        /// Lot 2a (11): the last main page, read again when the window reopens.
        static let lastPageKey = "goalong.dashboard.lastPage"

        /// The main page the window reopens on: the last one shown, else Activité. Ambiance only while its module is on.
        func lastMainSection(ambianceAvailable: Bool) -> DashboardSection {
            guard let raw = defaults.string(forKey: Self.lastPageKey), let section = DashboardSection(rawValue: raw),
                  !section.isSecondary, section != .work, section != .monitoring, section != .analytics
            else { return .overview }
            if section == .ambiance, !ambianceAvailable { return .overview }
            return section
        }

        func selectSection(_ section: DashboardSection) {
            // « Mon travail » is no page any more: the definition is the pane « Définition du travail » of Réglages.
            // Jev (`.monitoring`) is a rule of the page « Blocages », which opens its editor.
            if section == .work {
                openSettingsPane(.work)
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
            // Lot 2a (7): « Réglages » keeps the open pane; only a click on Réglages while already there goes home.
            if section == .settings, previousSection == .settings { settingsPane = .home }
            if section != previousSection {
                // R13c: a measure left open never closes on another page's read.
                GoalongSwitchTiming.cancel(previousSection.rawValue)
                GoalongSwitchTiming.begin(section.rawValue)
            }
            selectedSection = section
            if !section.isSecondary { defaults.set(section.sidebarParent.rawValue, forKey: Self.lastPageKey) }
            navigationStore.sectionRequests.send(section)
            if dashboardIsVisible, section == .agentActivity {
                agentActivityRuntime.scanNow(
                    forceFullDiscovery: false,
                    analyzeSelectedDay: true
                )
            }
        }

        /// The editor of a rule closed. Jev's destination opened its rule once: the page is the plain « Blocages »
        /// again, so showing it again (window reopened, another rule closed) does not open the Jev rule a second time.
        /// Same kept page: no switch to time, no request to send.
        func blockRuleEditorClosed() {
            if selectedSection == .monitoring { selectedSection = .blocking }
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

        private var secondaryReturnTitle: String { navigationStore.secondaryReturnTitle }
        private var highlightedSidebarSection: DashboardSection { navigationStore.highlightedSidebarSection }

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
            runtimeStore.setDashboardVisible(true)
            followToday()
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

        /// A visible window beside another app keeps its recording and storage status current,
        /// without the data and metadata readers that `dashboardDidBecomeVisible` starts.
        func dashboardStatusDidBecomeVisible() {
            guard !dashboardStatusIsVisible else { return }
            runtimeStore.setStatusVisible(true)
            // With the keyboard, dashboardDidBecomeVisible already read the status and armed the timers.
            guard !dashboardIsVisible else { return }
            refreshRuntime()
            updateRefreshSchedule()
        }

        func dashboardStatusDidBecomeHidden() {
            guard dashboardStatusIsVisible else { return }
            runtimeStore.setStatusVisible(false)
            guard !dashboardIsVisible else { return }
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
            runtimeStore.setDashboardVisible(false)
            refreshScheduler.deactivate()
            updateRefreshSchedule()
            dataRequestSequence &+= 1
            metadataRequestSequence &+= 1
            cancelDataRequest()
            cancelMetadataRequest()
            // A signed export keeps running: the user chose the file, and losing the keyboard
            // or hiding the window is not a reason to drop it. Only a real close stops it.
            discardShareCache()
            dataRefreshPending = false
            snapshotStore.setRefreshing(false)
            if discardContents { discardVisibleSnapshot() }
            agentActivityRuntime.dashboardDidBecomeHidden()
            let reader = dataReader
            dataQueue.async {
                reader.discardTransientCaches()
            }
        }

        /// The window is closing for real, not merely losing the keyboard or hiding.
        func dashboardWillClose() {
            if activeShareExportToken != nil {
                cancelShareExport()
                alert = DashboardAlert(
                    kind: .error,
                    title: "Export interrompu",
                    message: "La fenêtre a été fermée avant la fin de l’export. Relancez-le."
                )
            }
            dashboardDidBecomeHidden()
        }

        private func discardVisibleSnapshot() {
            snapshotStore.discard(day: selectedDay)
        }

        /// R14b: shows a read unless it equals the shown one on every field (the 60 s pass on a quiet day publishes
        /// nothing). The first read after the placeholder is always shown, so the generation tells a read from it.
        @discardableResult
        func publishSnapshot(_ next: DashboardDaySnapshot) -> Bool {
            snapshotStore.show(next)
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
                    message: "Aucune donnée avec preuve pour ce jour."
                )
                return
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(AppPaths.localDayString(for: selectedDay)).signed-share.json"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            startShareExport(to: destination)
        }

        /// Exports the selected day to a chosen destination. Tests call it without a save panel.
        func startShareExport(to destination: URL) {
            let day = selectedDay
            let rules = sharingRules
            let defaultVisibility = defaultSharingVisibility
            activeShareExportToken?.cancel()
            let token = DashboardCancellationToken()
            activeShareExportToken = token
            isExportingShare = true

            let job = ShareExportJob(
                day: day,
                sharingRules: rules,
                defaultVisibility: defaultVisibility,
                destination: destination
            )
            shareQueue.async { [weak self] in
                guard let self else { return }
                do {
                    if let writer = self.shareExportWriter {
                        try writer(job, { token.isCancelled })
                    } else {
                        try self.writeSharePackage(job, cancellation: { token.isCancelled })
                    }
                    DispatchQueue.main.async {
                        guard self.activeShareExportToken === token else { return }
                        self.activeShareExportToken = nil
                        self.isExportingShare = false
                        self.alert = DashboardAlert(
                            kind: .information,
                            title: "Fichier signé exporté",
                            message:
                                "Goalong a vérifié chaque signature de l’appareil et la chaîne d’intégrité avant l’export. Le fichier suit vos règles d’apps et de sites ; les champs masqués restent sur ce Mac."
                        )
                        self.revealExportedFile(destination)
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

        private func writeSharePackage(_ job: ShareExportJob, cancellation: @escaping () -> Bool) throws {
            let privacyRoot = AppPaths.applicationSupportDirectory
            let privacy = GoalongPrivacyPolicy.load(in: privacyRoot)
            let package = try shareBuilder.build(
                for: job.day,
                sharingRules: job.sharingRules,
                defaultVisibility: job.defaultVisibility,
                privacy: privacy,
                cancellation: cancellation
            )
            guard !cancellation() else { throw ShareBuildError.cancelled }
            guard GoalongPrivacyPolicy.load(in: privacyRoot).revision == privacy.revision else {
                throw ShareBuildError.exclusionsChanged
            }
            guard package.verificationReport().isLocallyValid else {
                throw ShareBuildError.brokenSeal(package.minutes.first?.anchorSequence ?? 0)
            }
            try shareBuilder.write(package, to: job.destination, cancellation: cancellation)
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
                                 defaults: UserDefaults = GoalongDefaults.standard,
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
                    } catch { rollbackError = GoalongUserFacingError.message(error) }
                }
                settingsDraft = savedSettingsDraft
                alert = DashboardAlert(kind: .error, title: "Enregistrement non confirmé",
                    message: GoalongUserFacingError.message(error) + (rollbackError.map { " Vérifiez le profil actuel : " + $0 } ?? " Vos choix précédents sont conservés."))
                return false
            }
        }

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
                alert = DashboardAlert(kind: .error, title: "Les choix n’ont pas pu être enregistrés", message: GoalongUserFacingError.message(error))
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

        private var mostRecentActivitySession: ActivitySession? {
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
                        self.snapshotStore.historyWasDeleted()
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
                if dashboardStatusIsVisible {
                    refreshScheduler.activateRuntimeOnly { [weak self] in self?.refreshRuntime() }
                } else {
                    refreshScheduler.deactivate()
                }
                return
            }
            refreshScheduler.activate(
                isToday: isTodaySelected,
                refreshRuntime: { [weak self] in self?.refreshRuntime() },
                refreshData: { [weak self] in
                    guard let self else { return }
                    self.followToday()
                    self.refreshData(force: false)
                    self.refreshMetadataIfNeeded(force: false)
                }
            )
        }

        /// Read on demand by the diagnostics panel; never published, see RuntimePresentation.==.
        func liveCaptureHealthSnapshot() -> CaptureHealthSnapshot { captureHealthSnapshot() }

        private func refreshRuntime() {
            guard recordingStatusIsLive else { return }
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

            if freeDiskCheckedAt.map({ now().throttleElapsed(since: $0) >= 60 }) ?? true {
                freeDiskCheckedAt = now()
                let free = availableBytes()
                runtimeStore.setFreeDiskBytes(free)
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
                captureHealth: health,
                storageInterruptedSince: health.state == .storageUnavailable ? healthSnapshot.storageInterruptedSince : nil
            )
            runtimeStore.setRuntime(next)
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
            if force { snapshotStore.setRefreshing(true) }
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
                    self.snapshotStore.setRefreshing(false)
                    let shouldCatchUp = self.dataRefreshPending
                    self.dataRefreshPending = false
                    guard self.dashboardIsVisible, !token.isCancelled, let next else { return }
                    guard self.selectedDay == day else {
                        self.refreshData(force: true)
                        return
                    }
                    self.publishSnapshot(next)
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
                    self.snapshotStore.applyMetadata(self.dataReader.applyingCachedMetadata(to: self.snapshot))
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
