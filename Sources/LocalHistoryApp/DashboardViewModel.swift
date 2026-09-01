#if os(macOS)
    import AppKit
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
        @Published private(set) var runtime: RuntimePresentation = .unavailable
        @Published private(set) var snapshot: DashboardDaySnapshot
        @Published private(set) var snapshotGeneration: UInt64 = 0
        @Published private(set) var isRefreshing = false
        @Published private(set) var shareSegments: [ShareSegment] = []
        @Published private(set) var isLoadingShare = false
        @Published private(set) var isExportingShare = false
        @Published var selectedShareSegmentID: String?
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

        let deviceID: String
        let deviceTrustTier: String
        let deviceAlgorithm: String
        let deviceProtectionTitle: String
        let deviceProtectionSummary: String
        let agentActivityRuntime: AgentActivityRuntime

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
        private var shareRequestSequence: UInt64 = 0
        private var activeShareRequest:
            (
                day: Date,
                token: DashboardCancellationToken,
                workItem: DispatchWorkItem
            )?
        private var shareRefreshPending = false
        private var activeShareExportToken: DashboardCancellationToken?

        init(
            state: CaptureState,
            permissions: PermissionManager,
            configManager: ConfigManager,
            sharingRulesStore: SharingRulesStore,
            agentActivityRuntime: AgentActivityRuntime,
            deviceInfo: DeviceIdentityInfo,
            eventTapStatus: @escaping () -> Bool,
            currentSuppression: @escaping () -> SuppressionReason?,
            captureHealthSnapshot: @escaping () -> CaptureHealthSnapshot,
            onBeginCaptureValidation: @escaping () -> Void,
            onTogglePause: @escaping () -> Void,
            onRequestPermissions: @escaping () -> Void,
            onSaveConfiguration: @escaping SaveConfiguration,
            onDeleteDetails: @escaping DeleteDetails,
            onDeleteTargetedDetails: @escaping DeleteTargetedDetails,
            refreshScheduler: DashboardRefreshScheduler = DashboardRefreshScheduler(),
            dataReader: DashboardDataReader = DashboardDataReader()
        ) {
            self.state = state
            self.permissions = permissions
            self.configManager = configManager
            self.sharingRulesStore = sharingRulesStore
            self.agentActivityRuntime = agentActivityRuntime
            self.sharingRules = sharingRulesStore.rules
            self.defaultSharingVisibility = sharingRulesStore.defaultVisibility
            self.deviceID = deviceInfo.deviceID
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
            self.refreshScheduler = refreshScheduler
            self.dataReader = dataReader

            let today = Calendar.current.startOfDay(for: Date())
            selectedDay = today
            snapshot = .empty(day: today)
            let draft = DashboardSettingsDraft(config: configManager.config)
            settingsDraft = draft
            savedSettingsDraft = draft
            showWelcome = !UserDefaults.standard.bool(forKey: "didShowLocalHistoryConsentOnboardingV5")

        }

        deinit {
            refreshScheduler.deactivate()
            cancelDataRequest()
            cancelMetadataRequest()
            cancelShareRequest()
            cancelShareExport()
        }

        var isTodaySelected: Bool {
            Calendar.current.isDateInToday(selectedDay)
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

        var selectedShareSegment: ShareSegment? {
            guard let selectedShareSegmentID else { return shareSegments.first }
            return shareSegments.first(where: { $0.id == selectedShareSegmentID }) ?? shareSegments.first
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
                    title: "Sharing rule could not be saved",
                    message: String(describing: error)
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
                    title: "Default sharing rule could not be saved",
                    message: String(describing: error)
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
            selectedShareSegmentID = nil
            cancelShareRequest()
            shareSegments = []
            updateRefreshSchedule()
            refreshData(force: true)
            if selectedSection == .share { reloadShareSegments() }
        }

        func selectSection(_ section: DashboardSection) {
            let previousSection = selectedSection
            selectedSection = section
            if section == .share {
                reloadShareSegments()
            } else if previousSection == .share, section != .share {
                cancelShareRequest()
            }
            if dashboardIsVisible, section == .agentActivity {
                agentActivityRuntime.scanNow(
                    forceFullDiscovery: false,
                    analyzeSelectedDay: true
                )
            }
        }

        func refreshEverything() {
            guard dashboardIsVisible else { return }
            refreshRuntime()
            refreshData(force: true)
            refreshMetadataIfNeeded(force: false)
            if selectedSection == .share { reloadShareSegments() }
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
            if selectedSection == .share { reloadShareSegments() }
            if selectedSection == .agentActivity {
                agentActivityRuntime.scanNow(
                    forceFullDiscovery: false,
                    analyzeSelectedDay: true
                )
            }
            updateRefreshSchedule()
        }

        func dashboardDidBecomeHidden() {
            guard dashboardIsVisible else { return }
            dashboardIsVisible = false
            refreshScheduler.deactivate()
            dataRequestSequence &+= 1
            metadataRequestSequence &+= 1
            cancelDataRequest()
            cancelMetadataRequest()
            cancelShareRequest()
            cancelShareExport()
            discardShareCache()
            dataRefreshPending = false
            isRefreshing = false
            snapshot = .empty(day: selectedDay)
            snapshotGeneration &+= 1
            shareSegments = []
            selectedShareSegmentID = nil
            agentActivityRuntime.dashboardDidBecomeHidden()
            let reader = dataReader
            dataQueue.async {
                reader.discardTransientCaches()
            }
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
            UserDefaults.standard.set(true, forKey: "didShowLocalHistoryConsentOnboardingV5")
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
            if !FileManager.default.fileExists(atPath: AppPaths.diagnosticsFile.path) {
                FileManager.default.createFile(
                    atPath: AppPaths.diagnosticsFile.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                )
            }
            GoalongWorkspaceOpenPolicy.open(AppPaths.diagnosticsFile, purpose: .localFile)
        }

        func selectSession(_ id: String) {
            selectedSessionID = id
        }

        func setShareLevel(_ level: ShareLevel, for segmentID: String) {
            guard let index = shareSegments.firstIndex(where: { $0.id == segmentID }) else { return }
            var updated = shareSegments
            let segment = updated[index]
            updated[index].level = segment.canRevealDetails ? level : .privateOnly
            shareSegments = updated
            selectedShareSegmentID = segmentID
        }

        func applySharePreset(_ level: ShareLevel) {
            var updated = shareSegments
            for index in updated.indices {
                updated[index].level = updated[index].canRevealDetails ? level : .privateOnly
            }
            shareSegments = updated
        }

        func reloadShareSegments() {
            guard dashboardIsVisible, selectedSection == .share else { return }
            if let activeShareRequest {
                if activeShareRequest.day == selectedDay {
                    // Coalesce repeated timer/UI requests into one latest-state pass.
                    shareRefreshPending = true
                    return
                }
                cancelShareRequest()
            }
            isLoadingShare = true
            shareRequestSequence &+= 1
            let requestSequence = shareRequestSequence
            let day = selectedDay
            let token = DashboardCancellationToken()
            let previousLevels = Dictionary(
                uniqueKeysWithValues: shareSegments.flatMap { segment in
                    segment.anchorSequences.map { ($0, segment.level) }
                }
            )

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let result: Result<[ShareSegment], Error>
                do {
                    var rows = try self.shareBuilder.minuteRows(
                        for: day,
                        cancellation: { token.isCancelled }
                    )
                    for index in rows.indices {
                        guard !token.isCancelled else { throw ShareBuildError.cancelled }
                        if let level = previousLevels[rows[index].anchorSequence] {
                            rows[index].level = rows[index].canRevealDetails ? level : .privateOnly
                        }
                    }
                    guard !token.isCancelled else { throw ShareBuildError.cancelled }
                    result = .success(Self.makeShareSegments(from: rows))
                } catch ShareBuildError.noSeals {
                    result = .success([])
                } catch {
                    result = .failure(error)
                }

                DispatchQueue.main.async {
                    guard self.shareRequestSequence == requestSequence else { return }
                    self.activeShareRequest = nil
                    self.isLoadingShare = false
                    let shouldCatchUp = self.shareRefreshPending
                    self.shareRefreshPending = false
                    guard self.dashboardIsVisible,
                        self.selectedSection == .share,
                        !token.isCancelled
                    else { return }
                    guard self.selectedDay == day else {
                        self.reloadShareSegments()
                        return
                    }

                    switch result {
                    case .success(let segments):
                        self.shareSegments = segments
                        if let selected = self.selectedShareSegmentID,
                            !segments.contains(where: { $0.id == selected })
                        {
                            self.selectedShareSegmentID = segments.first?.id
                        } else if self.selectedShareSegmentID == nil {
                            self.selectedShareSegmentID = segments.first?.id
                        }
                    case .failure(let error):
                        if let buildError = error as? ShareBuildError,
                            case .cancelled = buildError
                        {
                            return
                        }
                        self.shareSegments = []
                        self.alert = DashboardAlert(
                            kind: .error,
                            title: "Share data could not be loaded",
                            message: String(describing: error)
                        )
                    }
                    if shouldCatchUp { self.reloadShareSegments() }
                }
            }
            activeShareRequest = (day, token, workItem)
            shareQueue.async(execute: workItem)
        }

        func exportSharePackage() {
            guard snapshot.sealedMinutes > 0 else {
                alert = DashboardAlert(
                    kind: .information,
                    title: "Nothing to export",
                    message: "No sealed minutes are available for the selected day yet."
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
                    let package = try self.shareBuilder.build(
                        for: day,
                        sharingRules: rules,
                        defaultVisibility: defaultVisibility,
                        cancellation: { token.isCancelled }
                    )
                    guard !token.isCancelled else { throw ShareBuildError.cancelled }
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
                            title: "Locally signed package exported",
                            message:
                                "Goalong verified every included P-256 device signature and integrity chain before export. The package follows your saved app and website rules; hidden fields remain on this Mac."
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
                            title: "Export failed",
                            message: String(describing: error)
                        )
                    }
                }
            }
        }

        func saveSettings() {
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
                        title: "Invalid verification server",
                        message: "Use an HTTPS URL. HTTP is accepted only for localhost development."
                    )
                    return
                }
            }

            do {
                let requested = settingsDraft.applying(to: configManager.config)
                let applied = try onSaveConfiguration(requested)
                let refreshed = DashboardSettingsDraft(config: applied)
                settingsDraft = refreshed
                savedSettingsDraft = refreshed
                refreshRuntime()
                alert = DashboardAlert(
                    kind: .information,
                    title: "Settings saved",
                    message:
                        "Capture and verification settings are active. Retention cleanup is also applied on the next launch."
                )
            } catch {
                alert = DashboardAlert(
                    kind: .error,
                    title: "Settings could not be saved",
                    message: String(describing: error)
                )
            }
        }

        func configureCaptureForOnboarding(enabled: Bool) throws {
            var draft = settingsDraft
            draft.captureClicks = enabled
            draft.captureScroll = enabled
            draft.captureKeyboardActivity = enabled
            draft.captureShortcuts = enabled
            draft.captureWindowTitles = enabled
            draft.captureElementLabels = enabled
            draft.captureURLs = enabled
            draft.verificationEnabled = false
            draft.verificationServerURL = ""
            draft.enableAppAttest = false
            let applied = try onSaveConfiguration(draft.applying(to: configManager.config))
            let refreshed = DashboardSettingsDraft(config: applied)
            settingsDraft = refreshed
            savedSettingsDraft = refreshed
            refreshRuntime()
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
                            title: "Local details deleted",
                            message: cutoff == nil
                                ? "Deleted \(count) local event file(s). Existing seals and receipts remain, so those periods can still be shown as private."
                                : "Deleted \(count) detailed event(s). Existing seals and receipts remain."
                        )
                        self.refreshData(force: true)
                        self.reloadShareSegments()
                    case .failure(let error):
                        self.alert = DashboardAlert(
                            kind: .error,
                            title: "Deletion failed",
                            message: String(describing: error)
                        )
                    }
                }
            }
        }

        func deleteComputerHistoryEpisode(_ episode: ComputerHistoryEpisode, day: Date) {
            deleteTargetedDetails(
                .computerHistoryEpisode(id: episode.id, day: day),
                successMessage:
                    "Deleted the selected Computer History item and its exact local source details. Existing seals and receipts remain."
            )
        }

        func deleteActivitySession(_ session: ActivitySession) {
            deleteTargetedDetails(
                .activitySession(session),
                successMessage:
                    "Deleted the selected app session and its exact local source details. Existing seals and receipts remain."
            )
        }

        var mostRecentActivitySession: ActivitySession? {
            snapshot.sessions.first
        }

        private func deleteTargetedDetails(
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
                            title: "Local item deleted",
                            message: "\(successMessage) Removed \(count) local item(s)."
                        )
                        self.refreshData(force: true)
                        self.reloadShareSegments()
                    case .failure(let error):
                        self.alert = DashboardAlert(
                            kind: .error,
                            title: "Deletion failed",
                            message: String(describing: error)
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
                    if self.selectedSection == .share { self.reloadShareSegments() }
                }
            )
        }

        private func refreshRuntime() {
            guard dashboardIsVisible else { return }
            let status = permissions.snapshot
            let tap = eventTapStatus()
            let healthSnapshot = captureHealthSnapshot()
            let health = CaptureHealthEvaluator.assess(healthSnapshot)
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
                captureHealthSnapshot: healthSnapshot
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
            isRefreshing = true
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
                    self.isRefreshing = false
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

        private func cancelShareRequest() {
            shareRequestSequence &+= 1
            activeShareRequest?.token.cancel()
            activeShareRequest?.workItem.cancel()
            activeShareRequest = nil
            shareRefreshPending = false
            isLoadingShare = false
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

        private static func makeShareSegments(from rows: [ShareMinuteRow]) -> [ShareSegment] {
            struct Accumulator {
                var sequences: [UInt64]
                var start: Date
                var end: Date
                var appSummary: String
                var categorySummary: String
                var canRevealDetails: Bool
                var level: ShareLevel
            }

            var accumulators: [Accumulator] = []
            for row in rows.sorted(by: { $0.start < $1.start }) {
                let canMerge: Bool
                if let last = accumulators.last {
                    let contiguous = abs(row.start.timeIntervalSince(last.end)) <= 1.5
                    canMerge =
                        contiguous
                        && last.appSummary == row.appSummary
                        && last.categorySummary == row.categorySummary
                        && last.canRevealDetails == row.canRevealDetails
                        && last.level == row.level
                } else {
                    canMerge = false
                }

                if canMerge {
                    let index = accumulators.count - 1
                    accumulators[index].sequences.append(row.anchorSequence)
                    accumulators[index].end = max(accumulators[index].end, row.end)
                } else {
                    accumulators.append(
                        Accumulator(
                            sequences: [row.anchorSequence],
                            start: row.start,
                            end: row.end,
                            appSummary: row.appSummary,
                            categorySummary: row.categorySummary,
                            canRevealDetails: row.canRevealDetails,
                            level: row.canRevealDetails ? row.level : .privateOnly
                        ))
                }
            }

            return accumulators.map { item in
                let first = item.sequences.first ?? 0
                let last = item.sequences.last ?? first
                return ShareSegment(
                    id: "\(first)-\(last)",
                    anchorSequences: item.sequences,
                    start: item.start,
                    end: item.end,
                    appSummary: item.appSummary,
                    categorySummary: item.categorySummary,
                    canRevealDetails: item.canRevealDetails,
                    level: item.level
                )
            }
        }

        private static func isValidVerificationURL(_ raw: String) -> Bool {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
            if scheme == "https" { return url.host != nil }
            return scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
        }
    }
#endif
