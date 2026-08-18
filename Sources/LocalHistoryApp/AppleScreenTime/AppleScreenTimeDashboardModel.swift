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
        @Published var alert: AppleScreenTimeDashboardAlert?

        private let store: AppleScreenTimeStore?
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.apple-screen-time.dashboard",
            qos: .userInitiated
        )

        init(rootDirectory: URL, selectedDay: Date = Date()) {
            self.selectedDay = Calendar.current.startOfDay(for: selectedDay)
            do {
                let store = try AppleScreenTimeStore(rootDirectory: rootDirectory)
                self.store = store
                self.configuration = store.loadConfiguration()
            } catch {
                self.store = nil
                self.configuration = .default
                self.alert = AppleScreenTimeDashboardAlert(
                    title: "Apple Screen Time could not start",
                    message: String(describing: error)
                )
            }
            refresh()
        }

        var hasImports: Bool { importCount > 0 }

        var selectedDeviceIDs: Set<String> {
            Set(configuration.scope.selectedDeviceIDs)
        }

        func selectDay(_ date: Date) {
            selectedDay = Calendar.current.startOfDay(for: date)
            refresh()
        }

        func refresh() {
            guard let store, !isBusy else { return }
            isBusy = true
            let day = selectedDay
            let scope = configuration.scope

            queue.async { [weak self] in
                let exports = store.storedExports()
                let devices = Self.uniqueDevices(from: exports)
                let summary = store.summary(for: day, scope: scope)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.importCount = exports.count
                    self.availableDevices = devices
                    self.summary = summary
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

        func importExport() {
            guard let store else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = "Choose an Apple Screen Time export created by the Goalong collector."
            guard panel.runModal() == .OK, let source = panel.url else { return }

            isBusy = true
            queue.async { [weak self] in
                do {
                    let imported = try store.importExport(from: source)
                    var config = store.loadConfiguration()
                    config.enabled = true
                    if config.scope.mode == .selectedDevices,
                       config.scope.selectedDeviceIDs.isEmpty
                    {
                        config.scope = imported.envelope.requestedScope
                    }
                    try store.saveConfiguration(config)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.configuration = config
                        self.isBusy = false
                        self.alert = AppleScreenTimeDashboardAlert(
                            title: "Apple Screen Time imported",
                            message: Self.importMessage(for: imported)
                        )
                        self.refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isBusy = false
                        self.alert = AppleScreenTimeDashboardAlert(
                            title: "Import failed",
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
                    message: "Import Apple Screen Time data that covers the selected day first."
                )
                return
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(Self.dayString(selectedDay)).apple-screen-time-share.json"
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
                                "The file states its exact device scope, disclosure level, aggregation method, and import-verification status."
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
                            title: "Apple Screen Time data deleted",
                            message: "Deleted \(count) imported file\(count == 1 ? "" : "s")."
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

        private func saveConfigurationAndRefresh(refreshSummary: Bool = true) {
            guard let store else { return }
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

        private static func uniqueDevices(
            from exports: [AppleScreenTimeStoredExport]
        ) -> [AppleScreenTimeDevice] {
            var byID: [String: AppleScreenTimeDevice] = [:]
            for stored in exports {
                for report in stored.envelope.reports where byID[report.device.id] == nil {
                    byID[report.device.id] = report.device
                }
            }
            return byID.values.sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        private static func importMessage(for stored: AppleScreenTimeStoredExport) -> String {
            let deviceCount = stored.envelope.reports.count
            switch stored.verification {
            case .unsigned:
                return "Imported \(deviceCount) device report\(deviceCount == 1 ? "" : "s"). This JSON is unsigned, so LocalHistory clearly marks it as unverified rather than treating it like sealed recorder evidence."
            case .signaturePresentUnverified:
                return "Imported \(deviceCount) device report\(deviceCount == 1 ? "" : "s"). A signature is present, but this build has not verified it against an official collector key."
            case .verifiedOfficialCollector:
                return "Imported and verified \(deviceCount) device report\(deviceCount == 1 ? "" : "s") from an official collector."
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
