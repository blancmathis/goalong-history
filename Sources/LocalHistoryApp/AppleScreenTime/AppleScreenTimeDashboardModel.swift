#if os(macOS)
    import AppKit
    import AppleScreenTime
    import Combine
    import Foundation
    import UniformTypeIdentifiers

    final class AppleScreenTimeDashboardModel: ObservableObject {
        @Published var selectedDay: Date
        @Published var configuration: AppleScreenTimeConfiguration
        @Published private(set) var summary: AppleScreenTimeDaySummary?
        @Published private(set) var availableDevices: [AppleScreenTimeDevice] = []
        @Published private(set) var isBusy = false
        @Published private(set) var lastRefreshAt: Date?
        @Published private(set) var latestAppleUpdate: Date?
        @Published private(set) var status: AppleSystemScreenTimeStatus = .loading
        @Published private(set) var knowledgeIntervalCount = 0
        @Published private(set) var biomeIntervalCount = 0
        @Published var alert: AppleScreenTimeDashboardAlert?

        let currentMacDevice: AppleScreenTimeDevice

        private let store: AppleScreenTimeStore?
        private let appleSource: AppleSystemScreenTimeSource
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.apple-system-screen-time.dashboard",
            qos: .userInitiated
        )
        private var refreshTimer: Timer?
        private var deviceSourceLabels: [String: String] = [:]

        init(rootDirectory: URL, deviceID: String, selectedDay: Date = Date()) {
            let source = AppleSystemScreenTimeSource(deviceID: deviceID)
            self.appleSource = source
            self.currentMacDevice = source.currentMacDevice
            self.selectedDay = Calendar.current.startOfDay(for: selectedDay)

            do {
                let store = try AppleScreenTimeStore(rootDirectory: rootDirectory)
                self.store = store
                var config = store.loadConfiguration()
                config.enabled = true
                self.configuration = config
                try? store.saveConfiguration(config)
            } catch {
                self.store = nil
                self.configuration = AppleScreenTimeConfiguration(
                    enabled: true,
                    scope: .allDevices,
                    shareLevel: .perDevice
                )
                self.alert = AppleScreenTimeDashboardAlert(
                    title: "Screen Time configuration could not start",
                    message: String(describing: error)
                )
            }

            refresh()
            startRefreshTimer()
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

        func refresh() {
            guard !isBusy else { return }
            isBusy = true
            let day = selectedDay
            let requestedScope = configuration.scope
            let source = appleSource

            queue.async { [weak self] in
                let rawCollection = source.collect(for: day)
                let collection = AppleScreenTimeDeviceNormalizer.normalize(
                    rawCollection,
                    currentMac: source.currentMacDevice
                )
                let normalizedScope = requestedScope.normalized(
                    availableDevices: collection.availableDevices
                )
                let scoped = Self.scopedExport(
                    collection.storedExport,
                    scope: normalizedScope,
                    currentMacID: source.currentMacDevice.id
                )
                let interval = Calendar.current.dateInterval(of: .day, for: day)
                let nextSummary = interval.flatMap { interval in
                    scoped.flatMap {
                        AppleScreenTimeAnalyzer.summary(
                            from: $0,
                            interval: interval,
                            scope: normalizedScope
                        )
                    }
                }

                DispatchQueue.main.async {
                    guard let self else { return }
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
                    self.latestAppleUpdate = collection.latestAppleUpdate
                    self.knowledgeIntervalCount = collection.knowledgeIntervalCount
                    self.biomeIntervalCount = collection.biomeIntervalCount
                    self.lastRefreshAt = Date()
                    self.isBusy = false

                    if normalizedScope != requestedScope {
                        self.configuration.scope = normalizedScope
                        if let store = self.store {
                            try? store.saveConfiguration(self.configuration)
                        }
                    }
                }
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
            NSWorkspace.shared.open(store.rootDirectory)
        }

        private func openSettings(candidates: [String]) {
            for candidate in candidates {
                if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
            }
        }

        private func startRefreshTimer() {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                guard let self, self.selectedDayIsToday else { return }
                self.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }

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
