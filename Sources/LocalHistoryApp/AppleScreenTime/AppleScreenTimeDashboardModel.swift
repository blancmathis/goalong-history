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
        @Published private(set) var importCount = 0
        @Published private(set) var isBusy = false
        @Published private(set) var lastRefreshAt: Date?
        @Published private(set) var remoteDeviceCount = 0
        @Published var alert: AppleScreenTimeDashboardAlert?

        let currentMacDevice: AppleScreenTimeDevice

        private let store: AppleScreenTimeStore?
        private let liveMacSource: LiveMacScreenTimeSource
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.apple-screen-time.dashboard",
            qos: .userInitiated
        )
        private var refreshTimer: Timer?

        init(rootDirectory: URL, deviceID: String, selectedDay: Date = Date()) {
            let liveSource = LiveMacScreenTimeSource(deviceID: deviceID)
            self.liveMacSource = liveSource
            self.currentMacDevice = liveSource.device
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
                    scope: .macOnly,
                    shareLevel: .perDevice
                )
                self.alert = AppleScreenTimeDashboardAlert(
                    title: "Screen Time storage could not start",
                    message: String(describing: error)
                )
            }

            refresh()
            startLiveRefreshTimer()
        }

        deinit {
            refreshTimer?.invalidate()
        }

        var hasImports: Bool { importCount > 0 }
        var hasRemoteDevices: Bool { remoteDeviceCount > 0 }
        var currentMacDeviceID: String { currentMacDevice.id }

        var selectedDeviceIDs: Set<String> {
            Set(configuration.scope.selectedDeviceIDs)
        }

        var selectedDayIsToday: Bool {
            Calendar.current.isDateInToday(selectedDay)
        }

        var currentMacIsIncluded: Bool {
            switch configuration.scope.mode {
            case .allDevices, .macOnly:
                return true
            case .selectedDevices:
                return selectedDeviceIDs.contains(currentMacDevice.id)
            }
        }

        func selectDay(_ date: Date) {
            selectedDay = Calendar.current.startOfDay(for: date)
            refresh()
        }

        func refresh() {
            guard !isBusy else { return }
            isBusy = true
            let day = selectedDay
            let scope = configuration.scope
            let store = self.store
            let liveMacSource = self.liveMacSource

            queue.async { [weak self] in
                let imports = store?.storedExports() ?? []
                let local = liveMacSource.storedExport(for: day)
                let devices = Self.uniqueDevices(
                    localDevice: liveMacSource.device,
                    from: imports
                )
                let remoteReports = Self.latestRemoteReports(
                    for: day,
                    imports: imports,
                    excludingLocalDevice: liveMacSource.device
                )
                let merged = Self.combinedExport(
                    for: day,
                    scope: scope,
                    local: local,
                    remoteReports: remoteReports
                )
                let interval = Calendar.current.dateInterval(of: .day, for: day)
                let nextSummary = interval.flatMap { interval in
                    merged.flatMap {
                        AppleScreenTimeAnalyzer.summary(
                            from: $0,
                            interval: interval,
                            scope: scope
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
                    self.importCount = imports.count
                    self.availableDevices = devices
                    self.remoteDeviceCount = max(0, devices.count - 1)
                    self.summary = nextSummary
                    self.lastRefreshAt = Date()
                    self.isBusy = false
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

        /// Compatibility path for companion snapshots. The Mac itself never needs an import:
        /// its usage is reconstructed continuously from the live LocalHistory recorder.
        func importExport() {
            guard let store else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = "Choose a Screen Time companion snapshot for another Apple device."
            guard panel.runModal() == .OK, let source = panel.url else { return }

            isBusy = true
            queue.async { [weak self] in
                do {
                    let imported = try store.importExport(from: source)
                    var config = store.loadConfiguration()
                    config.enabled = true
                    try store.saveConfiguration(config)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.configuration = config
                        self.isBusy = false
                        self.alert = AppleScreenTimeDashboardAlert(
                            title: "Device snapshot connected",
                            message: Self.importMessage(for: imported)
                        )
                        self.refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isBusy = false
                        self.alert = AppleScreenTimeDashboardAlert(
                            title: "Connection failed",
                            message: String(describing: error)
                        )
                    }
                }
            }
        }

        func exportSharePayload() {
            guard let store, let summary else {
                alert = AppleScreenTimeDashboardAlert(
                    title: "Nothing to export",
                    message: "No Screen Time data is available for the selected day and device scope."
                )
                return
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(Self.dayString(selectedDay)).screen-time-share.json"
            guard panel.runModal() == .OK, let destination = panel.url else { return }

            isBusy = true
            let payload = AppleScreenTimeAnalyzer.sharePayload(
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
                            title: "Screen Time share exported",
                            message:
                                "The file includes the selected device scope, per-device totals and the chosen application disclosure level."
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

        func deleteAllImports() {
            guard let store, !isBusy else { return }
            isBusy = true
            queue.async { [weak self] in
                do {
                    let count = try store.deleteAllImports()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isBusy = false
                        self.alert = AppleScreenTimeDashboardAlert(
                            title: "Connected-device snapshots deleted",
                            message:
                                "Deleted \(count) snapshot\(count == 1 ? "" : "s"). Live Screen Time for this Mac is unaffected."
                        )
                        self.refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isBusy = false
                        self.alert = AppleScreenTimeDashboardAlert(
                            title: "Deletion failed",
                            message: String(describing: error)
                        )
                    }
                }
            }
        }

        func openDataFolder() {
            guard let store else { return }
            NSWorkspace.shared.open(store.rootDirectory)
        }

        private func startLiveRefreshTimer() {
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

        private static func combinedExport(
            for day: Date,
            scope: AppleScreenTimeScope,
            local: AppleScreenTimeStoredExport?,
            remoteReports: [AppleScreenTimeDeviceReport]
        ) -> AppleScreenTimeStoredExport? {
            guard let interval = Calendar.current.dateInterval(of: .day, for: day) else { return nil }
            let localReports = local?.envelope.reports ?? []
            let reports: [AppleScreenTimeDeviceReport]

            switch scope.mode {
            case .macOnly:
                // "Mac only" means this running Mac, not every Mac present in a synced account.
                reports = localReports
            case .allDevices, .selectedDevices:
                reports = localReports + remoteReports
            }

            guard !reports.isEmpty else { return nil }
            let provenance: AppleScreenTimeProvenance
            if remoteReports.isEmpty, let localProvenance = local?.envelope.provenance {
                provenance = localProvenance
            } else {
                let info = Bundle.main.infoDictionary
                provenance = AppleScreenTimeProvenance(
                    api: "LocalHistory live Mac recorder plus connected Apple device snapshots",
                    collectorBundleIdentifier: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                    collectorVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                    collectorPlatform: ProcessInfo.processInfo.operatingSystemVersionString,
                    authorization: .unknown,
                    fetchPolicy: .live,
                    euCustomerRequirementAcknowledged: false
                )
            }

            let envelope = AppleScreenTimeExportEnvelope(
                requestedStart: interval.start,
                requestedEnd: interval.end,
                requestedScope: scope,
                provenance: provenance,
                reports: reports
            )
            return AppleScreenTimeStoredExport(
                importedAt: Date(),
                verification: .unsigned,
                envelope: envelope
            )
        }

        private static func latestRemoteReports(
            for day: Date,
            imports: [AppleScreenTimeStoredExport],
            excludingLocalDevice local: AppleScreenTimeDevice
        ) -> [AppleScreenTimeDeviceReport] {
            guard let interval = Calendar.current.dateInterval(of: .day, for: day) else { return [] }
            var selected: [String: AppleScreenTimeDeviceReport] = [:]

            for stored in imports {
                let exportInterval = DateInterval(
                    start: stored.envelope.requestedStart,
                    end: stored.envelope.requestedEnd
                )
                guard exportInterval.intersects(interval) else { continue }

                for report in stored.envelope.reports {
                    guard !isSamePhysicalMac(report.device, local) else { continue }
                    guard report.segments.contains(where: { $0.interval.intersects(interval) }) else { continue }
                    if let previous = selected[report.device.id],
                       previous.lastUpdatedAt >= report.lastUpdatedAt
                    {
                        continue
                    }
                    selected[report.device.id] = report
                }
            }

            return selected.values.sorted {
                if $0.device.kind.rawValue != $1.device.kind.rawValue {
                    return $0.device.kind.rawValue < $1.device.kind.rawValue
                }
                return $0.device.displayName.localizedCaseInsensitiveCompare($1.device.displayName) == .orderedAscending
            }
        }

        private static func uniqueDevices(
            localDevice: AppleScreenTimeDevice,
            from exports: [AppleScreenTimeStoredExport]
        ) -> [AppleScreenTimeDevice] {
            var byID: [String: AppleScreenTimeDevice] = [localDevice.id: localDevice]
            for stored in exports {
                for report in stored.envelope.reports {
                    guard !isSamePhysicalMac(report.device, localDevice) else { continue }
                    byID[report.device.id] = report.device
                }
            }
            return byID.values.sorted {
                if $0.id == localDevice.id { return true }
                if $1.id == localDevice.id { return false }
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        private static func isSamePhysicalMac(
            _ candidate: AppleScreenTimeDevice,
            _ local: AppleScreenTimeDevice
        ) -> Bool {
            if candidate.id == local.id { return true }
            guard candidate.kind == .mac else { return false }
            return normalizedDeviceName(candidate.displayName) == normalizedDeviceName(local.displayName)
        }

        private static func normalizedDeviceName(_ value: String) -> String {
            value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func importMessage(for stored: AppleScreenTimeStoredExport) -> String {
            let deviceCount = stored.envelope.reports.count
            switch stored.verification {
            case .unsigned:
                return "Connected \(deviceCount) device snapshot\(deviceCount == 1 ? "" : "s"). The Mac continues updating automatically; this compatibility snapshot is marked unverified."
            case .signaturePresentUnverified:
                return "Connected \(deviceCount) device snapshot\(deviceCount == 1 ? "" : "s"). A signature is present but has not yet been verified against an official companion key."
            case .verifiedOfficialCollector:
                return "Connected and verified \(deviceCount) device report\(deviceCount == 1 ? "" : "s") from an official companion."
            }
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
