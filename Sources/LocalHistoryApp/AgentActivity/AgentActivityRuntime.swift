#if os(macOS)
    import AgentActivity
    import AppKit
    import Combine
    import Foundation

    struct AgentActivityAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    final class AgentActivityRuntime: ObservableObject {
        @Published private(set) var configuration: AgentActivityConfiguration
        @Published private(set) var overview: AgentActivityOverview
        @Published private(set) var latestRecords: [AgentCaptureRecord]
        @Published private(set) var integrationStatuses: [AgentIntegrationStatus]
        @Published private(set) var isScanning = false
        @Published private(set) var lastScanResult = AgentScanResult()
        @Published private(set) var storageBytes: Int64 = 0
        @Published private(set) var chainIsValid: Bool
        @Published var selectedDay: Date
        @Published var alert: AgentActivityAlert?

        let rootDirectory: URL

        private let store: AgentActivityStore
        private let scanner: AgentActivityScanner
        private let installer: AgentIntegrationInstaller
        private let workQueue = DispatchQueue(
            label: "ai.goalong.localhistory.agent-activity",
            qos: .utility
        )
        private let onCaptured: ([AgentCaptureRecord]) -> Void
        private var scanTimer: DispatchSourceTimer?
        private var scanInProgress = false
        private var started = false
        private let snapshotLock = NSLock()
        private var scanConfiguration: AgentActivityConfiguration
        private var scanSelectedDay: Date

        init(
            rootDirectory: URL,
            executableURL: URL,
            onCaptured: @escaping ([AgentCaptureRecord]) -> Void
        ) throws {
            self.rootDirectory = rootDirectory
            self.onCaptured = onCaptured
            store = try AgentActivityStore(rootDirectory: rootDirectory)
            scanner = AgentActivityScanner(store: store)
            installer = AgentIntegrationInstaller(executableURL: executableURL)

            let discovered = AgentDefaultSourceDiscovery.discover()
            let managed = AgentDefaultSourceDiscovery.managedHookFolders(rootDirectory: rootDirectory)
            let merged = AgentDefaultSourceDiscovery.merging(
                configuration: store.loadConfiguration(),
                discovered: discovered,
                managed: managed
            )
            let initialConfiguration = (try? store.saveConfiguration(merged)) ?? merged
            let initialDay = Calendar.current.startOfDay(for: Date())
            configuration = initialConfiguration
            scanConfiguration = initialConfiguration
            selectedDay = initialDay
            scanSelectedDay = initialDay
            overview = store.overview(for: initialDay)
            latestRecords = store.latestRecords()
            integrationStatuses = AgentIntegrationKind.allCases.map(installer.status)
            storageBytes = store.storageBytes()
            chainIsValid = store.manifestChainIsValid()
        }

        deinit {
            scanTimer?.cancel()
        }

        var userWatchedFolders: [AgentWatchedFolder] {
            configuration.watchedFolders.filter { !$0.isManaged }
        }

        var managedHookFolders: [AgentWatchedFolder] {
            configuration.watchedFolders.filter(\.isManaged)
        }

        func start() {
            guard !started else { return }
            started = true
            scanNow()
            scheduleTimer()
        }

        func stop() {
            scanTimer?.cancel()
            scanTimer = nil
            started = false
            // Wait for an in-flight scan so no capture is committed after EventRecorder closes.
            workQueue.sync {}
        }

        func scanNow() {
            workQueue.async { [weak self] in
                self?.performScan()
            }
        }

        func selectDay(_ date: Date) {
            let normalized = Calendar.current.startOfDay(for: date)
            guard normalized != selectedDay else { return }
            selectedDay = normalized
            updateScanSnapshot(day: normalized)
            refreshPublishedData()
        }

        func detectCommonSources() {
            let merged = AgentDefaultSourceDiscovery.merging(
                configuration: configuration,
                discovered: AgentDefaultSourceDiscovery.discover(),
                managed: AgentDefaultSourceDiscovery.managedHookFolders(rootDirectory: rootDirectory)
            )
            save(merged, successMessage: "Available local agent sources were added.")
        }

        func chooseFolder() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.canCreateDirectories = false
            panel.message = "Choose folders containing agent transcripts, sessions, logs or project artifacts."
            panel.prompt = "Watch folders"
            guard panel.runModal() == .OK else { return }
            addFolders(panel.urls)
        }

        func addFolder(
            _ url: URL,
            provider: AgentProvider? = nil,
            captureMode: AgentCaptureMode = .transcriptsAndLogs
        ) {
            addFolders([url], provider: provider, captureMode: captureMode)
        }

        private func addFolders(
            _ urls: [URL],
            provider: AgentProvider? = nil,
            captureMode: AgentCaptureMode = .transcriptsAndLogs
        ) {
            var next = configuration
            var knownPaths = Set(
                next.watchedFolders.map {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path.lowercased()
                }
            )
            var addedCount = 0

            for url in urls {
                let standardized = url.standardizedFileURL.path
                let key = standardized.lowercased()
                guard knownPaths.insert(key).inserted else { continue }
                let inferred = provider ?? Self.inferredProvider(from: standardized)
                next.watchedFolders.append(
                    AgentWatchedFolder(
                        displayName: url.lastPathComponent.isEmpty ? inferred.displayName : url.lastPathComponent,
                        path: standardized,
                        provider: inferred,
                        captureMode: captureMode
                    )
                )
                addedCount += 1
            }

            guard addedCount > 0 else {
                alert = AgentActivityAlert(
                    title: "Folder already monitored",
                    message: urls.count == 1
                        ? urls[0].standardizedFileURL.path
                        : "Every selected folder is already monitored."
                )
                return
            }

            let message =
                addedCount == 1
                ? "The folder is now monitored locally."
                : "\(addedCount) folders are now monitored locally."
            save(next, successMessage: message)
        }

        func removeFolder(id: String) {
            guard let folder = configuration.watchedFolders.first(where: { $0.id == id }), !folder.isManaged else {
                return
            }
            var next = configuration
            next.watchedFolders.removeAll { $0.id == id }
            save(next, successMessage: nil)
        }

        func setFolderEnabled(_ enabled: Bool, id: String) {
            updateFolder(id: id) { $0.isEnabled = enabled }
        }

        func setProvider(_ provider: AgentProvider, id: String) {
            updateFolder(id: id) { $0.provider = provider }
        }

        func setCaptureMode(_ mode: AgentCaptureMode, id: String) {
            updateFolder(id: id) { $0.captureMode = mode }
        }

        func setIncludeSubdirectories(_ enabled: Bool, id: String) {
            updateFolder(id: id) { $0.includeSubdirectories = enabled }
        }

        func renameFolder(_ name: String, id: String) {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            updateFolder(id: id) { $0.displayName = clean }
        }

        func applyFolder(_ folder: AgentWatchedFolder) {
            guard !folder.isManaged else { return }
            var next = configuration
            guard let index = next.watchedFolders.firstIndex(where: { $0.id == folder.id }) else { return }
            var normalized = folder
            normalized.displayName = normalized.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.displayName.isEmpty { normalized.displayName = normalized.url.lastPathComponent }
            next.watchedFolders[index] = normalized
            save(next, successMessage: nil)
        }

        func installIntegration(_ kind: AgentIntegrationKind) {
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.installer.install(kind)
                    let statuses = AgentIntegrationKind.allCases.map(self.installer.status)
                    DispatchQueue.main.async {
                        self.integrationStatuses = statuses
                        self.alert = AgentActivityAlert(
                            title: "\(kind.displayName) installed",
                            message: kind == .codexHooks
                                ? "New events are written directly to the local Goalong agent vault. Restart Codex, then approve the Goalong hook from Codex’s /hooks interface if it asks for trust."
                                : "New events are written directly to the local Goalong agent vault. Restart the agent application if it is already open."
                        )
                    }
                } catch {
                    self.publish(error: error, title: "Integration could not be installed")
                }
            }
        }

        func uninstallIntegration(_ kind: AgentIntegrationKind) {
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.installer.uninstall(kind)
                    let statuses = AgentIntegrationKind.allCases.map(self.installer.status)
                    DispatchQueue.main.async {
                        self.integrationStatuses = statuses
                        self.alert = AgentActivityAlert(
                            title: "\(kind.displayName) removed",
                            message: "Previously captured local history remains in the vault."
                        )
                    }
                } catch {
                    self.publish(error: error, title: "Integration could not be removed")
                }
            }
        }

        func status(for kind: AgentIntegrationKind) -> AgentIntegrationStatus {
            integrationStatuses.first(where: { $0.kind == kind })
                ?? AgentIntegrationStatus(
                    kind: kind,
                    isInstalled: false,
                    configurationPath: installer.configurationURL(for: kind).path
                )
        }

        func openRootFolder() {
            NSWorkspace.shared.open(rootDirectory)
        }

        func openHookInbox() {
            NSWorkspace.shared.open(store.hookInboxDirectory)
        }

        func openFolder(_ folder: AgentWatchedFolder) {
            NSWorkspace.shared.open(folder.url)
        }

        func openOriginal(_ record: AgentCaptureRecord) {
            let url = URL(fileURLWithPath: record.sourcePath)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                alert = AgentActivityAlert(
                    title: "Original file is no longer present",
                    message: "The immutable Goalong copy is still available."
                )
            }
        }

        func openCapturedCopy(_ record: AgentCaptureRecord) {
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let url = try self.store.materialize(captureID: record.id)
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    self.publish(error: error, title: "Captured copy could not be reconstructed")
                }
            }
        }

        func verify(_ record: AgentCaptureRecord) {
            workQueue.async { [weak self] in
                guard let self else { return }
                let valid = self.store.verifies(captureID: record.id)
                DispatchQueue.main.async {
                    self.alert = AgentActivityAlert(
                        title: valid ? "Capture verified" : "Capture verification failed",
                        message: valid
                            ? "The reconstructed local bytes match SHA-256 \(record.sha256)."
                            : "The local blob or delta chain no longer matches the sealed capture record."
                    )
                }
            }
        }

        private func updateFolder(id: String, mutation: (inout AgentWatchedFolder) -> Void) {
            var next = configuration
            guard let index = next.watchedFolders.firstIndex(where: { $0.id == id }) else { return }
            mutation(&next.watchedFolders[index])
            save(next, successMessage: nil)
        }

        private func save(_ configuration: AgentActivityConfiguration, successMessage: String?) {
            do {
                let saved = try store.saveConfiguration(configuration)
                self.configuration = saved
                updateScanSnapshot(configuration: saved)
                if let successMessage {
                    alert = AgentActivityAlert(title: "Agent monitoring updated", message: successMessage)
                }
                rescheduleTimer()
                scanNow()
            } catch {
                alert = AgentActivityAlert(
                    title: "Agent monitoring settings could not be saved",
                    message: error.localizedDescription
                )
            }
        }

        private func performScan() {
            guard !scanInProgress else { return }
            scanInProgress = true
            DispatchQueue.main.async { [weak self] in self?.isScanning = true }
            let snapshot = currentScanSnapshot()
            let result = scanner.scan(configuration: snapshot.configuration)
            if !result.captures.isEmpty { onCaptured(result.captures) }
            let selected = snapshot.day
            let nextOverview = store.overview(for: selected)
            let latest = store.latestRecords()
            let bytes = store.storageBytes()
            let chainValid = store.manifestChainIsValid()
            scanInProgress = false

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastScanResult = result
                if self.selectedDay == selected {
                    self.overview = nextOverview
                }
                self.latestRecords = latest
                self.storageBytes = bytes
                self.chainIsValid = chainValid
                self.isScanning = false
                if let first = result.failures.first {
                    self.alert = AgentActivityAlert(
                        title: "Some agent files could not be read",
                        message: result.failures.count == 1
                            ? first
                            : "\(first)\n\nAnd \(result.failures.count - 1) other read error(s)."
                    )
                }
            }
        }

        private func refreshPublishedData() {
            let selected = selectedDay
            workQueue.async { [weak self] in
                guard let self else { return }
                let next = self.store.overview(for: selected)
                let latest = self.store.latestRecords()
                let bytes = self.store.storageBytes()
                let chainValid = self.store.manifestChainIsValid()
                DispatchQueue.main.async {
                    guard self.selectedDay == selected else { return }
                    self.overview = next
                    self.latestRecords = latest
                    self.storageBytes = bytes
                    self.chainIsValid = chainValid
                }
            }
        }

        private func scheduleTimer() {
            let interval = currentScanConfiguration().scanIntervalSeconds
            let timer = DispatchSource.makeTimerSource(queue: workQueue)
            timer.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(500)
            )
            timer.setEventHandler { [weak self] in self?.performScan() }
            timer.resume()
            scanTimer = timer
        }

        private func rescheduleTimer() {
            guard started else { return }
            scanTimer?.cancel()
            scanTimer = nil
            scheduleTimer()
        }

        private func currentScanConfiguration() -> AgentActivityConfiguration {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            return scanConfiguration
        }

        private func currentScanSnapshot() -> (configuration: AgentActivityConfiguration, day: Date) {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            return (scanConfiguration, scanSelectedDay)
        }

        private func updateScanSnapshot(
            configuration: AgentActivityConfiguration? = nil,
            day: Date? = nil
        ) {
            snapshotLock.lock()
            if let configuration { scanConfiguration = configuration }
            if let day { scanSelectedDay = day }
            snapshotLock.unlock()
        }

        private func publish(error: Error, title: String) {
            DispatchQueue.main.async { [weak self] in
                self?.alert = AgentActivityAlert(title: title, message: error.localizedDescription)
            }
        }

        private static func inferredProvider(from path: String) -> AgentProvider {
            let lower = path.lowercased()
            if lower.contains("codex") { return .codex }
            if lower.contains("claude") { return .claudeCode }
            if lower.contains("cursor") { return .cursor }
            if lower.contains("opencode") { return .openCode }
            return .custom
        }
    }
#endif
