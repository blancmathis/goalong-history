#if os(macOS)
    import AgentActivity
    import AppKit
    import Combine
    import Darwin
    import Foundation

    struct AgentActivityAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum AgentActivityRuntimeAccessError: LocalizedError {
        case unauthorizedSource(String)

        var errorDescription: String? {
            switch self {
            case .unauthorizedSource(let entryID):
                return "The indexed source \(entryID) is not authorized by an active monitored folder."
            }
        }
    }

    final class AgentActivityRuntime: ObservableObject {
        @Published private(set) var configuration: AgentActivityConfiguration
        @Published private(set) var overview: AgentActivityOverview
        @Published private(set) var integrationStatuses: [AgentIntegrationStatus]
        @Published private(set) var isScanning = false
        @Published private(set) var lastScanResult = AgentScanResult()
        @Published private(set) var storageBytes: Int64 = 0
        @Published private(set) var indexIsValid: Bool
        @Published var selectedDay: Date
        @Published var alert: AgentActivityAlert?

        let rootDirectory: URL

        private let store: AgentActivityStore
        private let scanner: AgentActivityScanner
        private let installer: AgentIntegrationInstaller
        private let sourceDiscovery: () -> [AgentWatchedFolder]
        private let workQueue = DispatchQueue(
            label: "ai.goalong.localhistory.agent-activity",
            qos: .utility
        )
        private let workQueueSpecificKey = DispatchSpecificKey<UInt8>()
        private let onCaptured: ([AgentCaptureRecord]) -> Void
        private var scanTimer: DispatchSourceTimer?
        private var signalWatcher: DispatchSourceFileSystemObject?
        private var started = false
        private let snapshotLock = NSLock()
        private var scanConfiguration: AgentActivityConfiguration
        private var scanSelectedDay: Date
        private var scanSelectedDayRequiresAnalysis = false
        private var scanDashboardIsVisible = false
        private let derivedStateRefreshLock = NSLock()
        private var derivedStateRefreshCount = 0
        private let scanStateLock = NSLock()
        private var scanWorkScheduledOrRunning = false
        private var scanCatchUpRequested = false
        private var pendingForceFullDiscovery = false
        private var pendingTransientAnalysisClear = false
        private var pendingSelectedDayAnalysis = false
        private var scanGeneration: UInt64 = 0
        private var isStopping = false
        private var initialDiscoveryPerformed: Bool

        private struct ScanRequest {
            let forceFullDiscovery: Bool
            let clearTransientAnalyses: Bool
            let analyzeSelectedDay: Bool
        }

        init(
            rootDirectory: URL,
            executableURL: URL,
            performInitialDiscovery: Bool = true,
            sourceDiscovery: @escaping () -> [AgentWatchedFolder] = {
                AgentDefaultSourceDiscovery.discover()
            },
            onCaptured: @escaping ([AgentCaptureRecord]) -> Void
        ) throws {
            self.rootDirectory = rootDirectory
            self.onCaptured = onCaptured
            self.sourceDiscovery = sourceDiscovery
            store = try AgentActivityStore(rootDirectory: rootDirectory)
            scanner = AgentActivityScanner(store: store)
            installer = AgentIntegrationInstaller(executableURL: executableURL)
            initialDiscoveryPerformed = performInitialDiscovery

            let storedConfiguration = store.loadConfiguration()
            let merged = performInitialDiscovery
                ? AgentDefaultSourceDiscovery.merging(
                    configuration: storedConfiguration,
                    discovered: sourceDiscovery()
                )
                : storedConfiguration
            let initialConfiguration = (try? store.saveConfiguration(merged)) ?? merged
            let initialDay = Calendar.current.startOfDay(for: Date())
            configuration = initialConfiguration
            scanConfiguration = initialConfiguration
            selectedDay = initialDay
            scanSelectedDay = initialDay
            overview = store.overview(for: initialDay)
            integrationStatuses = AgentIntegrationKind.allCases.map(installer.status)
            storageBytes = store.storageBytes()
            indexIsValid = store.indexIsValid(maximumEntries: initialConfiguration.maximumIndexEntries)
            workQueue.setSpecific(key: workQueueSpecificKey, value: 1)
        }

        deinit {
            scanTimer?.cancel()
            signalWatcher?.cancel()
        }

        var userWatchedFolders: [AgentWatchedFolder] {
            configuration.watchedFolders.filter { !$0.isManaged }
        }

        func start() {
            guard !started else { return }
            if !initialDiscoveryPerformed {
                let merged = AgentDefaultSourceDiscovery.merging(
                    configuration: store.loadConfiguration(),
                    discovered: sourceDiscovery()
                )
                let applied = (try? store.saveConfiguration(merged)) ?? merged
                configuration = applied
                updateScanSnapshot(configuration: applied)
                initialDiscoveryPerformed = true
            }
            started = true
            scanStateLock.lock()
            isStopping = false
            scanStateLock.unlock()
            scanner.resetCancellation()
            scanNow(
                forceFullDiscovery: false,
                analyzeSelectedDay: currentScanSnapshot().selectedDayRequiresAnalysis
            )
            scheduleSignalWatcher()
            scheduleTimer()
        }

        func stop() {
            scanStateLock.lock()
            isStopping = true
            scanCatchUpRequested = false
            pendingForceFullDiscovery = false
            pendingTransientAnalysisClear = false
            pendingSelectedDayAnalysis = false
            scanStateLock.unlock()
            scanTimer?.cancel()
            scanTimer = nil
            signalWatcher?.cancel()
            signalWatcher = nil
            started = false
            scanner.cancelCurrentScan()
            // Wait for an in-flight scan so no capture is committed after EventRecorder closes.
            if DispatchQueue.getSpecific(key: workQueueSpecificKey) == nil {
                workQueue.sync {}
            }
        }

        func scanNow(
            forceFullDiscovery: Bool = false,
            analyzeSelectedDay: Bool = false
        ) {
            guard started else { return }
            enqueueScan(
                forceFullDiscovery: forceFullDiscovery,
                clearTransientAnalyses: false,
                analyzeSelectedDay: analyzeSelectedDay
            )
        }

        func selectDay(_ date: Date) {
            let normalized = Calendar.current.startOfDay(for: date)
            guard normalized != selectedDay else { return }
            selectedDay = normalized
            // Never show the previous day's rows under the new date while the direct-source
            // projection is being rebuilt. The complete snapshot is published atomically below.
            overview = AgentActivityOverview(day: normalized)
            updateScanSnapshot(day: normalized, selectedDayRequiresAnalysis: true)
            if started {
                enqueueScan(
                    forceFullDiscovery: false,
                    clearTransientAnalyses: true,
                    analyzeSelectedDay: true
                )
            }
        }

        func dashboardDidBecomeHidden() {
            updateScanSnapshot(dashboardIsVisible: false)
            store.discardTransientSummaries()
            overview = store.overview(for: selectedDay)
        }

        func dashboardDidBecomeVisible() {
            updateScanSnapshot(dashboardIsVisible: true)
        }

        func detectCommonSources() {
            guard started else { return }
            let discovered = sourceDiscovery()
            let merged = AgentDefaultSourceDiscovery.merging(
                configuration: configuration,
                discovered: discovered,
                reallowSuppressedSources: true
            )
            save(merged, successMessage: "Available local agent sources were added.")
        }

        func chooseFolder() {
            guard started else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.canCreateDirectories = false
            panel.message = "Choose folders containing original agent conversations, sessions or logs."
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
            var activatedCount = 0
            var didChange = false

            for url in urls {
                let standardized = url.standardizedFileURL.path
                let inferred = provider ?? Self.inferredProvider(from: standardized)
                let sourceID = AgentDefaultSourceDiscovery.stableID(provider: inferred, path: standardized)
                let sourceConsentIDs = AgentDefaultSourceDiscovery.consentIDs(
                    for: AgentWatchedFolder(
                        id: sourceID,
                        displayName: inferred.displayName,
                        path: standardized,
                        provider: inferred
                    )
                )
                let tombstoneCount = next.discoveryTombstones.count
                next.discoveryTombstones.removeAll { sourceConsentIDs.contains($0.sourceID) }
                let restoredDefaultSource = next.discoveryTombstones.count != tombstoneCount
                didChange = didChange || restoredDefaultSource

                if let index = next.watchedFolders.firstIndex(where: {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardized
                }) {
                    if !next.watchedFolders[index].isEnabled {
                        next.watchedFolders[index].isEnabled = true
                        activatedCount += 1
                        didChange = true
                    }
                    continue
                }
                next.watchedFolders.append(
                    AgentWatchedFolder(
                        id: restoredDefaultSource ? sourceID : UUID().uuidString,
                        displayName: url.lastPathComponent.isEmpty ? inferred.displayName : url.lastPathComponent,
                        path: standardized,
                        provider: inferred,
                        captureMode: captureMode
                    )
                )
                activatedCount += 1
                didChange = true
            }

            guard didChange else {
                alert = AgentActivityAlert(
                    title: "Folder already monitored",
                    message: urls.count == 1
                        ? urls[0].standardizedFileURL.path
                        : "Every selected folder is already monitored."
                )
                return
            }

            let message =
                activatedCount == 1
                ? "The folder is now monitored locally."
                : "\(activatedCount) folders are now monitored locally."
            save(next, successMessage: message)
        }

        func removeFolder(id: String) {
            guard let folder = configuration.watchedFolders.first(where: { $0.id == id }), !folder.isManaged else {
                return
            }
            var next = configuration
            if AgentDefaultSourceDiscovery.isAutoDiscovered(folder) {
                let consentIDs = AgentDefaultSourceDiscovery.consentIDs(for: folder)
                next.discoveryTombstones.removeAll { consentIDs.contains($0.sourceID) }
                next.discoveryTombstones.append(
                    contentsOf: consentIDs.map { AgentDiscoveryTombstone(sourceID: $0) }
                )
            }
            next.watchedFolders.removeAll { $0.id == id }
            save(next, successMessage: nil, clearTransientAnalyses: true)
        }

        func setFolderEnabled(_ enabled: Bool, id: String) {
            var next = configuration
            guard let index = next.watchedFolders.firstIndex(where: { $0.id == id }) else { return }
            let folder = next.watchedFolders[index]
            let consentIDs = AgentDefaultSourceDiscovery.consentIDs(for: folder)
            if enabled {
                next.discoveryTombstones.removeAll { consentIDs.contains($0.sourceID) }
            } else if AgentDefaultSourceDiscovery.isAutoDiscovered(folder) {
                next.discoveryTombstones.removeAll { consentIDs.contains($0.sourceID) }
                next.discoveryTombstones.append(
                    contentsOf: consentIDs.map { AgentDiscoveryTombstone(sourceID: $0) }
                )
            }
            next.watchedFolders[index].isEnabled = enabled
            save(next, successMessage: nil, clearTransientAnalyses: !enabled)
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
                                ? "Hooks now send only a rescan signal. Conversation text stays in Codex’s original storage. Restart Codex, then approve the Goalong hook from Codex’s /hooks interface if it asks for trust."
                                : "Hooks now send only a rescan signal. Conversation text stays in the provider’s original storage. Restart the agent application if it is already open."
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
                            message:
                                "The lightweight source index remains available; no transcript copy is stored by Goalong History."
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
            GoalongWorkspaceOpenPolicy.open(rootDirectory, purpose: .localFile)
        }

        func openSignalsFolder() {
            GoalongWorkspaceOpenPolicy.open(store.signalsDirectory, purpose: .localFile)
        }

        func openFolder(_ folder: AgentWatchedFolder) {
            GoalongWorkspaceOpenPolicy.open(folder.url, purpose: .localFile)
        }

        func openOriginal(_ record: AgentCaptureRecord) {
            guard AgentSourceAccessAuthority.allows(record.index, configuration: configuration) else {
                alert = AgentActivityAlert(
                    title: "Original source access denied",
                    message: "This index reference is not authorized by an active monitored folder."
                )
                return
            }
            let url = URL(fileURLWithPath: record.sourcePath)
            if record.index.reference.kind == .sqliteConversation,
                FileManager.default.fileExists(atPath: url.path)
            {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                alert = AgentActivityAlert(
                    title: "Original OpenCode database",
                    message:
                        "Conversation \(record.index.stableConversationID) is read directly from this database. Goalong History does not materialize a copy."
                )
            } else if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                alert = AgentActivityAlert(
                    title: "Original file is no longer present",
                    message: "Goalong History keeps only a missing-source state; there is no transcript copy."
                )
            }
        }

        func verify(_ record: AgentCaptureRecord) {
            workQueue.async { [weak self] in
                guard let self else { return }
                let valid: Bool
                do {
                    let current = try self.directRead(
                        entryID: record.id,
                        analysisInterval: record.analysisInterval
                    )
                    valid =
                        current.index.reference == record.index.reference
                        && current.sha256 == record.sha256
                        && current.digestScope == record.digestScope
                } catch {
                    valid = false
                }
                DispatchQueue.main.async {
                    let verifiedScope =
                        record.digestScope == .fullSource
                        ? "complete original source"
                        : "selected-day source projection"
                    self.alert = AgentActivityAlert(
                        title: valid ? "Original source verified" : "Original source changed or unavailable",
                        message: valid
                            ? "The provider’s current \(verifiedScope) matches SHA-256 \(record.sha256)."
                            : "The provider’s original source no longer matches this index entry or cannot be read."
                    )
                }
            }
        }

        func directRead(
            entryID: String,
            analysisInterval: DateInterval? = nil
        ) throws -> AgentCaptureRecord {
            guard let entry = store.entry(id: entryID) else {
                throw AgentActivityRuntimeAccessError.unauthorizedSource(entryID)
            }
            let snapshot = currentScanConfiguration()
            guard AgentSourceAccessAuthority.allows(entry, configuration: snapshot) else {
                throw AgentActivityRuntimeAccessError.unauthorizedSource(entryID)
            }
            return try store.directRead(
                entryID: entryID,
                maximumBytes: snapshot.maximumFileBytes,
                expectedReference: entry.reference,
                analysisInterval: analysisInterval
            )
        }

        private func updateFolder(id: String, mutation: (inout AgentWatchedFolder) -> Void) {
            var next = configuration
            guard let index = next.watchedFolders.firstIndex(where: { $0.id == id }) else { return }
            mutation(&next.watchedFolders[index])
            save(next, successMessage: nil)
        }

        private func save(
            _ configuration: AgentActivityConfiguration,
            successMessage: String?,
            clearTransientAnalyses: Bool = false
        ) {
            do {
                let saved = try store.saveConfiguration(configuration)
                self.configuration = saved
                updateScanSnapshot(configuration: saved)
                if clearTransientAnalyses {
                    store.clearTransientAnalyses()
                    overview = store.overview(for: selectedDay)
                }
                if let successMessage {
                    alert = AgentActivityAlert(title: "Agent monitoring updated", message: successMessage)
                }
                rescheduleTimer()
                // Newly enabled folders have no discovery cursor and will be fully discovered.
                // Existing folders reuse their bounded index instead of being recursively rescanned.
                scanNow(forceFullDiscovery: false)
            } catch {
                alert = AgentActivityAlert(
                    title: "Agent monitoring settings could not be saved",
                    message: error.localizedDescription
                )
            }
        }

        private func performScan(_ request: ScanRequest) {
            let snapshot = currentScanSnapshot()

            if request.clearTransientAnalyses {
                store.clearTransientAnalyses()
            }

            let result = scanner.scan(
                configuration: snapshot.configuration,
                forceFullDiscovery: request.forceFullDiscovery,
                analysisDay: snapshot.day,
                analyzeContent: request.analyzeSelectedDay
            )
            guard !scanIsStopping() else { return }
            if request.analyzeSelectedDay, result.analysisIncomplete {
                // Continue the same bounded pass through the existing single-flight queue. This
                // keeps one utility worker and one scanner while ensuring a 256-source cycle does
                // not silently turn an explicit selected-day request into a partial analysis.
                enqueueScan(
                    forceFullDiscovery: false,
                    clearTransientAnalyses: false,
                    analyzeSelectedDay: true
                )
            }
            if !result.captures.isEmpty { onCaptured(result.captures) }
            let selected = snapshot.day
            // Rebuild from the store on every bounded cycle so expired transient summaries
            // cannot remain strongly retained by the published runtime snapshot.
            let shouldRefreshDerivedState =
                snapshot.dashboardIsVisible
                || request.clearTransientAnalyses
                || request.analyzeSelectedDay
                || request.forceFullDiscovery
                || result.changedSourceCount > 0
                || result.statusChangeCount > 0
                || result.fullDiscoveryCount > 0
                || result.capacityLimitedFolderCount > 0
            if request.analyzeSelectedDay, !result.analysisIncomplete {
                completeSelectedDayAnalysisIfCurrent(selected)
            }
            let nextOverview: AgentActivityOverview?
            let bytes: Int64?
            let validIndex: Bool?
            if shouldRefreshDerivedState {
                // A bounded selected-day pass may need several cycles. Publishing any earlier
                // cycle mixes complete index counts with not-yet-rehydrated titles, causing the
                // intermittent "Codex conversation" rows reported by users.
                nextOverview = (request.analyzeSelectedDay && result.analysisIncomplete)
                    || (!request.analyzeSelectedDay && snapshot.selectedDayRequiresAnalysis)
                    ? nil
                    : store.overview(for: selected)
                bytes = store.storageBytes()
                validIndex = store.indexIsValid(
                    maximumEntries: snapshot.configuration.maximumIndexEntries
                )
                derivedStateRefreshLock.lock()
                derivedStateRefreshCount += 1
                derivedStateRefreshLock.unlock()
            } else {
                nextOverview = nil
                bytes = nil
                validIndex = nil
            }
            let failures = result.failures
            let publishedResult = AgentScanResult(
                scannedSourceCount: result.scannedSourceCount,
                changedSourceCount: result.changedSourceCount,
                skippedSourceCount: result.skippedSourceCount,
                statusChangeCount: result.statusChangeCount,
                fullDiscoveryCount: result.fullDiscoveryCount,
                analysisIncomplete: result.analysisIncomplete,
                capacityLimitedFolderCount: result.capacityLimitedFolderCount,
                failures: result.failures,
                captures: []
            )

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.scanIsStopping() else { return }
                self.lastScanResult = publishedResult
                if let nextOverview, self.selectedDay == selected {
                    self.overview = nextOverview
                }
                if let bytes { self.storageBytes = bytes }
                if let validIndex { self.indexIsValid = validIndex }
                if let first = failures.first {
                    self.alert = AgentActivityAlert(
                        title: "Some agent files could not be read",
                        message: failures.count == 1
                            ? first
                            : "\(first)\n\nAnd \(failures.count - 1) other read error(s)."
                    )
                }
            }
        }

        private func scanIsStopping() -> Bool {
            scanStateLock.lock()
            defer { scanStateLock.unlock() }
            return isStopping
        }

        private func enqueueScan(
            forceFullDiscovery: Bool,
            clearTransientAnalyses: Bool,
            analyzeSelectedDay: Bool
        ) {
            scanStateLock.lock()
            guard !isStopping else {
                scanStateLock.unlock()
                return
            }
            pendingForceFullDiscovery = pendingForceFullDiscovery || forceFullDiscovery
            pendingTransientAnalysisClear = pendingTransientAnalysisClear || clearTransientAnalyses
            pendingSelectedDayAnalysis = pendingSelectedDayAnalysis || analyzeSelectedDay
            if scanWorkScheduledOrRunning {
                scanCatchUpRequested = true
            } else {
                scanWorkScheduledOrRunning = true
                scanGeneration &+= 1
                let generation = scanGeneration
                // Queue while holding the state lock so stop() cannot enqueue its
                // draining barrier ahead of this already-reserved work item.
                workQueue.async { [weak self] in
                    self?.drainScanRequests(generation: generation)
                }
            }
            scanStateLock.unlock()
        }

        private func drainScanRequests(generation: UInt64) {
            guard var request = takeInitialScanRequest(generation: generation) else { return }
            DispatchQueue.main.async { [weak self] in self?.isScanning = true }
            var shouldPublishIdle = false
            defer {
                let abandonedWork = abandonScanWorkIfOwned(generation: generation)
                if shouldPublishIdle || abandonedWork {
                    DispatchQueue.main.async { [weak self] in self?.isScanning = false }
                }
            }

            while true {
                autoreleasepool {
                    performScan(request)
                }
                guard let catchUp = takeCatchUpScanRequest(generation: generation) else {
                    shouldPublishIdle = true
                    return
                }
                request = catchUp
            }
        }

        private func takeInitialScanRequest(generation: UInt64) -> ScanRequest? {
            scanStateLock.lock()
            defer { scanStateLock.unlock() }
            guard scanWorkScheduledOrRunning, scanGeneration == generation, !isStopping else {
                if scanGeneration == generation {
                    scanWorkScheduledOrRunning = false
                    scanCatchUpRequested = false
                    pendingForceFullDiscovery = false
                    pendingTransientAnalysisClear = false
                    pendingSelectedDayAnalysis = false
                }
                return nil
            }
            let request = ScanRequest(
                forceFullDiscovery: pendingForceFullDiscovery,
                clearTransientAnalyses: pendingTransientAnalysisClear,
                analyzeSelectedDay: pendingSelectedDayAnalysis
            )
            scanCatchUpRequested = false
            pendingForceFullDiscovery = false
            pendingTransientAnalysisClear = false
            pendingSelectedDayAnalysis = false
            return request
        }

        private func takeCatchUpScanRequest(generation: UInt64) -> ScanRequest? {
            scanStateLock.lock()
            defer { scanStateLock.unlock() }
            guard scanWorkScheduledOrRunning, scanGeneration == generation, !isStopping else {
                if scanGeneration == generation {
                    scanWorkScheduledOrRunning = false
                    scanCatchUpRequested = false
                    pendingForceFullDiscovery = false
                    pendingTransientAnalysisClear = false
                    pendingSelectedDayAnalysis = false
                }
                return nil
            }
            guard scanCatchUpRequested else {
                scanWorkScheduledOrRunning = false
                return nil
            }
            let request = ScanRequest(
                forceFullDiscovery: pendingForceFullDiscovery,
                clearTransientAnalyses: pendingTransientAnalysisClear,
                analyzeSelectedDay: pendingSelectedDayAnalysis
            )
            scanCatchUpRequested = false
            pendingForceFullDiscovery = false
            pendingTransientAnalysisClear = false
            pendingSelectedDayAnalysis = false
            return request
        }

        private func abandonScanWorkIfOwned(generation: UInt64) -> Bool {
            scanStateLock.lock()
            defer { scanStateLock.unlock() }
            guard scanWorkScheduledOrRunning, scanGeneration == generation else { return false }
            scanWorkScheduledOrRunning = false
            scanCatchUpRequested = false
            pendingForceFullDiscovery = false
            pendingTransientAnalysisClear = false
            pendingSelectedDayAnalysis = false
            return true
        }

        private func scheduleTimer() {
            let interval = Self.effectivePollingInterval(
                configuredInterval: currentScanConfiguration().scanIntervalSeconds
            )
            let timer = DispatchSource.makeTimerSource(queue: workQueue)
            timer.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(500)
            )
            timer.setEventHandler { [weak self] in self?.scanNow(forceFullDiscovery: false) }
            timer.resume()
            scanTimer = timer
        }

        private func scheduleSignalWatcher() {
            guard signalWatcher == nil else { return }
            let descriptor = store.signalsDirectory.path.withCString {
                Darwin.open($0, O_EVTONLY | O_CLOEXEC)
            }
            guard descriptor >= 0 else { return }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: workQueue
            )
            watcher.setEventHandler { [weak self] in
                self?.scanNow(forceFullDiscovery: false)
            }
            watcher.setCancelHandler { _ = Darwin.close(descriptor) }
            watcher.resume()
            signalWatcher = watcher
        }

        static func effectivePollingInterval(configuredInterval: Double) -> Double {
            max(30, configuredInterval)
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

        private func currentScanSnapshot() -> (
            configuration: AgentActivityConfiguration,
            day: Date,
            selectedDayRequiresAnalysis: Bool,
            dashboardIsVisible: Bool
        ) {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            return (
                scanConfiguration,
                scanSelectedDay,
                scanSelectedDayRequiresAnalysis,
                scanDashboardIsVisible
            )
        }

        private func updateScanSnapshot(
            configuration: AgentActivityConfiguration? = nil,
            day: Date? = nil,
            selectedDayRequiresAnalysis: Bool? = nil,
            dashboardIsVisible: Bool? = nil
        ) {
            snapshotLock.lock()
            if let configuration { scanConfiguration = configuration }
            if let day { scanSelectedDay = day }
            if let selectedDayRequiresAnalysis {
                scanSelectedDayRequiresAnalysis = selectedDayRequiresAnalysis
            }
            if let dashboardIsVisible { scanDashboardIsVisible = dashboardIsVisible }
            snapshotLock.unlock()
        }

        private func completeSelectedDayAnalysisIfCurrent(_ day: Date) {
            snapshotLock.lock()
            if scanSelectedDay == day {
                scanSelectedDayRequiresAnalysis = false
            }
            snapshotLock.unlock()
        }

        var derivedStateRefreshCountForTesting: Int {
            derivedStateRefreshLock.lock()
            defer { derivedStateRefreshLock.unlock() }
            return derivedStateRefreshCount
        }

        func waitForPendingScansForTesting() {
            guard DispatchQueue.getSpecific(key: workQueueSpecificKey) == nil else { return }
            workQueue.sync {}
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
