#if os(macOS)
    import AppKit
    import AppleScreenTime
    import AppleSystemScreenTime
    import Combine
    import Foundation
    import UniformTypeIdentifiers

    final class AppleScreenTimeDashboardModel: ObservableObject {
        typealias CollectionProvider = (Date) -> AppleSystemScreenTimeCollection

        /// Apple/iCloud usage stores do not meaningfully update at sub-second cadence.
        /// Keep the visible dashboard responsive without repeatedly enumerating them.
        static let defaultRefreshInterval: TimeInterval = 30

        @Published var selectedDay: Date
        @Published var configuration: AppleScreenTimeConfiguration
        @Published private(set) var summary: AppleScreenTimeDaySummary?
        @Published private(set) var unfilteredSummary: AppleScreenTimeDaySummary?
        @Published private(set) var availableDevices: [AppleScreenTimeDevice] = []
        @Published private(set) var isBusy = false
        @Published private(set) var lastRefreshAt: Date?
        @Published private(set) var latestAppleUpdate: Date?
        @Published private(set) var status: AppleSystemScreenTimeStatus = .loading
        @Published private(set) var knowledgeIntervalCount = 0
        @Published private(set) var biomeIntervalCount = 0
        @Published private(set) var screenTimeAppUsageIntervalCount = 0
        @Published var alert: AppleScreenTimeDashboardAlert?
        @Published private(set) var accessEnabled: Bool

        let currentMacDevice: AppleScreenTimeDevice

        private let store: AppleScreenTimeStore?
        private let appleSource: AppleSystemScreenTimeSource
        private let collectionProvider: CollectionProvider
        private let includesUnfilteredSummary: Bool
        private let refreshInterval: TimeInterval
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.apple-system-screen-time.dashboard",
            qos: .userInitiated
        )
        private var refreshTimer: Timer?
        private var deviceSourceLabels: [String: String] = [:]
        private var isActive = false
        private var lifecycleGeneration: UInt64 = 0

        init(
            rootDirectory: URL,
            deviceID: String,
            selectedDay: Date = Date(),
            accessEnabled: Bool = true,
            refreshInterval: TimeInterval = AppleScreenTimeDashboardModel.defaultRefreshInterval,
            includesUnfilteredSummary: Bool = false,
            collectionProvider: CollectionProvider? = nil
        ) {
            let source = AppleSystemScreenTimeSource(deviceID: deviceID)
            self.appleSource = source
            self.collectionProvider = collectionProvider ?? { source.collect(for: $0) }
            self.includesUnfilteredSummary = includesUnfilteredSummary
            self.refreshInterval = max(1, refreshInterval)
            self.accessEnabled = accessEnabled
            self.currentMacDevice = source.currentMacDevice
            self.selectedDay = Calendar.current.startOfDay(for: selectedDay)

            do {
                let store = try AppleScreenTimeStore(rootDirectory: rootDirectory)
                self.store = store
                var config = store.loadConfiguration()
                config.enabled = accessEnabled
                self.configuration = config
                try? store.saveConfiguration(config)
            } catch {
                self.store = nil
                self.configuration = AppleScreenTimeConfiguration(
                    enabled: accessEnabled,
                    scope: .allDevices,
                    shareLevel: .perDevice
                )
                self.alert = AppleScreenTimeDashboardAlert(
                    title: "Screen Time configuration could not start",
                    message: String(describing: error)
                )
            }
        }

        deinit {
            refreshTimer?.invalidate()
        }

        var currentMacDeviceID: String { currentMacDevice.id }
        var remoteDeviceCount: Int { availableDevices.filter { $0.id != currentMacDevice.id }.count }
        var hasRemoteDevices: Bool { remoteDeviceCount > 0 }
        var selectedDeviceIDs: Set<String> { Set(configuration.scope.selectedDeviceIDs) }
        var selectedDayIsToday: Bool { Calendar.current.isDateInToday(selectedDay) }
        var needsFullDiskAccess: Bool { status.kind == .fullDiskAccessRequired }

        var currentMacIsIncluded: Bool {
            switch configuration.scope.mode {
            case .allDevices, .macOnly:
                return true
            case .selectedDevices:
                return selectedDeviceIDs.contains(currentMacDevice.id)
            }
        }

        func sourceLabel(for device: AppleScreenTimeDevice) -> String {
            deviceSourceLabels[device.id]
                ?? (device.id == currentMacDevice.id ? "Apple system usage" : "Apple iCloud sync")
        }

        func selectDay(_ date: Date) {
            selectedDay = Calendar.current.startOfDay(for: date)
            refresh()
        }

        /// Apple system stores are comparatively expensive to enumerate. Keep their live
        /// refresh work strictly coupled to a dashboard page that is actually visible.
        func setActive(_ active: Bool) {
            guard active != isActive else { return }
            isActive = active
            lifecycleGeneration &+= 1
            if active, accessEnabled {
                refresh()
                startRefreshTimer()
            } else {
                stopRefreshTimer()
                isBusy = false
            }
        }

        func refresh() {
            guard accessEnabled else { return }
            guard isActive else { return }
            guard !isBusy else { return }
            isBusy = true
            let day = selectedDay
            let requestedScope = configuration.scope
            let source = appleSource
            let collectionProvider = collectionProvider
            let generation = lifecycleGeneration

            queue.async { [weak self] in
                let rawCollection = collectionProvider(day)
                let collection = AppleScreenTimeDeviceNormalizer.normalize(
                    rawCollection,
                    currentMac: source.currentMacDevice
                )
                let effectiveScope = requestedScope.normalized(
                    availableDevices: collection.availableDevices
                )
                let scoped = Self.scopedExport(
                    collection.storedExport,
                    scope: effectiveScope,
                    currentMacID: source.currentMacDevice.id
                )
                let interval = Calendar.current.dateInterval(of: .day, for: day)
                let nextSummary = interval.flatMap { interval in
                    scoped.flatMap {
                        AppleScreenTimeAnalyzer.summary(
                            from: $0,
                            interval: interval,
                            scope: effectiveScope
                        )
                    }
                }
                let nextUnfilteredSummary = self?.includesUnfilteredSummary == true
                    ? interval.flatMap { interval in
                        scoped.flatMap {
                            AppleScreenTimeAnalyzer.summary(
                                from: $0,
                                interval: interval,
                                scope: effectiveScope,
                                includingSystemInactivity: true
                            )
                        }
                    }
                    : nil

                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.isActive, self.lifecycleGeneration == generation else {
                        self.isBusy = false
                        return
                    }
                    guard self.selectedDay == day else {
                        self.isBusy = false
                        self.refresh()
                        return
                    }
                    guard self.configuration.scope == requestedScope else {
                        self.isBusy = false
                        self.refresh()
                        return
                    }

                    self.availableDevices = collection.availableDevices
                    self.deviceSourceLabels = collection.deviceSourceLabels
                    self.status = collection.status
                    self.summary = nextSummary
                    self.unfilteredSummary = nextUnfilteredSummary
                    self.latestAppleUpdate = collection.latestAppleUpdate
                    self.knowledgeIntervalCount = collection.knowledgeIntervalCount
                    self.biomeIntervalCount = collection.biomeIntervalCount
                    self.screenTimeAppUsageIntervalCount = collection.screenTimeAppUsageIntervalCount
                    self.lastRefreshAt = Date()
                    self.isBusy = false
                }
            }
        }

        func setAccessEnabled(_ enabled: Bool) {
            guard accessEnabled != enabled else { return }
            accessEnabled = enabled
            configuration.enabled = enabled
            try? store?.saveConfiguration(configuration)
            lifecycleGeneration &+= 1
            if enabled {
                if isActive {
                    refresh()
                    startRefreshTimer()
                }
            } else {
                stopRefreshTimer()
                isBusy = false
                summary = nil
                unfilteredSummary = nil
                availableDevices = []
                latestAppleUpdate = nil
                status = AppleSystemScreenTimeStatus(
                    kind: .noAppleData,
                    title: "Apple Screen Time is off",
                    message: "Enable this source before Goalong reads Apple’s protected local stores."
                )
            }
        }

        func setScopeMode(_ mode: AppleScreenTimeScopeMode) {
            switch mode {
            case .allDevices:
                configuration.scope = .allDevices
            case .macOnly:
                configuration.scope = .macOnly
            case .selectedDevices:
                let existing = configuration.scope.selectedDeviceIDs
                let initial = existing.isEmpty ? availableDevices.map(\.id) : existing
                configuration.scope = AppleScreenTimeScope(
                    mode: .selectedDevices,
                    selectedDeviceIDs: initial
                )
            }
            saveConfigurationAndRefresh()
        }

        func toggleDevice(_ device: AppleScreenTimeDevice) {
            var selected = selectedDeviceIDs
            if selected.contains(device.id) {
                selected.remove(device.id)
            } else {
                selected.insert(device.id)
            }
            configuration.scope = AppleScreenTimeScope(
                mode: .selectedDevices,
                selectedDeviceIDs: Array(selected)
            )
            saveConfigurationAndRefresh()
        }

        func setShareLevel(_ level: AppleScreenTimeShareLevel) {
            configuration.shareLevel = level
            saveConfigurationAndRefresh(refreshSummary: false)
        }

        func exportSharePayload() {
            guard let store, let summary else {
                alert = AppleScreenTimeDashboardAlert(
                    title: "Nothing to export",
                    message: "No Apple Screen Time data is available for the selected day and device scope."
                )
                return
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(Self.dayString(selectedDay)).apple-screen-time-share.json"
            guard panel.runModal() == .OK, let destination = panel.url else { return }

            isBusy = true
            let payload = Self.systemSharePayload(
                from: summary,
                disclosureLevel: configuration.shareLevel
            )
            queue.async { [weak self] in
                do {
                    try store.writeSharePayload(payload, to: destination)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isBusy = false
                        self.alert = AppleScreenTimeDashboardAlert(
                            title: "Apple Screen Time exported",
                            message:
                                "The file states the exact device scope, Apple data source, per-device totals and chosen application disclosure level."
                        )
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isBusy = false
                        self.alert = AppleScreenTimeDashboardAlert(
                            title: "Export failed",
                            message: String(describing: error)
                        )
                    }
                }
            }
        }

        func openFullDiskAccessSettings() {
            openSettings(candidates: [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            ])
        }

        func openScreenTimeSettings() {
            openSettings(candidates: [
                "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension",
                "x-apple.systempreferences:com.apple.preference.familysharing",
                "x-apple.systempreferences:",
            ])
        }

        func openConfigurationFolder() {
            guard let store else { return }
            GoalongWorkspaceOpenPolicy.open(store.rootDirectory, purpose: .localFile)
        }

        private func openSettings(candidates: [String]) {
            for candidate in candidates {
                if let url = URL(string: candidate),
                    GoalongWorkspaceOpenPolicy.open(url, purpose: .systemSettings)
                { return }
            }
        }

        private func startRefreshTimer() {
            stopRefreshTimer()
            guard isActive else { return }
            let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
                guard let self, self.isActive, self.selectedDayIsToday else { return }
                self.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }

        private func stopRefreshTimer() {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }

        var hasActiveRefreshTimerForTesting: Bool { refreshTimer != nil }

        private func saveConfigurationAndRefresh(refreshSummary: Bool = true) {
            guard let store else {
                if refreshSummary { refresh() }
                return
            }
            do {
                try store.saveConfiguration(configuration)
                if refreshSummary { refresh() }
            } catch {
                alert = AppleScreenTimeDashboardAlert(
                    title: "Screen Time settings could not be saved",
                    message: String(describing: error)
                )
            }
        }

        private static func systemSharePayload(
            from summary: AppleScreenTimeDaySummary,
            disclosureLevel: AppleScreenTimeShareLevel
        ) -> AppleScreenTimeSharePayload {
            let generated = AppleScreenTimeAnalyzer.sharePayload(
                from: summary,
                disclosureLevel: disclosureLevel
            )
            return AppleScreenTimeSharePayload(
                schemaVersion: generated.schemaVersion,
                createdAt: generated.createdAt,
                start: generated.start,
                end: generated.end,
                requestedScope: generated.requestedScope,
                includedDeviceCount: generated.includedDeviceCount,
                totalScreenOnDuration: generated.totalScreenOnDuration,
                aggregationMethod: generated.aggregationMethod,
                disclosureLevel: generated.disclosureLevel,
                devices: generated.devices,
                provenance: generated.provenance,
                importVerification: generated.importVerification,
                trustNotice:
                    "These values were read directly from Apple’s local knowledgeC and Biome stores. They were not generated by Goalong History or manually imported. Apple’s private on-disk formats are not cryptographically attested for third parties and may change in future OS releases."
            )
        }

        private static func scopedExport(
            _ stored: AppleScreenTimeStoredExport?,
            scope: AppleScreenTimeScope,
            currentMacID: String
        ) -> AppleScreenTimeStoredExport? {
            guard let stored else { return nil }
            let reports: [AppleScreenTimeDeviceReport]
            switch scope.mode {
            case .macOnly:
                reports = stored.envelope.reports.filter { $0.device.id == currentMacID }
            case .allDevices:
                reports = stored.envelope.reports
            case .selectedDevices:
                let selected = Set(scope.selectedDeviceIDs)
                reports = stored.envelope.reports.filter { selected.contains($0.device.id) }
            }
            guard !reports.isEmpty else { return nil }

            let envelope = AppleScreenTimeExportEnvelope(
                schemaVersion: stored.envelope.schemaVersion,
                createdAt: stored.envelope.createdAt,
                requestedStart: stored.envelope.requestedStart,
                requestedEnd: stored.envelope.requestedEnd,
                requestedScope: scope,
                provenance: stored.envelope.provenance,
                reports: reports
            )
            return AppleScreenTimeStoredExport(
                importedAt: stored.importedAt,
                verification: stored.verification,
                envelope: envelope
            )
        }

        private static func dayString(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }

    struct AppleScreenTimeDashboardAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
#endif
