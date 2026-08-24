#if os(macOS)
    import AppKit
    import ApplicationServices
    import Carbon
    import Combine
    import CryptoKit
    import Darwin
    import Foundation
    import LocalHistoryCore

    /// Coordinates every background job that can persist a derived view. A clear-history
    /// operation first suspends admission, invalidates the current generation, and waits
    /// for admitted jobs to finish before it removes source and derived files. Keeping the
    /// suspension active through deletion prevents a queued or in-flight pre-clear job
    /// from recreating those files after the operation reports success.
    final class DerivedHistoryWriteBarrier {
        static let shared = DerivedHistoryWriteBarrier(
            label: "ai.goalong.localhistory.derived-history-clear"
        )

        struct Admission: Equatable {
            fileprivate let generation: UInt64
        }

        struct Permit: Equatable {
            fileprivate let id: UUID
            fileprivate let generation: UInt64
        }

        struct Suspension: Equatable {
            fileprivate let id: UUID
        }

        private let condition = NSCondition()
        private let drainQueue: DispatchQueue
        private var generation: UInt64 = 0
        private var activePermits: Set<UUID> = []
        private var suspensions: Set<UUID> = []

        init(label: String) {
            drainQueue = DispatchQueue(label: label, qos: .utility)
        }

        /// Captures the generation for work that may still be waiting on another queue.
        /// Starting that work after a clear invalidates the admission fails closed.
        func admission() -> Admission? {
            condition.lock()
            defer { condition.unlock() }
            guard suspensions.isEmpty else { return nil }
            return Admission(generation: generation)
        }

        func beginJob(admission: Admission? = nil) -> Permit? {
            condition.lock()
            defer { condition.unlock() }
            guard suspensions.isEmpty,
                admission.map({ $0.generation == generation }) ?? true
            else { return nil }
            let permit = Permit(id: UUID(), generation: generation)
            activePermits.insert(permit.id)
            return permit
        }

        func endJob(_ permit: Permit) {
            condition.lock()
            if activePermits.remove(permit.id) != nil, activePermits.isEmpty {
                condition.broadcast()
            }
            condition.unlock()
        }

        /// A permit from an earlier generation can never authorize a delayed commit,
        /// including after the suspension has been resumed.
        func isCurrent(_ permit: Permit) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return suspensions.isEmpty && permit.generation == generation
        }

        /// Completion delivery is generation-checked too. This prevents a result that
        /// finished just before a clear from being published from the main-queue backlog
        /// after that clear has started or completed.
        func isCurrent(_ admission: Admission) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return suspensions.isEmpty && admission.generation == generation
        }

        @discardableResult
        func suspend() -> Suspension {
            condition.lock()
            generation &+= 1
            let suspension = Suspension(id: UUID())
            suspensions.insert(suspension.id)
            condition.unlock()
            return suspension
        }

        func notifyWhenDrained(
            _ suspension: Suspension,
            on completionQueue: DispatchQueue = .main,
            completion: @escaping () -> Void
        ) {
            drainQueue.async { [self] in
                condition.lock()
                while !activePermits.isEmpty, suspensions.contains(suspension.id) {
                    condition.wait()
                }
                let remainsSuspended = suspensions.contains(suspension.id)
                condition.unlock()
                guard remainsSuspended else { return }
                completionQueue.async(execute: completion)
            }
        }

        func resume(_ suspension: Suspension) {
            condition.lock()
            if suspensions.remove(suspension.id) != nil {
                condition.broadcast()
            }
            condition.unlock()
        }
    }

    protocol ActivityAnalysisRefreshServing: AnyObject {
        func refresh(
            day: Date,
            force: Bool,
            completion: @escaping (Result<ActivityAnalysisCycleResult, Error>) -> Void
        )
    }

    final class ActivityAnalysisRuntime: ActivityAnalysisRefreshServing {
        static let shared = ActivityAnalysisRuntime()
        static let backgroundRefreshInterval: TimeInterval = 10 * 60

        private weak var recorder: EventRecorder?
        private weak var state: CaptureState?
        private weak var configManager: ConfigManager?
        private var currentContext: (() -> ContextSnapshot?)?
        private var semanticContextStore: SemanticContextStore?
        private var memoryStore: LocalActivityMemoryStore?

        private var richContextTimer: Timer?
        private var analysisTimer: Timer?
        private var lastRichContextFingerprints: [String: String] = [:]
        private var lastRichContextCapture = Date.distantPast
        private var interactionCaptureGeneration: UInt64 = 0
        private var started = false
        private let store = ActivityAnalysisStore()
        private let derivedWriteBarrier = DerivedHistoryWriteBarrier.shared
        private let analysisCycleService = ActivityAnalysisCycleService.shared
        private lazy var refreshScheduler = ActivityAnalysisRefreshScheduler(
            label: "ai.goalong.localhistory.activity-analysis-refresh",
            barrier: derivedWriteBarrier
        ) { [weak self] day, force in
            guard let self else {
                throw ActivityAnalysisRefreshError.runtimeUnavailable
            }
            return try self.performRefresh(day: day, force: force)
        }

        private init() {}

        func start(
            recorder: EventRecorder,
            state: CaptureState,
            configManager: ConfigManager,
            currentContext: @escaping () -> ContextSnapshot?,
            semanticContextStore: SemanticContextStore,
            memoryStore: LocalActivityMemoryStore
        ) {
            stop()
            self.recorder = recorder
            self.state = state
            self.configManager = configManager
            self.currentContext = currentContext
            self.semanticContextStore = semanticContextStore
            self.memoryStore = memoryStore
            started = true

            let analysisTimer = Timer(
                timeInterval: Self.backgroundRefreshInterval,
                repeats: true
            ) { [weak self] _ in
                self?.generateRecentAnalyses(force: false)
            }
            analysisTimer.tolerance = 30
            RunLoop.main.add(analysisTimer, forMode: .common)
            self.analysisTimer = analysisTimer
            scheduleRichContextTimer()
            generateRecentAnalyses(force: true)
        }

        func stop() {
            started = false
            richContextTimer?.invalidate()
            analysisTimer?.invalidate()
            richContextTimer = nil
            analysisTimer = nil
            currentContext = nil
            semanticContextStore = nil
            memoryStore = nil
        }

        /// Captures bounded Accessibility context linked to one concrete interaction.
        /// Near-event capture is intentionally shallow to keep the event tap responsive;
        /// the delayed settled phase receives the full tree budget. Only explicitly
        /// chronological evidence may later be used as a true before-state.
        func captureInteractionContext(
            interactionID: String,
            phase: String,
            trigger: String,
            context explicitContext: ContextSnapshot? = nil
        ) {
            guard !interactionID.isEmpty else { return }
            guard let snapshot = explicitContext ?? currentContext?() else { return }
            let budget = semanticBudget(for: phase)
            _ = persistSemanticContext(
                snapshot: snapshot,
                maximumCharacters: budget.characters,
                maximumNodes: budget.nodes,
                deduplicate: false,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: phase,
                    ComputerHistoryMetadata.interactionTrigger: trigger,
                    "computer_history.capture_nodes": String(budget.nodes),
                ]
            )
        }

        /// Captures an event-driven semantic observation that is not tied to an input
        /// interaction, such as a programmatic value change or a short-lived window title.
        /// Fingerprint deduplication prevents Accessibility notification storms from
        /// producing duplicate local payloads.
        func captureObservedContext(
            trigger: String,
            context explicitContext: ContextSnapshot? = nil
        ) {
            guard let snapshot = explicitContext ?? currentContext?() else { return }
            _ = persistSemanticContext(
                snapshot: snapshot,
                maximumCharacters: 4_800,
                maximumNodes: 180,
                deduplicate: true,
                metadata: [
                    ComputerHistoryMetadata.interactionTrigger: "ax:\(trigger)",
                    "computer_history.capture_nodes": "180",
                ]
            )
        }

        func scheduleInteractionContext(
            interactionID: String,
            phase: String,
            trigger: String,
            delay: TimeInterval
        ) {
            guard !interactionID.isEmpty else { return }
            let scheduledGeneration = interactionCaptureGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Swift.max(0, delay)) { [weak self] in
                guard let self,
                    self.interactionCaptureGeneration == scheduledGeneration
                else { return }
                self.captureInteractionContext(
                    interactionID: interactionID,
                    phase: phase,
                    trigger: trigger
                )
            }
        }

        /// Invalidates delayed semantic captures tied to pre-clear interactions and
        /// clears metadata-only deduplication state so post-clear observations can be
        /// captured from a clean generation.
        func prepareForHistoryClear() {
            interactionCaptureGeneration &+= 1
            lastRichContextFingerprints.removeAll(keepingCapacity: false)
            lastRichContextCapture = .distantPast
        }

        private func semanticBudget(for phase: String) -> (characters: Int, nodes: Int) {
            switch phase {
            case ComputerHistoryMetadata.Phase.before,
                ComputerHistoryMetadata.Phase.nearEvent:
                return (2_400, 72)
            case ComputerHistoryMetadata.Phase.after:
                return (4_800, 160)
            case ComputerHistoryMetadata.Phase.settled:
                return (6_000, 260)
            default:
                return (4_000, 140)
            }
        }

        private func captureRichContextIfNeeded() {
            let now = Date()
            let interval = ActivityAnalysisPreferences.richContextIntervalSeconds
            // Check the configured cadence before sampling foreground context. The old
            // two-second timer called ContextMonitor.sampleNow() even when the eventual
            // AX capture was not due, bypassing that monitor's adaptive backoff.
            guard now.timeIntervalSince(lastRichContextCapture) >= interval,
                ActivityAnalysisPreferences.richContextEnabled,
                let state,
                state.isCapturing,
                let snapshot = currentContext?(),
                snapshot.suppressionReason == nil,
                snapshot.focusedElement?.isSecure != true
            else { return }

            lastRichContextCapture = now
            _ = persistSemanticContext(
                snapshot: snapshot,
                maximumCharacters: 6_000,
                maximumNodes: 260,
                deduplicate: true,
                metadata: [ComputerHistoryMetadata.interactionTrigger: "periodic"]
            )
        }

        private func scheduleRichContextTimer() {
            richContextTimer?.invalidate()
            richContextTimer = nil
            guard
                Self.shouldScheduleRichContextTimer(
                    started: started,
                    enabled: ActivityAnalysisPreferences.richContextEnabled
                )
            else { return }
            let timer = Timer(
                timeInterval: ActivityAnalysisPreferences.richContextIntervalSeconds,
                repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                self.captureRichContextIfNeeded()
                self.scheduleRichContextTimer()
            }
            RunLoop.main.add(timer, forMode: .common)
            richContextTimer = timer
        }

        func richContextPreferenceDidChange() {
            if ActivityAnalysisPreferences.richContextEnabled {
                scheduleRichContextTimer()
            } else {
                richContextTimer?.invalidate()
                richContextTimer = nil
            }
        }

        var hasRichContextTimerForTesting: Bool { richContextTimer != nil }

        static func shouldScheduleRichContextTimer(started: Bool, enabled: Bool) -> Bool {
            started && enabled
        }

        @discardableResult
        private func persistSemanticContext(
            snapshot: ContextSnapshot,
            maximumCharacters: Int,
            maximumNodes: Int,
            deduplicate: Bool,
            metadata additionalMetadata: [String: String]
        ) -> SemanticContextReference? {
            guard ActivityAnalysisPreferences.richContextEnabled,
                let recorder,
                let state,
                state.isCapturing,
                snapshot.suppressionReason == nil,
                snapshot.focusedElement?.isSecure != true,
                !IsSecureEventInputEnabled(),
                let validatedSnapshot = currentContext?(),
                Self.semanticBoundaryMatches(validatedSnapshot, expected: snapshot),
                let application = NSRunningApplication(
                    processIdentifier: validatedSnapshot.app.processIdentifier
                ),
                application.isTerminated == false,
                let capture = AXRichContextReader.capture(
                    processIdentifier: validatedSnapshot.app.processIdentifier,
                    maximumCharacters: maximumCharacters,
                    maximumNodes: maximumNodes
                ),
                !IsSecureEventInputEnabled(),
                let postCaptureSnapshot = currentContext?(),
                Self.semanticBoundaryMatches(
                    postCaptureSnapshot,
                    expected: validatedSnapshot
                )
            else { return nil }

            let contextKey = [
                validatedSnapshot.app.bundleIdentifier
                    ?? "pid:\(validatedSnapshot.app.processIdentifier)",
                validatedSnapshot.url?.value ?? "",
                validatedSnapshot.window?.title ?? "",
            ].joined(separator: "|")
            if deduplicate {
                guard lastRichContextFingerprints[contextKey] != capture.fingerprint else {
                    return nil
                }
                lastRichContextFingerprints[contextKey] = capture.fingerprint
                if lastRichContextFingerprints.count > 256,
                    let firstKey = lastRichContextFingerprints.keys.first
                {
                    lastRichContextFingerprints.removeValue(forKey: firstKey)
                }
            }

            guard let semanticContextStore else { return nil }
            do {
                let reference = try semanticContextStore.append(
                    capture: capture,
                    context: validatedSnapshot
                )
                var metadata: [String: String] = [
                    ActivitySemanticMetadata.version: "4",
                    ActivitySemanticMetadata.source: capture.source,
                    ActivitySemanticMetadata.redacted: String(capture.redacted),
                    ActivitySemanticMetadata.truncated: String(capture.truncated),
                    ActivitySemanticMetadata.fingerprint: capture.fingerprint,
                    ActivitySemanticMetadata.characterCount: String(capture.text.count),
                    "semantic_storage": "separate_local_jsonl",
                ]
                for (key, value) in additionalMetadata { metadata[key] = value }
                recorder.record(
                    kind: .semanticSnapshot,
                    context: validatedSnapshot,
                    semanticContext: reference,
                    metadata: metadata
                )
                return reference
            } catch {
                Diagnostics.write("Semantic context persistence failed: \(error)")
                return nil
            }
        }

        static func semanticBoundaryMatches(
            _ candidate: ContextSnapshot,
            expected: ContextSnapshot
        ) -> Bool {
            candidate.suppressionReason == nil
                && candidate.focusedElement?.isSecure != true
                && candidate.app.processIdentifier == expected.app.processIdentifier
                && candidate.app.bundleIdentifier == expected.app.bundleIdentifier
                && candidate.fingerprint == expected.fingerprint
        }

        private func generateRecentAnalyses(force: Bool) {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            // Enqueue older input first so today's workflow detection sees the refreshed
            // prior memory. The scheduler serializes these with every UI refresh.
            for day in [yesterday, today].compactMap({ $0 }) {
                refresh(day: day, force: force) { result in
                    if case .failure(let error) = result,
                        !(error is ActivityAnalysisRefreshError)
                    {
                        Diagnostics.write(
                            "Activity analysis generation failed for \(ActivityAnalysisPaths.dayString(day)): \(error)"
                        )
                    }
                }
            }
        }

        /// The only asynchronous entry point used by the UI and background cadence.
        /// Equal day/force requests share one admitted coordinator execution and all
        /// completions are delivered on the main queue.
        func refresh(
            day: Date,
            force: Bool,
            completion: @escaping (Result<ActivityAnalysisCycleResult, Error>) -> Void
        ) {
            refreshScheduler.request(
                day: Calendar.current.startOfDay(for: day),
                force: force,
                completionQueue: .main,
                completion: completion
            )
        }

        /// Called while the global derived-write barrier is suspended and drained.
        /// Clearing the tiny revision cache ensures no pre-clear source revision can be
        /// reused after source files have been rewritten or removed.
        func invalidateRevisionCacheForHistoryClear() throws {
            try analysisCycleService.invalidateRevisionCache()
        }

        /// Rebuilds only from the post-clear source state. The barrier must be resumed
        /// before this is called so the pass receives a permit in the new generation.
        func refreshAfterHistoryClear() {
            generateRecentAnalyses(force: true)
        }

        private func performRefresh(
            day: Date,
            force: Bool
        ) throws -> ActivityAnalysisCycleResult {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            if force {
                store.removeOrphanedAnalyses()
            }
            // Keep only the active rolling days plus a selected historical day. This
            // bounds the revision cache without making an old-day UI refresh evict the
            // hot today/yesterday entries.
            analysisCycleService.retainCacheEntries(
                for: Set([yesterday, today, day].compactMap { $0 }).sorted()
            )

            let result = try autoreleasepool {
                try analysisCycleService.process(
                    day: day,
                    tokenBudget: ActivityAnalysisPreferences.agentTokenBudget,
                    forceVerification: force,
                    includeActivityMemory: memoryStore != nil
                )
            }
            if result.sourceAbsent {
                // Match the prior retention contract: the regenerable compact analysis
                // is removed, while long-lived memories and Computer History persist.
                store.removeAnalysis(for: day)
            }
            for issue in result.issues {
                Diagnostics.write(
                    "Activity analysis load gap: \(issue.path):\(issue.line.map(String.init) ?? "-") \(issue.message)"
                )
            }
            return result
        }
    }

    /// Serializes expensive day analysis and collapses an arbitrary burst of requests
    /// into the active pass plus at most one catch-up pass.
    final class ActivityAnalysisPassCoalescer {
        private let queue: DispatchQueue
        private let lock = NSLock()
        private let pendingGroup = DispatchGroup()
        private var passScheduled = false
        private var catchUpRequested = false
        private var forcedPassRequested = false

        init(label: String) {
            queue = DispatchQueue(label: label, qos: .utility)
        }

        func request(
            force: Bool,
            operation: @escaping (Bool) -> Void
        ) {
            lock.lock()
            forcedPassRequested = forcedPassRequested || force
            if passScheduled {
                catchUpRequested = true
                lock.unlock()
                return
            }
            passScheduled = true
            pendingGroup.enter()
            lock.unlock()

            queue.async { [self] in
                defer { self.pendingGroup.leave() }

                while true {
                    self.lock.lock()
                    let requestedForce = self.forcedPassRequested
                    self.forcedPassRequested = false
                    self.catchUpRequested = false
                    self.lock.unlock()

                    operation(requestedForce)

                    self.lock.lock()
                    let shouldCatchUp = self.catchUpRequested
                    if !shouldCatchUp {
                        self.passScheduled = false
                        self.catchUpRequested = false
                        self.forcedPassRequested = false
                    }
                    self.lock.unlock()
                    if !shouldCatchUp { return }
                }
            }
        }

        func waitUntilIdle(timeout: DispatchTime) -> Bool {
            pendingGroup.wait(timeout: timeout) == .success
        }
    }

    enum ActivityAnalysisRefreshError: LocalizedError, Equatable {
        case temporarilySuspended
        case invalidatedByHistoryClear
        case runtimeUnavailable

        var errorDescription: String? {
            switch self {
            case .temporarilySuspended:
                return "Derived history refresh is paused while local history is being cleared"
            case .invalidatedByHistoryClear:
                return "The refresh was cancelled because local history was cleared"
            case .runtimeUnavailable:
                return "The activity-analysis runtime is no longer available"
            }
        }
    }

    /// Coalesces equal UI/background requests onto one serial coordinator execution.
    /// The barrier generation participates in the key so a post-clear refresh can never
    /// join work admitted from the previous generation.
    final class ActivityAnalysisRefreshScheduler {
        typealias Operation = (Date, Bool) throws -> ActivityAnalysisCycleResult
        typealias Completion = (Result<ActivityAnalysisCycleResult, Error>) -> Void

        private struct RequestKey: Hashable {
            let dayKey: String
            let force: Bool
            let barrierGeneration: UInt64
        }

        private struct Callback {
            let admission: DerivedHistoryWriteBarrier.Admission
            let queue: DispatchQueue
            let completion: Completion
        }

        private struct PendingRequest {
            let day: Date
            let force: Bool
            let admission: DerivedHistoryWriteBarrier.Admission
            var callbacks: [Callback]
        }

        private let queue: DispatchQueue
        private let barrier: DerivedHistoryWriteBarrier
        private let operation: Operation
        private let lock = NSLock()
        private let pendingGroup = DispatchGroup()
        private var pending: [RequestKey: PendingRequest] = [:]

        init(
            label: String,
            barrier: DerivedHistoryWriteBarrier,
            operation: @escaping Operation
        ) {
            queue = DispatchQueue(label: label, qos: .utility)
            self.barrier = barrier
            self.operation = operation
        }

        func request(
            day: Date,
            force: Bool,
            completionQueue: DispatchQueue,
            completion: @escaping Completion
        ) {
            guard let admission = barrier.admission() else {
                completionQueue.async {
                    completion(.failure(ActivityAnalysisRefreshError.temporarilySuspended))
                }
                return
            }

            let normalized = Calendar.current.startOfDay(for: day)
            let key = RequestKey(
                dayKey: ActivityAnalysisPaths.dayString(normalized),
                force: force,
                barrierGeneration: admission.generation
            )
            let callback = Callback(
                admission: admission,
                queue: completionQueue,
                completion: completion
            )

            lock.lock()
            if var existing = pending[key] {
                existing.callbacks.append(callback)
                pending[key] = existing
                lock.unlock()
                return
            }
            pending[key] = PendingRequest(
                day: normalized,
                force: force,
                admission: admission,
                callbacks: [callback]
            )
            pendingGroup.enter()
            lock.unlock()

            queue.async { [self] in
                run(key: key)
            }
        }

        func waitUntilIdle(timeout: DispatchTime) -> Bool {
            pendingGroup.wait(timeout: timeout) == .success
        }

        private func run(key: RequestKey) {
            lock.lock()
            guard let request = pending[key] else {
                lock.unlock()
                return
            }
            lock.unlock()

            let result: Result<ActivityAnalysisCycleResult, Error>
            if let permit = barrier.beginJob(admission: request.admission) {
                result = Result {
                    try autoreleasepool {
                        try operation(request.day, request.force)
                    }
                }
                barrier.endJob(permit)
            } else {
                result = .failure(ActivityAnalysisRefreshError.invalidatedByHistoryClear)
            }

            lock.lock()
            let callbacks = pending.removeValue(forKey: key)?.callbacks ?? []
            lock.unlock()
            pendingGroup.leave()

            for callback in callbacks {
                callback.queue.async { [barrier] in
                    guard barrier.isCurrent(callback.admission) else {
                        callback.completion(
                            .failure(ActivityAnalysisRefreshError.invalidatedByHistoryClear)
                        )
                        return
                    }
                    callback.completion(result)
                }
            }
        }
    }

    struct ActivityAnalysisCycleResult: Equatable {
        let sourceAbsent: Bool
        let issues: [HistoryLoadIssue]
        let sourceBytesRead: Int64
        let sourceReadPasses: Int
        let derivedViewsWritten: Int
        let usedCachedRevision: Bool
    }

    /// Owns the single mutable coordinator/cache for one source root. Equal requests
    /// share the active result (including failures), while different requests wait for
    /// that flight to finish so two loaders can never read or rewrite the same root at
    /// once. The process registry is weak for fixture roots; the application root is
    /// held strongly by `shared` for the lifetime of the app.
    final class ActivityAnalysisCycleService {
        typealias Operation = (
            Date,
            Int,
            Bool,
            Bool
        ) throws -> ActivityAnalysisCycleResult
        typealias RevisionProvider = (Date, Int) -> ActivityAnalysisSourceProbe

        private struct RequestKey: Equatable {
            let dayKey: String
            let tokenBudget: Int
            let forceVerification: Bool
            let includeActivityMemory: Bool
            let sourceProbe: ActivityAnalysisSourceProbe
        }

        private final class Flight {
            let key: RequestKey
            let leaderThreadID: UInt32
            var result: Result<ActivityAnalysisCycleResult, Error>?
            var joinedRequestCount = 0

            init(key: RequestKey, leaderThreadID: UInt32) {
                self.key = key
                self.leaderThreadID = leaderThreadID
            }
        }

        private final class WeakService {
            weak var value: ActivityAnalysisCycleService?

            init(_ value: ActivityAnalysisCycleService) {
                self.value = value
            }
        }

        static let shared: ActivityAnalysisCycleService = {
            let coordinator = ActivityAnalysisCycleCoordinator(
                rootDirectory: AppPaths.applicationSupportDirectory,
                computerHistoryStore: ComputerHistoryStore()
            )
            return ActivityAnalysisCycleService(coordinator: coordinator)
        }()

        private static let registryLock = NSLock()
        private static var processWideServices: [String: WeakService] = [:]

        private let condition = NSCondition()
        private let operation: Operation
        private let revisionProvider: RevisionProvider
        private let retainOperation: ([Date]) -> Void
        private let invalidateOperation: () throws -> Void
        private var activeFlight: Flight?
        private var exclusiveOperationActive = false

        private init(coordinator: ActivityAnalysisCycleCoordinator) {
            revisionProvider = { coordinator.probe(day: $0, tokenBudget: $1) }
            operation = { day, tokenBudget, forceVerification, includeActivityMemory in
                try coordinator.process(
                    day: day,
                    tokenBudget: tokenBudget,
                    forceVerification: forceVerification,
                    includeActivityMemory: includeActivityMemory
                )
            }
            retainOperation = { coordinator.retainCacheEntries(for: $0) }
            invalidateOperation = { try coordinator.invalidateRevisionCache() }
        }

        /// Internal injection keeps the single-flight behavior independently testable
        /// without adding a second source loader or a persistent result cache.
        init(
            revisionProvider: @escaping RevisionProvider,
            operation: @escaping Operation,
            retainCacheEntries: @escaping ([Date]) -> Void = { _ in },
            invalidateRevisionCache: @escaping () throws -> Void = {}
        ) {
            self.revisionProvider = revisionProvider
            self.operation = operation
            retainOperation = retainCacheEntries
            invalidateOperation = invalidateRevisionCache
        }

        static func processWide(
            rootDirectory: URL,
            computerHistoryStore: ComputerHistoryStore
        ) -> ActivityAnalysisCycleService {
            let rootKey = rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            let applicationRootKey = AppPaths.applicationSupportDirectory.standardizedFileURL
                .resolvingSymlinksInPath().path
            if rootKey == applicationRootKey {
                return shared
            }

            registryLock.lock()
            defer { registryLock.unlock() }
            processWideServices = processWideServices.filter { $0.value.value != nil }
            if let existing = processWideServices[rootKey]?.value {
                return existing
            }
            let service = ActivityAnalysisCycleService(
                coordinator: ActivityAnalysisCycleCoordinator(
                    rootDirectory: rootDirectory,
                    computerHistoryStore: computerHistoryStore
                )
            )
            processWideServices[rootKey] = WeakService(service)
            return service
        }

        func process(
            day: Date,
            tokenBudget: Int,
            forceVerification: Bool,
            includeActivityMemory: Bool
        ) throws -> ActivityAnalysisCycleResult {
            let normalizedDay = Calendar.current.startOfDay(for: day)
            let sourceProbe = revisionProvider(normalizedDay, tokenBudget)
            let key = RequestKey(
                dayKey: ActivityAnalysisPaths.dayString(normalizedDay),
                tokenBudget: tokenBudget,
                forceVerification: forceVerification,
                includeActivityMemory: includeActivityMemory,
                sourceProbe: sourceProbe
            )
            var ownedFlight: Flight?
            let currentThreadID = pthread_mach_thread_np(pthread_self())

            condition.lock()
            while ownedFlight == nil {
                while exclusiveOperationActive {
                    condition.wait()
                }
                if let flight = activeFlight {
                    if flight.leaderThreadID == currentThreadID {
                        condition.unlock()
                        throw ActivityAnalysisCycleError.reentrantCycle
                    }
                    if flight.key == key {
                        flight.joinedRequestCount += 1
                        condition.broadcast()
                        while flight.result == nil {
                            condition.wait()
                        }
                        let result = flight.result!
                        condition.unlock()
                        return try result.get()
                    }
                    condition.wait()
                    continue
                }
                let flight = Flight(key: key, leaderThreadID: currentThreadID)
                activeFlight = flight
                ownedFlight = flight
            }
            condition.unlock()

            let result: Result<ActivityAnalysisCycleResult, Error> = Result {
                try operation(
                    normalizedDay,
                    tokenBudget,
                    forceVerification,
                    includeActivityMemory
                )
            }

            condition.lock()
            ownedFlight?.result = result
            activeFlight = nil
            condition.broadcast()
            condition.unlock()
            return try result.get()
        }

        func retainCacheEntries(for days: [Date]) {
            withExclusiveOperation {
                retainOperation(days)
            }
        }

        func invalidateRevisionCache() throws {
            try withExclusiveOperation {
                try invalidateOperation()
            }
        }

        /// Bounded test diagnostic used to release a deliberately paused source pass
        /// only after the second trigger has joined that exact flight.
        func waitUntilCurrentFlightIsShared(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while activeFlight?.joinedRequestCount == 0 {
                guard condition.wait(until: deadline) else { return false }
            }
            return true
        }

        private func withExclusiveOperation<T>(_ body: () throws -> T) rethrows -> T {
            condition.lock()
            while exclusiveOperationActive || activeFlight != nil {
                condition.wait()
            }
            exclusiveOperationActive = true
            condition.unlock()
            defer {
                condition.lock()
                exclusiveOperationActive = false
                condition.broadcast()
                condition.unlock()
            }
            return try body()
        }
    }

    struct ActivityAnalysisFileStamp: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    struct ActivityAnalysisSourceRevision: Codable, Equatable {
        let event: ActivityAnalysisFileStamp
        let semantic: ActivityAnalysisFileStamp?
        let processingKey: String
    }

    enum ActivityAnalysisSourceProbe: Equatable {
        case absent
        case available(ActivityAnalysisSourceRevision)
        case inaccessible(String)
    }

    struct ActivityAnalysisPriorRevisionLimits {
        let maximumDirectoryEntries: Int
        let maximumScanDuration: TimeInterval

        static let production = ActivityAnalysisPriorRevisionLimits(
            maximumDirectoryEntries: 20_000,
            maximumScanDuration: 2
        )
    }

    struct ActivityAnalysisDayLoadLimits {
        static let production = ActivityAnalysisDayLoadLimits(
            maximumRetainedRows: 32_768,
            maximumEstimatedRetainedBytes: 64 * 1_024 * 1_024
        )

        let maximumRetainedRows: Int
        let maximumEstimatedRetainedBytes: Int64

        init(maximumRetainedRows: Int, maximumEstimatedRetainedBytes: Int64) {
            self.maximumRetainedRows = max(0, maximumRetainedRows)
            self.maximumEstimatedRetainedBytes = max(0, maximumEstimatedRetainedBytes)
        }
    }

    struct ActivityAnalysisPriorRevisionDiagnostics: Equatable {
        let scannedEntryCount: Int
        let peakRetainedCandidateCount: Int
        let selectedNames: [String]
        let usedCachedDirectoryRevision: Bool
    }

    struct ActivityAnalysisDaySnapshot {
        let events: [HistoryEvent]
        let sourceJournalSummary: ComputerHistorySourceJournalSummary
        let sourceTail: ActivityAnalysisSourceTail?
        let semanticSnapshots: [String: SemanticContextPayload]
        let issues: [HistoryLoadIssue]
        let bytesRead: Int64
        let contentDigest: String
    }

    struct ActivityAnalysisSourceTail: Codable, Equatable {
        let eventCount: Int
        let continuityBoundaryCount: Int
        let firstSourceSequence: UInt64?
        let lastSourceSequence: UInt64?
        let lastSourceEventHash: String?
        let lastEventTimestamp: Date?
        let lastEventID: String?
        let endedWithNewline: Bool
    }

    private struct ActivityAnalysisMaintenanceSuffix {
        let sourceTail: ActivityAnalysisSourceTail
        let bytesRead: Int64
        let contentDigest: String
    }

    enum ActivityAnalysisCycleError: LocalizedError {
        case sourceInaccessible(String)
        case sourceChangedDuringRead
        case oversizedJSONLine(path: String, maximumBytes: Int)
        case reentrantCycle

        var errorDescription: String? {
            switch self {
            case .sourceInaccessible(let message):
                return message
            case .sourceChangedDuringRead:
                return "The source journal changed while it was being read; keeping the last known-good derived views"
            case .oversizedJSONLine(let path, let maximumBytes):
                return "Refused an oversized JSONL row in \(path) (maximum \(maximumBytes) bytes)"
            case .reentrantCycle:
                return "Refused a reentrant activity-analysis cycle on the same source root"
            }
        }
    }

    private struct ActivityAnalysisRevisionCacheFile: Codable {
        let version: Int
        var entries: [String: ActivityAnalysisRevisionCacheEntry]
    }

    struct ActivityAnalysisRevisionCacheEntry: Codable, Equatable {
        let revision: ActivityAnalysisSourceRevision
        let sourceContentDigest: String
        let sourceTail: ActivityAnalysisSourceTail?
        let expectedOutputs: [String]
        let outputRevision: String?
        let successfulAt: Date
    }

    final class ActivityAnalysisRevisionCache {
        private static let formatVersion = 1
        private static let maximumEntryCount = 4
        private static let maximumBytes = 64 * 1_024
        private static let maximumLastEventIDBytes = 512
        private static let allowedOutputs: Set<String> = [
            "analysis-json", "analysis-markdown", "memory-json", "memory-markdown",
            "computer-history-json",
        ]

        private let fileManager: FileManager
        private let analysisDirectory: URL
        private let cacheURL: URL
        private let dataWriter: (Data, URL) throws -> Void
        private var entries: [String: ActivityAnalysisRevisionCacheEntry] = [:]

        init(
            rootDirectory: URL,
            fileManager: FileManager = .default,
            dataWriter: @escaping (Data, URL) throws -> Void = {
                try GoalongOwnedAtomicFileWriter.write($0, to: $1)
            }
        ) {
            self.fileManager = fileManager
            analysisDirectory = rootDirectory.appendingPathComponent("analysis", isDirectory: true)
            cacheURL = analysisDirectory.appendingPathComponent("runtime-input-cache.json")
            self.dataWriter = dataWriter
            load()
        }

        func entry(for key: String) -> ActivityAnalysisRevisionCacheEntry? {
            entries[key]
        }

        func set(_ entry: ActivityAnalysisRevisionCacheEntry, for key: String) throws {
            var updated = entries
            updated[key] = Self.entryByBoundingSourceTail(entry)
            // Keep the invariant here rather than relying on individual callers to
            // prune first. Every entry point therefore receives the same hard limit.
            let otherKeysByRecency =
                updated.filter { $0.key != key }
                .sorted {
                    if $0.value.successfulAt == $1.value.successfulAt {
                        return $0.key > $1.key
                    }
                    return $0.value.successfulAt > $1.value.successfulAt
                }
                .map(\.key)
            let retainedKeys = Set(
                [key] + otherKeysByRecency.prefix(Self.maximumEntryCount - 1)
            )
            updated = updated.filter { retainedKeys.contains($0.key) }
            try persist(updated)
            entries = updated
        }

        func removeValue(for key: String) throws {
            var updated = entries
            guard updated.removeValue(forKey: key) != nil else { return }
            try persist(updated)
            entries = updated
        }

        func retain(keys: Set<String>) throws {
            let filtered = entries.filter { keys.contains($0.key) }
            guard filtered.count != entries.count else { return }
            try persist(filtered)
            entries = filtered
        }

        func removeAll() throws {
            guard !entries.isEmpty || Self.isRegularFileWithoutFollowingSymlinks(cacheURL) else {
                return
            }
            try persist([:])
            entries.removeAll()
        }

        func outputsExist(_ names: [String], rootDirectory: URL, dayKey: String) -> Bool {
            guard !names.isEmpty, names.allSatisfy(Self.allowedOutputs.contains) else { return false }
            return names.allSatisfy { name in
                let URL: URL
                switch name {
                case "analysis-json":
                    URL = rootDirectory.appendingPathComponent("analysis/\(dayKey).analysis.json")
                case "analysis-markdown":
                    URL = rootDirectory.appendingPathComponent("analysis/\(dayKey).agent.md")
                case "memory-json":
                    URL = rootDirectory.appendingPathComponent("memories/\(dayKey).memory.json")
                case "memory-markdown":
                    URL = rootDirectory.appendingPathComponent("memories/\(dayKey).memory.md")
                case "computer-history-json":
                    URL = rootDirectory.appendingPathComponent("computer-history/\(dayKey).computer-history.json")
                default:
                    return false
                }
                return Self.isRegularFileWithoutFollowingSymlinks(URL)
            }
        }

        func outputsMatch(
            _ entry: ActivityAnalysisRevisionCacheEntry,
            rootDirectory: URL,
            dayKey: String
        ) -> Bool {
            guard let expected = entry.outputRevision else { return false }
            return outputRevision(
                entry.expectedOutputs,
                rootDirectory: rootDirectory,
                dayKey: dayKey
            ) == expected
        }

        func outputRevision(
            _ names: [String],
            rootDirectory: URL,
            dayKey: String
        ) -> String? {
            guard outputsExist(names, rootDirectory: rootDirectory, dayKey: dayKey) else {
                return nil
            }
            let rows = names.sorted().compactMap { name -> String? in
                let relative: String
                switch name {
                case "analysis-json": relative = "analysis/\(dayKey).analysis.json"
                case "analysis-markdown": relative = "analysis/\(dayKey).agent.md"
                case "memory-json": relative = "memories/\(dayKey).memory.json"
                case "memory-markdown": relative = "memories/\(dayKey).memory.md"
                case "computer-history-json":
                    relative = "computer-history/\(dayKey).computer-history.json"
                default: return nil
                }
                let URL = rootDirectory.appendingPathComponent(relative)
                var information = stat()
                guard lstat(URL.path, &information) == 0,
                    (information.st_mode & S_IFMT) == S_IFREG
                else { return nil }
                return
                    "\(name)|\(information.st_dev):\(information.st_ino):\(information.st_size):\(information.st_mtimespec.tv_sec):\(information.st_mtimespec.tv_nsec)"
            }
            guard rows.count == names.count else { return nil }
            return SHA256Digest.hashHex(rows.joined(separator: "\n"))
        }

        private func load() {
            guard Self.isRegularFileWithoutFollowingSymlinks(cacheURL),
                let values = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]),
                let size = values.fileSize,
                size >= 0,
                size <= Self.maximumBytes,
                let data = try? Data(contentsOf: cacheURL, options: [.mappedIfSafe])
            else { return }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let stored = try? decoder.decode(ActivityAnalysisRevisionCacheFile.self, from: data),
                stored.version == Self.formatVersion,
                stored.entries.count <= Self.maximumEntryCount,
                stored.entries.values.allSatisfy({ entry in
                    entry.sourceContentDigest.count == 64
                        && (entry.outputRevision == nil || entry.outputRevision?.count == 64)
                        && entry.expectedOutputs.allSatisfy(Self.allowedOutputs.contains)
                })
            else { return }
            entries = stored.entries.mapValues(Self.entryByBoundingSourceTail)
        }

        private func persist(_ candidateEntries: [String: ActivityAnalysisRevisionCacheEntry]) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(
                ActivityAnalysisRevisionCacheFile(
                    version: Self.formatVersion,
                    entries: candidateEntries
                )
            )
            guard candidateEntries.count <= Self.maximumEntryCount,
                data.count <= Self.maximumBytes
            else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "The bounded activity-analysis cache exceeded 4 entries or \(Self.maximumBytes) bytes"
                )
            }

            var directoryInformation = stat()
            let directoryStatus = lstat(analysisDirectory.path, &directoryInformation)
            if directoryStatus == 0 {
                guard (directoryInformation.st_mode & S_IFMT) == S_IFDIR else {
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Refused non-directory analysis cache path \(analysisDirectory.path)"
                    )
                }
            } else if errno == ENOENT {
                try fileManager.createDirectory(
                    at: analysisDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not inspect analysis cache path \(analysisDirectory.path): \(String(cString: strerror(errno)))"
                )
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: analysisDirectory.path
            )
            var cacheInformation = stat()
            let cacheStatus = lstat(cacheURL.path, &cacheInformation)
            if cacheStatus == 0,
                (cacheInformation.st_mode & S_IFMT) != S_IFREG
            {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Refused non-regular analysis cache file \(cacheURL.path)"
                )
            } else if cacheStatus != 0, errno != ENOENT {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not inspect analysis cache file \(cacheURL.path): \(String(cString: strerror(errno)))"
                )
            }
            try dataWriter(data, cacheURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }

        private static func entryByBoundingSourceTail(
            _ entry: ActivityAnalysisRevisionCacheEntry
        ) -> ActivityAnalysisRevisionCacheEntry {
            guard let sourceTail = entry.sourceTail,
                let lastEventID = sourceTail.lastEventID,
                lastEventID.utf8.count > maximumLastEventIDBytes
            else { return entry }

            // The ID is needed only by the append-only shortcut. Dropping the tail is
            // safer than truncating an ordering key: the next pass performs an exact
            // full read while the persistent cache remains small.
            return ActivityAnalysisRevisionCacheEntry(
                revision: entry.revision,
                sourceContentDigest: entry.sourceContentDigest,
                sourceTail: nil,
                expectedOutputs: entry.expectedOutputs,
                outputRevision: entry.outputRevision,
                successfulAt: entry.successfulAt
            )
        }

        private static func isRegularFileWithoutFollowingSymlinks(_ URL: URL) -> Bool {
            var information = stat()
            guard lstat(URL.path, &information) == 0 else { return false }
            return (information.st_mode & S_IFMT) == S_IFREG
        }
    }

    struct ActivityAnalysisDayLoader {
        private static let readChunkBytes = 256 * 1_024
        private static let maximumJSONLineBytes = 2 * 1_024 * 1_024
        private static let retainedValueMarginBytes: Int64 = 256

        let rootDirectory: URL
        let limits: ActivityAnalysisDayLoadLimits

        init(
            rootDirectory: URL,
            limits: ActivityAnalysisDayLoadLimits = .production
        ) {
            self.rootDirectory = rootDirectory
            self.limits = limits
        }

        func load(day: Date) throws -> ActivityAnalysisDaySnapshot {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not calculate the end of the selected local day"
                )
            }
            let end = next
            let dayKey = ActivityAnalysisPaths.dayString(start)
            let eventURL =
                rootDirectory
                .appendingPathComponent("events", isDirectory: true)
                .appendingPathComponent(dayKey + ".jsonl")
            let semanticURL =
                rootDirectory
                .appendingPathComponent("semantic", isDirectory: true)
                .appendingPathComponent(dayKey + ".semantic.jsonl")

            var issues: [HistoryLoadIssue] = []
            var rawEventCount = 0
            var rawContinuityBoundaryCount = 0
            struct SourceIntegrityPoint {
                let sequence: UInt64
                let previousEventHash: String
                let eventRoot: String
                let eventHash: String

                init(_ integrity: EventIntegrity) {
                    sequence = integrity.sequence
                    previousEventHash = integrity.previousEventHash
                    eventRoot = integrity.eventRoot
                    eventHash = integrity.eventHash
                }
            }
            struct SourceEventBoundary {
                let timestamp: Date
                let eventID: String
                let integrity: SourceIntegrityPoint?

                init(_ event: HistoryEvent) {
                    timestamp = event.timestamp
                    eventID = event.id
                    integrity = event.integrity.map(SourceIntegrityPoint.init)
                }

                static func precedes(_ left: Self, _ right: Self) -> Bool {
                    if left.timestamp == right.timestamp { return left.eventID < right.eventID }
                    return left.timestamp < right.timestamp
                }
            }
            var firstRawEvent: SourceEventBoundary?
            var lastRawEvent: SourceEventBoundary?
            var previousPhysicalEvent: SourceEventBoundary?
            var sourceTailIsValid = true
            var retainedRowCount = 0
            var estimatedRetainedBytes: Int64 = 0
            let retainedValueEncoder = Self.makeEncoder()

            func reserveRetainedValue<T: Encodable>(_ value: T) throws {
                let valueBytes = try Self.estimatedRetainedBytes(
                    for: value,
                    encoder: retainedValueEncoder
                )
                guard retainedRowCount < limits.maximumRetainedRows,
                    valueBytes <= limits.maximumEstimatedRetainedBytes - estimatedRetainedBytes
                else {
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Derived analysis kept the last-known-good views because the "
                            + "retained-evidence budget was exceeded "
                            + "(\(limits.maximumRetainedRows) rows or "
                            + "\(limits.maximumEstimatedRetainedBytes) estimated bytes)"
                    )
                }
                retainedRowCount += 1
                estimatedRetainedBytes += valueBytes
            }

            let eventResult: ([HistoryEvent], Int64, String) = try readJSONLines(
                HistoryEvent.self,
                at: eventURL,
                start: start,
                end: end,
                timestamp: { $0.timestamp },
                include: { $0.isDerivedAnalysisEvidence },
                observe: { event in
                    let boundary = SourceEventBoundary(event)
                    guard event.timestamp >= start, event.timestamp < end else {
                        sourceTailIsValid = false
                        return
                    }
                    rawEventCount += 1
                    if event.isObservationContinuityBoundary {
                        rawContinuityBoundaryCount += 1
                    }
                    if let first = firstRawEvent {
                        if SourceEventBoundary.precedes(boundary, first) {
                            firstRawEvent = boundary
                        }
                    } else {
                        firstRawEvent = boundary
                    }
                    if let last = lastRawEvent {
                        if SourceEventBoundary.precedes(last, boundary) {
                            lastRawEvent = boundary
                        }
                    } else {
                        lastRawEvent = boundary
                    }
                    guard let integrity = event.integrity else {
                        sourceTailIsValid = false
                        previousPhysicalEvent = boundary
                        return
                    }
                    guard
                        ChainHash.event(
                            sequence: integrity.sequence,
                            previous: integrity.previousEventHash,
                            eventRoot: integrity.eventRoot
                        ) == integrity.eventHash
                    else {
                        sourceTailIsValid = false
                        previousPhysicalEvent = boundary
                        return
                    }
                    if let previous = previousPhysicalEvent {
                        if SourceEventBoundary.precedes(boundary, previous) {
                            sourceTailIsValid = false
                        }
                        guard let previousIntegrity = previous.integrity else {
                            sourceTailIsValid = false
                            previousPhysicalEvent = boundary
                            return
                        }
                        let nextSequence = previousIntegrity.sequence.addingReportingOverflow(1)
                        guard !nextSequence.overflow,
                            integrity.sequence == nextSequence.partialValue,
                            integrity.previousEventHash == previousIntegrity.eventHash
                        else {
                            sourceTailIsValid = false
                            previousPhysicalEvent = boundary
                            return
                        }
                    }
                    previousPhysicalEvent = boundary
                },
                transform: { $0.compactedForDerivedAnalysis },
                retain: { event in
                    try reserveRetainedValue(event)
                    return true
                },
                issues: &issues
            )

            let referencedSemanticIDs = Set(
                eventResult.0.compactMap { event -> String? in
                    guard event.suppressionReason == nil,
                        !event.isObservationContinuityBoundary
                    else { return nil }
                    return event.semanticContext?.snapshotID
                }
            )

            var semanticSnapshots: [String: SemanticContextPayload] = [:]
            let semanticResult: (Int64, String?)
            if Self.fileExistsWithoutFollowingSymlinks(semanticURL) {
                let loaded: ([SemanticContextPayload], Int64, String) = try readJSONLines(
                    SemanticContextPayload.self,
                    at: semanticURL,
                    start: start,
                    end: end,
                    timestamp: { $0.capturedAt },
                    include: { referencedSemanticIDs.contains($0.id) },
                    observe: { _ in },
                    retain: { payload in
                        if let existing = semanticSnapshots[payload.id] {
                            guard existing == payload else {
                                throw ActivityAnalysisCycleError.sourceInaccessible(
                                    "Derived analysis kept the last-known-good views because "
                                        + "referenced semantic snapshots contained conflicting "
                                        + "duplicate identifiers"
                                )
                            }
                            return false
                        }
                        try reserveRetainedValue(payload)
                        semanticSnapshots[payload.id] = payload
                        return false
                    },
                    issues: &issues
                )
                semanticResult = (loaded.1, loaded.2)
            } else {
                semanticResult = (0, nil)
            }
            let digestMaterial = [
                "events:\(eventResult.2)",
                "semantic:\(semanticResult.1 ?? "absent")",
            ].joined(separator: "\n")
            let sourceJournalSummary = ComputerHistorySourceJournalSummary(
                eventCount: rawEventCount,
                continuityBoundaryCount: rawContinuityBoundaryCount,
                firstSourceSequence: firstRawEvent?.integrity?.sequence,
                lastSourceSequence: lastRawEvent?.integrity?.sequence,
                lastSourceEventHash: lastRawEvent?.integrity?.eventHash
            )
            let sourceTail =
                issues.isEmpty && sourceTailIsValid
                ? ActivityAnalysisSourceTail(
                    eventCount: rawEventCount,
                    continuityBoundaryCount: rawContinuityBoundaryCount,
                    firstSourceSequence: sourceJournalSummary.firstSourceSequence,
                    lastSourceSequence: sourceJournalSummary.lastSourceSequence,
                    lastSourceEventHash: sourceJournalSummary.lastSourceEventHash,
                    lastEventTimestamp: lastRawEvent?.timestamp,
                    lastEventID: lastRawEvent?.eventID,
                    endedWithNewline: try Self.fileEndsWithNewline(eventURL)
                )
                : nil

            return ActivityAnalysisDaySnapshot(
                events: eventResult.0.sorted(by: Self.eventOrder),
                sourceJournalSummary: sourceJournalSummary,
                sourceTail: sourceTail,
                semanticSnapshots: semanticSnapshots,
                issues: issues,
                bytesRead: eventResult.1 + semanticResult.0,
                contentDigest: SHA256Digest.hashHex(digestMaterial)
            )
        }

        /// Reads only bytes appended after a previously verified journal revision.
        ///
        /// This deliberately accepts the narrow case where every appended row is
        /// integrity-chained recorder bookkeeping that all derived engines exclude.
        /// Any evidence row, discontinuity, malformed line, replacement, truncation,
        /// semantic change, or concurrent write returns `nil` so the coordinator can
        /// fall back to the exact full-day rebuild.
        fileprivate func loadMaintenanceSuffix(
            day: Date,
            from previous: ActivityAnalysisSourceRevision,
            to current: ActivityAnalysisSourceRevision,
            priorTail: ActivityAnalysisSourceTail
        ) throws -> ActivityAnalysisMaintenanceSuffix? {
            guard previous.processingKey == current.processingKey,
                previous.semantic == current.semantic,
                previous.event.device == current.event.device,
                previous.event.inode == current.event.inode,
                current.event.size > previous.event.size,
                previous.event.size > 0,
                priorTail.eventCount > 0,
                priorTail.endedWithNewline,
                let priorSequence = priorTail.lastSourceSequence,
                let priorHash = priorTail.lastSourceEventHash,
                let priorTimestamp = priorTail.lastEventTimestamp,
                let priorID = priorTail.lastEventID
            else { return nil }

            let calendar = Calendar.current
            let start = calendar.startOfDay(for: day)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not calculate the end of the selected local day"
                )
            }
            let dayKey = ActivityAnalysisPaths.dayString(start)
            let eventURL =
                rootDirectory
                .appendingPathComponent("events", isDirectory: true)
                .appendingPathComponent(dayKey + ".jsonl")
            let descriptor = Darwin.open(eventURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not open \(eventURL.path) read-only without following links: "
                        + String(cString: strerror(errno))
                )
            }
            defer { Darwin.close(descriptor) }

            var initialInformation = stat()
            guard Darwin.fstat(descriptor, &initialInformation) == 0,
                (initialInformation.st_mode & S_IFMT) == S_IFREG,
                Self.fileStamp(initialInformation) == current.event
            else {
                throw ActivityAnalysisCycleError.sourceChangedDuringRead
            }

            var boundaryByte: UInt8 = 0
            guard
                Darwin.pread(
                    descriptor,
                    &boundaryByte,
                    1,
                    off_t(previous.event.size - 1)
                ) == 1,
                boundaryByte == 0x0A,
                Darwin.lseek(descriptor, off_t(previous.event.size), SEEK_SET)
                    == off_t(previous.event.size)
            else { return nil }

            let decoder = Self.makeDecoder()
            var hasher = CryptoKit.SHA256()
            var buffer = Data()
            buffer.reserveCapacity(Self.readChunkBytes * 2)
            var scratch = [UInt8](repeating: 0, count: Self.readChunkBytes)
            var bytesRead: Int64 = 0
            var appendedEventCount = 0
            var lastSequence = priorSequence
            var lastHash = priorHash
            var lastTimestamp = priorTimestamp
            var lastID = priorID

            while true {
                let readCount = scratch.withUnsafeMutableBytes { bytes -> Int in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Could not read appended bytes from \(eventURL.path): "
                            + String(cString: strerror(errno))
                    )
                }
                if readCount == 0 { break }

                let chunk = Data(scratch.prefix(readCount))
                bytesRead += Int64(readCount)
                hasher.update(data: chunk)
                buffer.append(chunk)

                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineByteCount = buffer.distance(from: buffer.startIndex, to: newline)
                    guard lineByteCount <= Self.maximumJSONLineBytes else {
                        throw ActivityAnalysisCycleError.oversizedJSONLine(
                            path: eventURL.path,
                            maximumBytes: Self.maximumJSONLineBytes
                        )
                    }
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty else { continue }
                    guard let event = try? decoder.decode(HistoryEvent.self, from: line),
                        event.timestamp >= start,
                        event.timestamp < end,
                        !event.isDerivedAnalysisEvidence,
                        event.timestamp > lastTimestamp
                            || (event.timestamp == lastTimestamp && event.id >= lastID),
                        let integrity = event.integrity
                    else { return nil }
                    let nextSequence = lastSequence.addingReportingOverflow(1)
                    guard !nextSequence.overflow,
                        integrity.sequence == nextSequence.partialValue,
                        integrity.previousEventHash == lastHash,
                        ChainHash.event(
                            sequence: integrity.sequence,
                            previous: integrity.previousEventHash,
                            eventRoot: integrity.eventRoot
                        ) == integrity.eventHash
                    else { return nil }
                    appendedEventCount += 1
                    lastSequence = integrity.sequence
                    lastHash = integrity.eventHash
                    lastTimestamp = event.timestamp
                    lastID = event.id
                }

                guard buffer.count <= Self.maximumJSONLineBytes else {
                    throw ActivityAnalysisCycleError.oversizedJSONLine(
                        path: eventURL.path,
                        maximumBytes: Self.maximumJSONLineBytes
                    )
                }
            }

            guard buffer.isEmpty,
                bytesRead == current.event.size - previous.event.size
            else { return nil }
            var finalInformation = stat()
            guard Darwin.fstat(descriptor, &finalInformation) == 0,
                Self.fileStamp(finalInformation) == current.event
            else {
                throw ActivityAnalysisCycleError.sourceChangedDuringRead
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return ActivityAnalysisMaintenanceSuffix(
                sourceTail: ActivityAnalysisSourceTail(
                    eventCount: priorTail.eventCount + appendedEventCount,
                    continuityBoundaryCount: priorTail.continuityBoundaryCount,
                    firstSourceSequence: priorTail.firstSourceSequence,
                    lastSourceSequence: lastSequence,
                    lastSourceEventHash: lastHash,
                    lastEventTimestamp: lastTimestamp,
                    lastEventID: lastID,
                    endedWithNewline: true
                ),
                bytesRead: bytesRead,
                contentDigest: digest
            )
        }

        private func readJSONLines<T: Decodable>(
            _ type: T.Type,
            at URL: URL,
            start: Date,
            end: Date,
            timestamp: (T) -> Date,
            include: (T) -> Bool,
            observe: (T) -> Void,
            transform: (T) -> T = { $0 },
            retain: (T) throws -> Bool = { _ in true },
            issues: inout [HistoryLoadIssue]
        ) throws -> ([T], Int64, String) {
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: URL)
            } catch {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not open \(URL.path) read-only: \(error)"
                )
            }
            defer { try? handle.close() }

            let decoder = Self.makeDecoder()
            var hasher = CryptoKit.SHA256()
            var buffer = Data()
            buffer.reserveCapacity(Self.readChunkBytes * 2)
            var output: [T] = []
            var bytesRead: Int64 = 0
            var lineNumber = 0

            while let chunk = try handle.read(upToCount: Self.readChunkBytes), !chunk.isEmpty {
                bytesRead += Int64(chunk.count)
                hasher.update(data: chunk)
                buffer.append(chunk)

                while let newline = buffer.firstIndex(of: 0x0A) {
                    lineNumber += 1
                    let lineByteCount = buffer.distance(from: buffer.startIndex, to: newline)
                    guard lineByteCount <= Self.maximumJSONLineBytes else {
                        throw ActivityAnalysisCycleError.oversizedJSONLine(
                            path: URL.path,
                            maximumBytes: Self.maximumJSONLineBytes
                        )
                    }
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    try decode(
                        line,
                        lineNumber: lineNumber,
                        URL: URL,
                        decoder: decoder,
                        start: start,
                        end: end,
                        timestamp: timestamp,
                        include: include,
                        observe: observe,
                        transform: transform,
                        retain: retain,
                        output: &output,
                        issues: &issues
                    )
                }

                guard buffer.count <= Self.maximumJSONLineBytes else {
                    throw ActivityAnalysisCycleError.oversizedJSONLine(
                        path: URL.path,
                        maximumBytes: Self.maximumJSONLineBytes
                    )
                }
            }

            if !buffer.isEmpty {
                lineNumber += 1
                guard buffer.count <= Self.maximumJSONLineBytes else {
                    throw ActivityAnalysisCycleError.oversizedJSONLine(
                        path: URL.path,
                        maximumBytes: Self.maximumJSONLineBytes
                    )
                }
                try decode(
                    buffer,
                    lineNumber: lineNumber,
                    URL: URL,
                    decoder: decoder,
                    start: start,
                    end: end,
                    timestamp: timestamp,
                    include: include,
                    observe: observe,
                    transform: transform,
                    retain: retain,
                    output: &output,
                    issues: &issues
                )
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (output, bytesRead, digest)
        }

        private func decode<T: Decodable>(
            _ line: Data,
            lineNumber: Int,
            URL: URL,
            decoder: JSONDecoder,
            start: Date,
            end: Date,
            timestamp: (T) -> Date,
            include: (T) -> Bool,
            observe: (T) -> Void,
            transform: (T) -> T,
            retain: (T) throws -> Bool,
            output: inout [T],
            issues: inout [HistoryLoadIssue]
        ) throws {
            guard !line.isEmpty else { return }
            let value: T
            do {
                value = try decoder.decode(T.self, from: line)
            } catch {
                if issues.count < 256 {
                    issues.append(
                        HistoryLoadIssue(
                            path: URL.path,
                            line: lineNumber,
                            message: "Could not decode JSONL row: \(error)"
                        )
                    )
                }
                return
            }
            observe(value)
            let date = timestamp(value)
            guard date >= start, date < end else { return }
            guard include(value) else { return }
            let transformed = transform(value)
            guard try retain(transformed) else { return }
            output.append(transformed)
        }

        static func estimatedRetainedBytes<T: Encodable>(
            for value: T,
            encoder: JSONEncoder? = nil
        ) throws -> Int64 {
            let encoder = encoder ?? makeEncoder()
            return Int64(try encoder.encode(value).count)
                + Int64(MemoryLayout<T>.stride)
                + retainedValueMarginBytes
        }

        private static func fileExistsWithoutFollowingSymlinks(_ URL: URL) -> Bool {
            var information = stat()
            guard lstat(URL.path, &information) == 0 else { return false }
            return (information.st_mode & S_IFMT) == S_IFREG
        }

        private static func fileEndsWithNewline(_ URL: URL) throws -> Bool {
            let descriptor = Darwin.open(URL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not open \(URL.path) read-only without following links: "
                        + String(cString: strerror(errno))
                )
            }
            defer { Darwin.close(descriptor) }
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0,
                (information.st_mode & S_IFMT) == S_IFREG
            else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not inspect \(URL.path) through its read-only descriptor"
                )
            }
            guard information.st_size > 0 else { return true }
            var byte: UInt8 = 0
            guard Darwin.pread(descriptor, &byte, 1, information.st_size - 1) == 1 else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not inspect the final byte of \(URL.path)"
                )
            }
            return byte == 0x0A
        }

        private static func fileStamp(_ information: stat) -> ActivityAnalysisFileStamp {
            ActivityAnalysisFileStamp(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                size: Int64(information.st_size),
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec)
            )
        }

        private static func eventOrder(_ left: HistoryEvent, _ right: HistoryEvent) -> Bool {
            if left.timestamp == right.timestamp { return left.id < right.id }
            return left.timestamp < right.timestamp
        }

        private static func makeDecoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { value in
                let container = try value.singleValueContainer()
                let raw = try container.decode(String.self)
                if let date = fractionalISO.date(from: raw) ?? basicISO.date(from: raw) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 timestamp: \(raw)"
                )
            }
            return decoder
        }

        private static func makeEncoder() -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }

        private static let fractionalISO: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private static let basicISO: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    }

    private struct ActivityAnalysisDerivedWriter {
        let rootDirectory: URL
        let fileManager: FileManager

        init(rootDirectory: URL, fileManager: FileManager = .default) {
            self.rootDirectory = rootDirectory
            self.fileManager = fileManager
        }

        func writeAnalysisIfChanged(_ analysis: ActivityDayAnalysis, dayKey: String) throws -> Bool {
            let directory = rootDirectory.appendingPathComponent("analysis", isDirectory: true)
            try prepareDirectory(directory)
            let JSONURL = directory.appendingPathComponent(dayKey + ".analysis.json")
            let markdownURL = directory.appendingPathComponent(dayKey + ".agent.md")
            let encoded = try Self.encode(analysis)

            if Self.hasSameAnalysisJSON(existingAt: JSONURL, as: encoded),
                Self.isRegularFile(markdownURL)
            {
                secure([JSONURL, markdownURL])
                return false
            }

            try write(encoded, to: JSONURL)
            try write(Data(analysis.agentMarkdown.utf8), to: markdownURL)
            return true
        }

        func writeMemoryIfChanged(_ memory: ActivityMemory, dayKey: String) throws -> Bool {
            let directory = rootDirectory.appendingPathComponent("memories", isDirectory: true)
            try prepareDirectory(directory)
            let JSONURL = directory.appendingPathComponent(dayKey + ".memory.json")
            let markdownURL = directory.appendingPathComponent(dayKey + ".memory.md")
            let encoded = try Self.encode(memory)

            if Self.hasSameMemoryJSON(existingAt: JSONURL, as: encoded),
                Self.isRegularFile(markdownURL)
            {
                secure([JSONURL, markdownURL])
                return false
            }

            try write(encoded, to: JSONURL)
            try write(Data(ActivityMemoryMarkdownRenderer.render(memory).utf8), to: markdownURL)
            return true
        }

        private func prepareDirectory(_ directory: URL) throws {
            var information = stat()
            if lstat(directory.path, &information) == 0 {
                guard (information.st_mode & S_IFMT) == S_IFDIR else {
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Refused non-directory derived storage path \(directory.path)"
                    )
                }
            } else if errno == ENOENT {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not inspect derived storage directory \(directory.path): \(String(cString: strerror(errno)))"
                )
            }
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        private func write(_ data: Data, to URL: URL) throws {
            var information = stat()
            let status = lstat(URL.path, &information)
            if status == 0 {
                guard (information.st_mode & S_IFMT) == S_IFREG else {
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Refused non-regular derived output \(URL.path)"
                    )
                }
            } else if errno != ENOENT {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not inspect derived output \(URL.path): \(String(cString: strerror(errno)))"
                )
            }
            try GoalongOwnedAtomicFileWriter.write(data, to: URL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: URL.path)
        }

        private func secure(_ URLs: [URL]) {
            for URL in URLs {
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: URL.path)
            }
        }

        private static func encode<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        }

        private static func hasSameAnalysisJSON(existingAt URL: URL, as candidate: Data) -> Bool {
            guard let existing = safeData(at: URL) else { return false }
            return normalizedJSONDigest(existing, kind: .analysis)
                == normalizedJSONDigest(candidate, kind: .analysis)
        }

        private static func hasSameMemoryJSON(existingAt URL: URL, as candidate: Data) -> Bool {
            guard let existing = safeData(at: URL) else { return false }
            return normalizedJSONDigest(existing, kind: .memory)
                == normalizedJSONDigest(candidate, kind: .memory)
        }

        private enum JSONKind {
            case analysis
            case memory
        }

        private static func normalizedJSONDigest(_ data: Data, kind: JSONKind) -> String? {
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            object.removeValue(forKey: "generatedAt")
            if kind == .memory {
                object.removeValue(forKey: "id")
                for key in [
                    "significantActions", "observedRequestsOrIntentions", "unknowns", "claims",
                ] {
                    if let rows = object[key] as? [[String: Any]] {
                        object[key] = rows.map(Self.removingRootID)
                    }
                }
                if let outcome = object["observableOutcome"] as? [String: Any] {
                    object["observableOutcome"] = removingRootID(outcome)
                }
                if var coverage = object["coverage"] as? [String: Any],
                    let gaps = coverage["gaps"] as? [[String: Any]]
                {
                    coverage["gaps"] = gaps.map(Self.removingRootID)
                    object["coverage"] = coverage
                }
            }
            guard
                let normalized = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            else { return nil }
            return SHA256Digest.hashHex(normalized)
        }

        private static func removingRootID(_ value: [String: Any]) -> [String: Any] {
            var output = value
            output.removeValue(forKey: "id")
            return output
        }

        private static func safeData(at URL: URL) -> Data? {
            guard isRegularFile(URL),
                let values = try? URL.resourceValues(forKeys: [.fileSizeKey]),
                let size = values.fileSize,
                size >= 0,
                size <= 128 * 1_024 * 1_024
            else { return nil }
            return try? Data(contentsOf: URL, options: [.mappedIfSafe])
        }

        private static func isRegularFile(_ URL: URL) -> Bool {
            var information = stat()
            guard lstat(URL.path, &information) == 0 else { return false }
            return (information.st_mode & S_IFMT) == S_IFREG
        }
    }

    /// Coordinates one day of derived analysis. The implementation lives beside the
    /// runtime so every background trigger shares the same serialization and cache.
    final class ActivityAnalysisCycleCoordinator {
        private static let maximumPriorComputerHistoryDays = 30
        /// Codex produces ten-minute activity memories. Matching that cadence keeps
        /// the active journal fresh without rereading an ever-growing day once per
        /// minute. Explicit user refreshes bypass this background debounce.
        private static let minimumBackgroundRefreshInterval =
            ActivityAnalysisRuntime.backgroundRefreshInterval

        private let rootDirectory: URL
        private let computerHistoryStore: ComputerHistoryStore
        private let fileManager: FileManager
        private let engineRevision: String
        private let loader: ActivityAnalysisDayLoader
        private let writer: ActivityAnalysisDerivedWriter
        private let cache: ActivityAnalysisRevisionCache
        private let priorRevisionLimits: ActivityAnalysisPriorRevisionLimits
        private let monotonicNow: () -> TimeInterval
        private let priorRevisionLock = NSLock()
        private var priorRevisionCache: [String: PriorRevisionCacheEntry] = [:]
        private var priorRevisionCacheOrder: [String] = []
        private var priorRevisionDiagnostics = ActivityAnalysisPriorRevisionDiagnostics(
            scannedEntryCount: 0,
            peakRetainedCandidateCount: 0,
            selectedNames: [],
            usedCachedDirectoryRevision: false
        )

        private struct PriorRevisionCandidate: Equatable {
            let name: String
            let stamp: ActivityAnalysisFileStamp
        }

        private struct PriorRevisionCacheEntry {
            let directoryStamp: PriorDirectoryStamp
            let candidates: [PriorRevisionCandidate]
            let digest: String
        }

        private struct PriorDirectoryStamp: Equatable {
            let device: UInt64
            let inode: UInt64
            let size: Int64
            let modificationSeconds: Int64
            let modificationNanoseconds: Int64
            let changeSeconds: Int64
            let changeNanoseconds: Int64
        }

        init(
            rootDirectory: URL,
            computerHistoryStore: ComputerHistoryStore,
            fileManager: FileManager = .default,
            engineRevision: String? = nil,
            dayLoadLimits: ActivityAnalysisDayLoadLimits = .production,
            priorRevisionLimits: ActivityAnalysisPriorRevisionLimits = .production,
            monotonicNow: @escaping () -> TimeInterval = {
                ProcessInfo.processInfo.systemUptime
            }
        ) {
            self.rootDirectory = rootDirectory.standardizedFileURL
            self.computerHistoryStore = computerHistoryStore
            self.fileManager = fileManager
            self.engineRevision = engineRevision ?? Self.defaultEngineRevision()
            self.priorRevisionLimits = ActivityAnalysisPriorRevisionLimits(
                maximumDirectoryEntries: max(1, priorRevisionLimits.maximumDirectoryEntries),
                maximumScanDuration: max(0.001, priorRevisionLimits.maximumScanDuration)
            )
            self.monotonicNow = monotonicNow
            loader = ActivityAnalysisDayLoader(
                rootDirectory: rootDirectory.standardizedFileURL,
                limits: dayLoadLimits
            )
            writer = ActivityAnalysisDerivedWriter(
                rootDirectory: rootDirectory.standardizedFileURL,
                fileManager: fileManager
            )
            cache = ActivityAnalysisRevisionCache(
                rootDirectory: rootDirectory.standardizedFileURL,
                fileManager: fileManager
            )
        }

        func retainCacheEntries(for days: [Date]) {
            let keys = Set(days.map(ActivityAnalysisPaths.dayString))
            do {
                try cache.retain(keys: keys)
            } catch {
                Diagnostics.write("Could not prune bounded activity-analysis cache: \(error)")
            }
            priorRevisionLock.lock()
            priorRevisionCache = priorRevisionCache.filter { keys.contains($0.key) }
            priorRevisionCacheOrder.removeAll { !keys.contains($0) }
            priorRevisionLock.unlock()
        }

        func invalidateRevisionCache() throws {
            try cache.removeAll()
            priorRevisionLock.lock()
            priorRevisionCache.removeAll(keepingCapacity: false)
            priorRevisionCacheOrder.removeAll(keepingCapacity: false)
            priorRevisionLock.unlock()
        }

        var priorRevisionDiagnosticsForTesting: ActivityAnalysisPriorRevisionDiagnostics {
            priorRevisionLock.lock()
            defer { priorRevisionLock.unlock() }
            return priorRevisionDiagnostics
        }

        func process(
            day: Date,
            tokenBudget: Int,
            forceVerification: Bool,
            includeActivityMemory: Bool
        ) throws -> ActivityAnalysisCycleResult {
            // `forceVerification` still accepts an exact cache hit, but it bypasses
            // the append-only background debounce when source bytes changed.
            let start = Calendar.current.startOfDay(for: day)
            let dayKey = ActivityAnalysisPaths.dayString(start)
            let currentProbe = probe(day: start, tokenBudget: tokenBudget)
            let revision: ActivityAnalysisSourceRevision
            switch currentProbe {
            case .absent:
                try cache.removeValue(for: dayKey)
                return ActivityAnalysisCycleResult(
                    sourceAbsent: true,
                    issues: [],
                    sourceBytesRead: 0,
                    sourceReadPasses: 0,
                    derivedViewsWritten: 0,
                    usedCachedRevision: false
                )
            case .inaccessible(let message):
                throw ActivityAnalysisCycleError.sourceInaccessible(message)
            case .available(let value):
                revision = value
            }

            let cached = cache.entry(for: dayKey)
            if let cached,
                cached.revision == revision,
                Self.cacheEntry(cached, coversMemory: includeActivityMemory),
                cache.outputsMatch(
                    cached,
                    rootDirectory: rootDirectory,
                    dayKey: dayKey
                )
            {
                return ActivityAnalysisCycleResult(
                    sourceAbsent: false,
                    issues: [],
                    sourceBytesRead: 0,
                    sourceReadPasses: 0,
                    derivedViewsWritten: 0,
                    usedCachedRevision: true
                )
            }

            if !forceVerification,
                let cached,
                Self.cacheEntry(cached, coversMemory: includeActivityMemory),
                cache.outputsMatch(
                    cached,
                    rootDirectory: rootDirectory,
                    dayKey: dayKey
                ),
                shouldDeferAppendOnlyRefresh(
                    cached: cached,
                    current: revision,
                    now: Date()
                )
            {
                guard probe(day: start, tokenBudget: tokenBudget) == .available(revision) else {
                    throw ActivityAnalysisCycleError.sourceChangedDuringRead
                }
                return ActivityAnalysisCycleResult(
                    sourceAbsent: false,
                    issues: [],
                    sourceBytesRead: 0,
                    sourceReadPasses: 0,
                    derivedViewsWritten: 0,
                    usedCachedRevision: false
                )
            }

            let priorComputerHistory: [ComputerHistoryDayMemory]
            if revision.event.size > 0 {
                let priorLoad = computerHistoryStore.loadRecent(
                    maximumDays: Self.maximumPriorComputerHistoryDays + 2
                )
                guard priorLoad.isComplete else {
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Computer History kept the last-known-good view because prior "
                            + "retained memories could not be loaded completely"
                    )
                }
                priorComputerHistory = Array(
                    priorLoad.memories.filter { $0.dayStart < start }
                        .suffix(Self.maximumPriorComputerHistoryDays)
                )
            } else {
                priorComputerHistory = []
            }

            if let cached,
                let incremental = try processMaintenanceOnlyAppend(
                    day: start,
                    dayKey: dayKey,
                    cached: cached,
                    revision: revision,
                    tokenBudget: tokenBudget,
                    includeActivityMemory: includeActivityMemory
                )
            {
                return incremental
            }

            let snapshot = try loader.load(day: start)
            guard snapshot.issues.isEmpty else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Derived analysis kept the last-known-good views because the source "
                        + "contained \(snapshot.issues.count) unreadable row(s)"
                )
            }
            guard probe(day: start, tokenBudget: tokenBudget) == .available(revision) else {
                throw ActivityAnalysisCycleError.sourceChangedDuringRead
            }

            if let cached,
                cached.sourceContentDigest == snapshot.contentDigest,
                cached.revision.processingKey == revision.processingKey,
                Self.cacheEntry(cached, coversMemory: includeActivityMemory),
                cache.outputsMatch(
                    cached,
                    rootDirectory: rootDirectory,
                    dayKey: dayKey
                )
            {
                try cache.set(
                    ActivityAnalysisRevisionCacheEntry(
                        revision: revision,
                        sourceContentDigest: cached.sourceContentDigest,
                        sourceTail: snapshot.sourceTail,
                        expectedOutputs: cached.expectedOutputs,
                        outputRevision: cached.outputRevision,
                        successfulAt: cached.successfulAt
                    ),
                    for: dayKey
                )
                return ActivityAnalysisCycleResult(
                    sourceAbsent: false,
                    issues: snapshot.issues,
                    sourceBytesRead: snapshot.bytesRead,
                    sourceReadPasses: 1,
                    derivedViewsWritten: 0,
                    usedCachedRevision: false
                )
            }

            let generatedAt = Date()
            let analysisEvents = snapshot.events.map { event in
                Self.eventByResolvingSemanticContext(
                    event,
                    semanticSnapshots: snapshot.semanticSnapshots
                )
            }
            let analysis = ActivityAnalysisEngine.analyze(
                events: analysisEvents,
                day: start,
                options: ActivityAnalysisOptions(agentTokenBudget: tokenBudget),
                generatedAt: generatedAt
            )
            var writes = try writer.writeAnalysisIfChanged(analysis, dayKey: dayKey) ? 1 : 0
            var expectedOutputs = ["analysis-json", "analysis-markdown"]

            if includeActivityMemory, !snapshot.events.isEmpty {
                let memory = try DeterministicActivitySummarizer().summarize(
                    ActivitySummaryInput(
                        events: snapshot.events,
                        intervalStart: start,
                        intervalEnd: Calendar.current.date(byAdding: .day, value: 1, to: start)?
                            .addingTimeInterval(-0.001),
                        generatedAt: generatedAt,
                        semanticSnapshots: snapshot.semanticSnapshots
                    )
                )
                if try writer.writeMemoryIfChanged(memory, dayKey: dayKey) {
                    writes += 1
                }
                expectedOutputs.append(contentsOf: ["memory-json", "memory-markdown"])
            }

            if !snapshot.events.isEmpty {
                let memory = ComputerHistoryEngine.analyze(
                    events: snapshot.events,
                    semanticSnapshots: snapshot.semanticSnapshots,
                    day: start,
                    priorMemories: priorComputerHistory,
                    sourceJournalSummary: snapshot.sourceJournalSummary,
                    generatedAt: generatedAt
                )
                let before = Self.fileStampIfRegular(at: computerHistoryJSONURL(dayKey: dayKey))
                _ = try computerHistoryStore.write(memory, for: start)
                let after = Self.fileStampIfRegular(at: computerHistoryJSONURL(dayKey: dayKey))
                if before != after { writes += 1 }
                expectedOutputs.append("computer-history-json")
            }

            guard
                let outputRevision = cache.outputRevision(
                    expectedOutputs,
                    rootDirectory: rootDirectory,
                    dayKey: dayKey
                )
            else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not verify the derived outputs for \(dayKey)"
                )
            }
            try cache.set(
                ActivityAnalysisRevisionCacheEntry(
                    revision: revision,
                    sourceContentDigest: snapshot.contentDigest,
                    sourceTail: snapshot.sourceTail,
                    expectedOutputs: expectedOutputs,
                    outputRevision: outputRevision,
                    successfulAt: generatedAt
                ),
                for: dayKey
            )
            return ActivityAnalysisCycleResult(
                sourceAbsent: false,
                issues: snapshot.issues,
                sourceBytesRead: snapshot.bytesRead,
                sourceReadPasses: 1,
                derivedViewsWritten: writes,
                usedCachedRevision: false
            )
        }

        private func processMaintenanceOnlyAppend(
            day: Date,
            dayKey: String,
            cached: ActivityAnalysisRevisionCacheEntry,
            revision: ActivityAnalysisSourceRevision,
            tokenBudget: Int,
            includeActivityMemory: Bool
        ) throws -> ActivityAnalysisCycleResult? {
            guard let priorTail = cached.sourceTail,
                cached.expectedOutputs.contains("computer-history-json"),
                Self.cacheEntry(cached, coversMemory: includeActivityMemory),
                cache.outputsMatch(
                    cached,
                    rootDirectory: rootDirectory,
                    dayKey: dayKey
                ),
                let suffix = try loader.loadMaintenanceSuffix(
                    day: day,
                    from: cached.revision,
                    to: revision,
                    priorTail: priorTail
                ),
                probe(day: day, tokenBudget: tokenBudget) == .available(revision),
                let existing = computerHistoryStore.loadStored(for: day),
                existing.coverage.sourceEventCount == priorTail.eventCount,
                existing.coverage.suppressedEventCount == priorTail.continuityBoundaryCount,
                existing.coverage.firstSourceSequence == priorTail.firstSourceSequence,
                existing.coverage.lastSourceSequence == priorTail.lastSourceSequence,
                existing.coverage.lastSourceEventHash == priorTail.lastSourceEventHash
            else { return nil }

            let appendedEventCount = suffix.sourceTail.eventCount - priorTail.eventCount
            var writes = 0
            let generatedAt = Date()
            if appendedEventCount > 0 {
                let priorCoverage = existing.coverage
                let coverage = ComputerHistoryCoverage(
                    sourceEventCount: suffix.sourceTail.eventCount,
                    actionEventCount: priorCoverage.actionEventCount,
                    semanticSnapshotCount: priorCoverage.semanticSnapshotCount,
                    linkedInteractionCount: priorCoverage.linkedInteractionCount,
                    interactionsWithBeforeAndAfterContext:
                        priorCoverage.interactionsWithBeforeAndAfterContext,
                    resourceCount: priorCoverage.resourceCount,
                    episodeCount: priorCoverage.episodeCount,
                    suppressedEventCount: suffix.sourceTail.continuityBoundaryCount,
                    firstSourceSequence: suffix.sourceTail.firstSourceSequence,
                    lastSourceSequence: suffix.sourceTail.lastSourceSequence,
                    lastSourceEventHash: suffix.sourceTail.lastSourceEventHash,
                    retainedEpisodeCount: priorCoverage.retainedEpisodeCount,
                    retainedInteractionCount: priorCoverage.retainedInteractionCount,
                    retainedResourceCount: priorCoverage.retainedResourceCount
                )
                let base = ComputerHistoryDayMemory(
                    schemaVersion: existing.schemaVersion,
                    dayStart: existing.dayStart,
                    dayEnd: existing.dayEnd,
                    generatedAt: generatedAt,
                    title: existing.title,
                    executiveSummary: existing.executiveSummary,
                    episodes: existing.episodes,
                    resources: existing.resources,
                    workflowPatterns: existing.workflowPatterns,
                    suggestions: existing.suggestions,
                    coverage: coverage,
                    markdown: "",
                    securityNotice: existing.securityNotice
                )
                let updated = ComputerHistoryDayMemory(
                    schemaVersion: base.schemaVersion,
                    dayStart: base.dayStart,
                    dayEnd: base.dayEnd,
                    generatedAt: base.generatedAt,
                    title: base.title,
                    executiveSummary: base.executiveSummary,
                    episodes: base.episodes,
                    resources: base.resources,
                    workflowPatterns: base.workflowPatterns,
                    suggestions: base.suggestions,
                    coverage: base.coverage,
                    markdown: ComputerHistoryMarkdownRenderer.render(base),
                    securityNotice: base.securityNotice
                )
                let before = Self.fileStampIfRegular(at: computerHistoryJSONURL(dayKey: dayKey))
                _ = try computerHistoryStore.write(updated, for: day)
                let after = Self.fileStampIfRegular(at: computerHistoryJSONURL(dayKey: dayKey))
                if before != after { writes = 1 }
            }

            guard
                let outputRevision = cache.outputRevision(
                    cached.expectedOutputs,
                    rootDirectory: rootDirectory,
                    dayKey: dayKey
                )
            else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not verify the derived outputs for \(dayKey)"
                )
            }
            let digest = SHA256Digest.hashHex(
                "maintenance-append-v1\0\(cached.sourceContentDigest)\0\(suffix.contentDigest)"
            )
            try cache.set(
                ActivityAnalysisRevisionCacheEntry(
                    revision: revision,
                    sourceContentDigest: digest,
                    sourceTail: suffix.sourceTail,
                    expectedOutputs: cached.expectedOutputs,
                    outputRevision: outputRevision,
                    successfulAt: generatedAt
                ),
                for: dayKey
            )
            return ActivityAnalysisCycleResult(
                sourceAbsent: false,
                issues: [],
                sourceBytesRead: suffix.bytesRead,
                sourceReadPasses: 1,
                derivedViewsWritten: writes,
                usedCachedRevision: false
            )
        }

        private func shouldDeferAppendOnlyRefresh(
            cached: ActivityAnalysisRevisionCacheEntry,
            current: ActivityAnalysisSourceRevision,
            now: Date
        ) -> Bool {
            let elapsed = now.timeIntervalSince(cached.successfulAt)
            guard elapsed >= 0,
                elapsed < Self.minimumBackgroundRefreshInterval,
                cached.revision.processingKey == current.processingKey,
                Self.isAppendOnlyAdvance(from: cached.revision.event, to: current.event),
                Self.isAppendOnlyAdvance(from: cached.revision.semantic, to: current.semantic),
                current != cached.revision
            else { return false }
            return true
        }

        private static func isAppendOnlyAdvance(
            from previous: ActivityAnalysisFileStamp?,
            to current: ActivityAnalysisFileStamp?
        ) -> Bool {
            switch (previous, current) {
            case (nil, nil):
                return true
            case (nil, let current?):
                return current.size >= 0
            case (let previous?, let current?):
                return previous.device == current.device
                    && previous.inode == current.inode
                    && current.size >= previous.size
            case (_?, nil):
                return false
            }
        }

        private static func cacheEntry(
            _ entry: ActivityAnalysisRevisionCacheEntry,
            coversMemory: Bool
        ) -> Bool {
            !coversMemory
                || (entry.expectedOutputs.contains("memory-json")
                    && entry.expectedOutputs.contains("memory-markdown"))
        }

        func probe(day: Date, tokenBudget: Int) -> ActivityAnalysisSourceProbe {
            let start = Calendar.current.startOfDay(for: day)
            let dayKey = ActivityAnalysisPaths.dayString(start)
            let eventURL =
                rootDirectory
                .appendingPathComponent("events", isDirectory: true)
                .appendingPathComponent(dayKey + ".jsonl")
            let semanticURL =
                rootDirectory
                .appendingPathComponent("semantic", isDirectory: true)
                .appendingPathComponent(dayKey + ".semantic.jsonl")

            do {
                guard let event = try Self.fileStamp(at: eventURL) else { return .absent }
                let semantic = try Self.fileStamp(at: semanticURL)
                let prior = try priorComputerHistoryRevision(before: dayKey)
                let timezone = Calendar.current.timeZone
                let processingMaterial = [
                    "engine=\(engineRevision)",
                    "token_budget=\(tokenBudget)",
                    "timezone=\(timezone.identifier)",
                    "utc_offset=\(timezone.secondsFromGMT(for: start))",
                    "prior_computer_history=\(prior)",
                ].joined(separator: "\n")
                return .available(
                    ActivityAnalysisSourceRevision(
                        event: event,
                        semantic: semantic,
                        processingKey: SHA256Digest.hashHex(processingMaterial)
                    )
                )
            } catch {
                return .inaccessible(String(describing: error))
            }
        }

        private func priorComputerHistoryRevision(before dayKey: String) throws -> String {
            let directory = rootDirectory.appendingPathComponent("computer-history", isDirectory: true)
            priorRevisionLock.lock()
            defer { priorRevisionLock.unlock() }

            guard let directoryStamp = try Self.directoryStamp(at: directory) else {
                priorRevisionCache.removeValue(forKey: dayKey)
                priorRevisionCacheOrder.removeAll { $0 == dayKey }
                priorRevisionDiagnostics = ActivityAnalysisPriorRevisionDiagnostics(
                    scannedEntryCount: 0,
                    peakRetainedCandidateCount: 0,
                    selectedNames: [],
                    usedCachedDirectoryRevision: false
                )
                return SHA256Digest.hashHex("")
            }

            if let cached = priorRevisionCache[dayKey],
                cached.directoryStamp == directoryStamp,
                try cached.candidates.allSatisfy({ candidate in
                    try Self.fileStamp(
                        at: directory.appendingPathComponent(candidate.name)
                    ) == candidate.stamp
                }),
                try Self.directoryStamp(at: directory) == directoryStamp
            {
                touchPriorRevisionCacheKey(dayKey)
                priorRevisionDiagnostics = ActivityAnalysisPriorRevisionDiagnostics(
                    scannedEntryCount: 0,
                    peakRetainedCandidateCount: cached.candidates.count,
                    selectedNames: cached.candidates.map(\.name),
                    usedCachedDirectoryRevision: true
                )
                return cached.digest
            }

            let suffix = ".computer-history.json"
            let startedAt = monotonicNow()
            var scannedEntryCount = 0
            var candidates: [(name: String, URL: URL)] = []
            var enumerationError: Error?
            guard
                let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants],
                    errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }
                )
            else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not enumerate prior Computer History at \(directory.path)"
                )
            }

            while let candidateURL = enumerator.nextObject() as? URL {
                scannedEntryCount += 1
                guard scannedEntryCount <= priorRevisionLimits.maximumDirectoryEntries else {
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Prior Computer History at \(directory.path) exceeded "
                            + "\(priorRevisionLimits.maximumDirectoryEntries) entries"
                    )
                }
                if scannedEntryCount.isMultiple(of: 128),
                    monotonicNow() - startedAt > priorRevisionLimits.maximumScanDuration
                {
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Prior Computer History at \(directory.path) exceeded its time budget"
                    )
                }

                let name = candidateURL.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                guard name.hasSuffix(suffix) else { continue }
                let sourceDay = String(name.dropLast(suffix.count))
                guard sourceDay < dayKey else { continue }
                if candidates.count < Self.maximumPriorComputerHistoryDays {
                    candidates.append((name, candidateURL))
                    candidates.sort { $0.name < $1.name }
                } else if let oldest = candidates.first, name > oldest.name {
                    candidates[0] = (name, candidateURL)
                    candidates.sort { $0.name < $1.name }
                }
            }
            if let enumerationError {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not enumerate prior Computer History at \(directory.path): \(enumerationError)"
                )
            }
            guard monotonicNow() - startedAt <= priorRevisionLimits.maximumScanDuration else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Prior Computer History at \(directory.path) exceeded its time budget"
                )
            }

            var retained: [PriorRevisionCandidate] = []
            retained.reserveCapacity(Self.maximumPriorComputerHistoryDays)
            var rows: [String] = []
            rows.reserveCapacity(Self.maximumPriorComputerHistoryDays)
            for candidate in candidates {
                guard monotonicNow() - startedAt <= priorRevisionLimits.maximumScanDuration else {
                    throw ActivityAnalysisCycleError.sourceInaccessible(
                        "Prior Computer History at \(directory.path) exceeded its time budget"
                    )
                }
                guard let stamp = try Self.fileStamp(at: candidate.URL) else {
                    throw ActivityAnalysisCycleError.sourceChangedDuringRead
                }
                retained.append(PriorRevisionCandidate(name: candidate.name, stamp: stamp))
                rows.append("\(candidate.name)|\(Self.stampDescription(stamp))")
            }
            guard try Self.directoryStamp(at: directory) == directoryStamp else {
                throw ActivityAnalysisCycleError.sourceChangedDuringRead
            }
            let digest = SHA256Digest.hashHex(rows.joined(separator: "\n"))
            priorRevisionCache[dayKey] = PriorRevisionCacheEntry(
                directoryStamp: directoryStamp,
                candidates: retained,
                digest: digest
            )
            touchPriorRevisionCacheKey(dayKey)
            while priorRevisionCacheOrder.count > 4 {
                let removed = priorRevisionCacheOrder.removeFirst()
                priorRevisionCache.removeValue(forKey: removed)
            }
            priorRevisionDiagnostics = ActivityAnalysisPriorRevisionDiagnostics(
                scannedEntryCount: scannedEntryCount,
                peakRetainedCandidateCount: candidates.count,
                selectedNames: retained.map(\.name),
                usedCachedDirectoryRevision: false
            )
            return digest
        }

        private func touchPriorRevisionCacheKey(_ key: String) {
            priorRevisionCacheOrder.removeAll { $0 == key }
            priorRevisionCacheOrder.append(key)
        }

        private func computerHistoryJSONURL(dayKey: String) -> URL {
            rootDirectory
                .appendingPathComponent("computer-history", isDirectory: true)
                .appendingPathComponent(dayKey + ".computer-history.json")
        }

        private static func eventByResolvingSemanticContext(
            _ event: HistoryEvent,
            semanticSnapshots: [String: SemanticContextPayload]
        ) -> HistoryEvent {
            guard
                let semantic = SemanticContextResolver.text(
                    for: event,
                    semanticSnapshots: semanticSnapshots
                )
            else { return event }
            var metadata = event.metadata ?? [:]
            metadata[ActivitySemanticMetadata.text] = semantic
            return HistoryEvent(
                schemaVersion: event.schemaVersion,
                id: event.id,
                sessionID: event.sessionID,
                timestamp: event.timestamp,
                kind: event.kind,
                app: event.app,
                window: event.window,
                element: event.element,
                url: event.url,
                pointer: event.pointer,
                keyboard: event.keyboard,
                scroll: event.scroll,
                inputOrigin: event.inputOrigin,
                semanticContext: event.semanticContext,
                classification: event.classification,
                suppressionReason: event.suppressionReason,
                message: event.message,
                metadata: metadata,
                integrity: event.integrity
            )
        }

        private static func fileStamp(at URL: URL) throws -> ActivityAnalysisFileStamp? {
            var information = stat()
            guard lstat(URL.path, &information) == 0 else {
                if errno == ENOENT { return nil }
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not inspect \(URL.path): \(String(cString: strerror(errno)))"
                )
            }
            guard (information.st_mode & S_IFMT) == S_IFREG else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Refused non-regular or symbolic-link source \(URL.path)"
                )
            }
            return ActivityAnalysisFileStamp(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                size: Int64(information.st_size),
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec)
            )
        }

        private static func directoryStamp(at URL: URL) throws -> PriorDirectoryStamp? {
            var information = stat()
            guard lstat(URL.path, &information) == 0 else {
                if errno == ENOENT { return nil }
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Could not inspect prior Computer History at \(URL.path): "
                        + String(cString: strerror(errno))
                )
            }
            guard (information.st_mode & S_IFMT) == S_IFDIR else {
                throw ActivityAnalysisCycleError.sourceInaccessible(
                    "Refused non-directory prior Computer History path \(URL.path)"
                )
            }
            return PriorDirectoryStamp(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                size: Int64(information.st_size),
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
                changeSeconds: Int64(information.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
            )
        }

        private static func fileStampIfRegular(at URL: URL) -> ActivityAnalysisFileStamp? {
            try? fileStamp(at: URL)
        }

        private static func stampDescription(_ value: ActivityAnalysisFileStamp) -> String {
            "\(value.device):\(value.inode):\(value.size):\(value.modificationSeconds):\(value.modificationNanoseconds)"
        }

        private static func defaultEngineRevision() -> String {
            let shortVersion =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "development"
            let buildVersion =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "development"
            return "shared-day-analysis-v1|\(shortVersion)|\(buildVersion)"
        }
    }
#endif
