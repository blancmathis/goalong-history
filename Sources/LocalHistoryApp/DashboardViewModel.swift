#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import LocalHistoryCore
    import UniformTypeIdentifiers

    final class DashboardViewModel: ObservableObject {
        typealias SaveConfiguration = (RecorderConfig) throws -> RecorderConfig
        typealias DeleteDetails = (Date?, @escaping (Result<Int, Error>) -> Void) -> Void

        @Published var selectedSection: DashboardSection = .overview
        @Published private(set) var runtime: RuntimePresentation = .unavailable
        @Published private(set) var snapshot: DashboardDaySnapshot
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

        let deviceID: String
        let deviceTrustTier: String
        let deviceAlgorithm: String

        private(set) var selectedDay: Date
        private var savedSettingsDraft: DashboardSettingsDraft

        private let state: CaptureState
        private let permissions: PermissionManager
        private let configManager: ConfigManager
        private let sharingRulesStore: SharingRulesStore
        private let eventTapStatus: () -> Bool
        private let currentSuppression: () -> SuppressionReason?
        private let onTogglePause: () -> Void
        private let onRequestPermissions: () -> Void
        private let onSaveConfiguration: SaveConfiguration
        private let onDeleteDetails: DeleteDetails
        private let dataReader = DashboardDataReader()
        private let shareBuilder = SharePackageBuilder()
        private let dataQueue = DispatchQueue(label: "ai.goalong.localhistory.dashboard-data", qos: .userInitiated)
        private let shareQueue = DispatchQueue(label: "ai.goalong.localhistory.dashboard-share", qos: .userInitiated)
        private var runtimeTimer: Timer?
        private var dataTimer: Timer?

        init(
            state: CaptureState,
            permissions: PermissionManager,
            configManager: ConfigManager,
            sharingRulesStore: SharingRulesStore,
            deviceInfo: DeviceIdentityInfo,
            eventTapStatus: @escaping () -> Bool,
            currentSuppression: @escaping () -> SuppressionReason?,
            onTogglePause: @escaping () -> Void,
            onRequestPermissions: @escaping () -> Void,
            onSaveConfiguration: @escaping SaveConfiguration,
            onDeleteDetails: @escaping DeleteDetails
        ) {
            self.state = state
            self.permissions = permissions
            self.configManager = configManager
            self.sharingRulesStore = sharingRulesStore
            self.sharingRules = sharingRulesStore.rules
            self.defaultSharingVisibility = sharingRulesStore.defaultVisibility
            self.deviceID = deviceInfo.deviceID
            self.deviceTrustTier = deviceInfo.trustTier
            self.deviceAlgorithm = deviceInfo.algorithm
            self.eventTapStatus = eventTapStatus
            self.currentSuppression = currentSuppression
            self.onTogglePause = onTogglePause
            self.onRequestPermissions = onRequestPermissions
            self.onSaveConfiguration = onSaveConfiguration
            self.onDeleteDetails = onDeleteDetails

            let today = Calendar.current.startOfDay(for: Date())
            selectedDay = today
            snapshot = .empty(day: today)
            let draft = DashboardSettingsDraft(config: configManager.config)
            settingsDraft = draft
            savedSettingsDraft = draft
            showWelcome = !UserDefaults.standard.bool(forKey: "didShowLocalHistoryOnboardingV3")

            refreshRuntime()
            refreshData(force: true)
            startTimers()
        }

        deinit {
            runtimeTimer?.invalidate()
            dataTimer?.invalidate()
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
            refreshData(force: true)
            reloadShareSegments()
        }

        func selectSection(_ section: DashboardSection) {
            selectedSection = section
            if section == .share, shareSegments.isEmpty {
                reloadShareSegments()
            }
        }

        func refreshEverything() {
            refreshRuntime()
            refreshData(force: true)
            if selectedSection == .share { reloadShareSegments() }
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

        func openAccessibilitySettings() {
            permissions.openAccessibilitySettings()
        }

        func openInputMonitoringSettings() {
            permissions.openInputMonitoringSettings()
        }

        func dismissWelcome() {
            UserDefaults.standard.set(true, forKey: "didShowLocalHistoryOnboardingV3")
            showWelcome = false
        }

        func openDataFolder() {
            NSWorkspace.shared.open(AppPaths.applicationSupportDirectory)
        }

        func openConfiguration() {
            NSWorkspace.shared.open(AppPaths.configFile)
        }

        func openTodayJSON() {
            let file = AppPaths.eventFileURL(for: selectedDay)
            if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.open(file)
            } else {
                NSWorkspace.shared.open(AppPaths.eventsDirectory)
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
            NSWorkspace.shared.open(AppPaths.diagnosticsFile)
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
            guard !isLoadingShare else { return }
            isLoadingShare = true
            let day = selectedDay
            let previousLevels = Dictionary(
                uniqueKeysWithValues: shareSegments.flatMap { segment in
                    segment.anchorSequences.map { ($0, segment.level) }
                }
            )

            shareQueue.async { [weak self] in
                guard let self else { return }
                do {
                    var rows = try self.shareBuilder.minuteRows(for: day)
                    for index in rows.indices {
                        if let level = previousLevels[rows[index].anchorSequence] {
                            rows[index].level = rows[index].canRevealDetails ? level : .privateOnly
                        }
                    }
                    let segments = Self.makeShareSegments(from: rows)
                    DispatchQueue.main.async {
                        self.isLoadingShare = false
                        guard self.selectedDay == day else {
                            self.reloadShareSegments()
                            return
                        }
                        self.shareSegments = segments
                        if let selected = self.selectedShareSegmentID,
                            !segments.contains(where: { $0.id == selected })
                        {
                            self.selectedShareSegmentID = segments.first?.id
                        } else if self.selectedShareSegmentID == nil {
                            self.selectedShareSegmentID = segments.first?.id
                        }
                    }
                } catch ShareBuildError.noSeals {
                    DispatchQueue.main.async {
                        self.isLoadingShare = false
                        guard self.selectedDay == day else {
                            self.reloadShareSegments()
                            return
                        }
                        self.shareSegments = []
                        self.selectedShareSegmentID = nil
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isLoadingShare = false
                        guard self.selectedDay == day else {
                            self.reloadShareSegments()
                            return
                        }
                        self.shareSegments = []
                        self.alert = DashboardAlert(
                            kind: .error,
                            title: "Share data could not be loaded",
                            message: String(describing: error)
                        )
                    }
                }
            }
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
            panel.nameFieldStringValue = "\(AppPaths.localDayString(for: selectedDay)).verified-share.json"
            guard panel.runModal() == .OK, let destination = panel.url else { return }

            let day = selectedDay
            let rules = sharingRules
            let defaultVisibility = defaultSharingVisibility
            isExportingShare = true

            shareQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let package = try self.shareBuilder.build(
                        for: day,
                        sharingRules: rules,
                        defaultVisibility: defaultVisibility
                    )
                    guard package.minutes.allSatisfy({ $0.verifiesStructure() }) else {
                        throw ShareBuildError.brokenSeal(package.minutes.first?.anchorSequence ?? 0)
                    }
                    try self.shareBuilder.write(package, to: destination)
                    DispatchQueue.main.async {
                        self.isExportingShare = false
                        self.alert = DashboardAlert(
                            kind: .information,
                            title: "Verified package exported",
                            message:
                                "The package follows your saved app and website rules. Hidden fields remain on this Mac."
                        )
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isExportingShare = false
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

        private func startTimers() {
            let runtimeTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.refreshRuntime()
            }
            let dataTimer = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
                guard let self, self.isTodaySelected else { return }
                self.refreshData(force: false)
                if self.selectedSection == .share { self.reloadShareSegments() }
            }
            RunLoop.main.add(runtimeTimer, forMode: .common)
            RunLoop.main.add(dataTimer, forMode: .common)
            self.runtimeTimer = runtimeTimer
            self.dataTimer = dataTimer
        }

        private func refreshRuntime() {
            let status = permissions.currentStatus
            let tap = eventTapStatus()
            let runtimeState: RuntimeStateKind
            if !status.allGranted {
                runtimeState = .permissionsMissing
            } else if state.isManuallyPaused {
                runtimeState = .paused
            } else if let suppression = currentSuppression() {
                runtimeState = .suppressed(suppression)
            } else if !tap {
                runtimeState = .inputTapUnavailable
            } else {
                runtimeState = .recording
            }

            let next = RuntimePresentation(
                state: runtimeState,
                accessibilityGranted: status.accessibility,
                inputMonitoringGranted: status.inputMonitoring,
                eventTapRunning: tap,
                verificationEnabled: configManager.config.verificationEnabled == true,
                verificationServer: configManager.config.verificationServerURL
            )
            if next != runtime { runtime = next }
        }

        private func refreshData(force: Bool) {
            guard !isRefreshing else { return }
            isRefreshing = true
            let day = selectedDay
            dataQueue.async { [weak self] in
                guard let self else { return }
                let next = self.dataReader.snapshot(for: day)
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    guard self.selectedDay == day else {
                        self.refreshData(force: true)
                        return
                    }
                    self.snapshot = next
                    if let selected = self.selectedSessionID,
                        !self.filteredSessions.contains(where: { $0.id == selected })
                    {
                        self.selectedSessionID = self.filteredSessions.first?.id
                    }
                }
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
