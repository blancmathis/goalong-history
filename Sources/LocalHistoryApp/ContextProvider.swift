#if os(macOS)
    import AppKit
    import Carbon
    import ApplicationServices
    import Foundation
    import LocalHistoryCore

    struct BoundedIdentifierCache<Value: Hashable> {
        private let capacity: Int
        private var values = Set<Value>()
        private var accessOrder: [Value] = []

        init(capacity: Int = 64) {
            self.capacity = max(1, capacity)
        }

        mutating func insert(_ value: Value) {
            if values.contains(value) {
                accessOrder.removeAll { $0 == value }
            } else {
                values.insert(value)
            }
            accessOrder.append(value)
            while accessOrder.count > capacity {
                values.remove(accessOrder.removeFirst())
            }
        }

        func contains(_ value: Value) -> Bool {
            values.contains(value)
        }

        var count: Int { values.count }
    }

    typealias BoundedProcessIdentifierCache = BoundedIdentifierCache<Int32>

    /// Main-owned admission/publication facade. Production always uses owned AX lanes;
    /// the inline backend exists only for deterministic baseline parity fixtures.
    final class ContextProvider {
        enum Backend { case background, legacy }
        let backend: Backend
        private let historyQueue = DispatchQueue(label: "Goalong.HistoryAX", qos: .userInitiated)
        private let operations = AXContinuationQueue()
        private let presenceProbe = ForegroundActivityProbe()
        private var historyGeneration = UUID()
        private var permits: [UUID: AXRequestPermit] = [:]
        private let live: Bool
        private let parameters: () -> ContextReadParameters
        private let blockingParameters: () -> ContextReadParameters
        private let foregroundPID: () -> pid_t?
        private let applicationResolver: (pid_t) -> ForegroundAXApplication?
        private let client: AXClient
        private let historyReader: ContextAXReader
        private let blockingReader: ContextAXReader
        private let blockingLane: BlockingAXLane
        private var blockingGeneration = UUID()
        private let blockingProbe: (() -> BlockingObservation?)?
        private let privateWindowSink: (Bool) -> Void
        private(set) var lastCaptureProvedExternalAX = false
        private(set) var lastCaptureBoundary: AXReadBoundary?

        init(configManager: ConfigManager, permissions: PermissionManager,
             blockingProbe: (() -> BlockingObservation?)? = nil, client: AXClient = .system) {
            self.backend = .background
            self.live = true
            self.client = client
            self.blockingProbe = blockingProbe
            self.privateWindowSink = { JevIngress.shared.setPrivateWindow($0) }
            historyReader = ContextAXReader(clock: client.clock)
            blockingReader = ContextAXReader(clock: client.clock)
            blockingLane = BlockingAXLane(client: client)
            parameters = { Self.liveParameters(config: configManager.config, accessibility: permissions.currentStatus.accessibility, history: true, permissionRevision: permissions.observationRevision) }
            blockingParameters = { Self.liveParameters(config: configManager.config, accessibility: false, history: false) }
            foregroundPID = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            applicationResolver = { NSRunningApplication(processIdentifier: $0).map(ForegroundAXApplication.init) }
        }

        /// Fixture injection avoids AppKit, permission probes and user storage.
        init(client: AXClient, backend: Backend = .background, parameters: @escaping () -> ContextReadParameters,
             privateWindowSink: @escaping (Bool) -> Void = { _ in },
             applicationResolver: @escaping (pid_t) -> ForegroundAXApplication? = { _ in nil }) {
            self.backend = backend
            self.live = false
            self.client = client
            self.parameters = parameters
            self.blockingParameters = parameters
            self.foregroundPID = { parameters().foregroundApplication?.processIdentifier }
            self.applicationResolver = applicationResolver
            self.privateWindowSink = privateWindowSink
            self.blockingProbe = nil
            historyReader = ContextAXReader(clock: client.clock)
            blockingReader = ContextAXReader(clock: client.clock)
            blockingLane = BlockingAXLane(client: client)
        }

        var historyPrivacyStopped: Bool {
            GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory).blocked
        }

        private static func liveParameters(config: RecorderConfig, accessibility: Bool, history: Bool, permissionRevision: UInt64 = 0) -> ContextReadParameters {
            let applications = history ? NSWorkspace.shared.runningApplications.map(ForegroundAXApplication.init) : []
            let front = NSWorkspace.shared.frontmostApplication.map(ForegroundAXApplication.init)
            var catalogue = Dictionary(applications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { _, new in new })
            if let front { catalogue[front.processIdentifier] = front }
            var emptyPolicy = GoalongPrivacyPolicy(); emptyPolicy.revision = "none"
            return ContextReadParameters(foregroundApplication: front, applications: catalogue,
                config: config, accessibilityAvailable: accessibility,
                blockingAXTrusted: history ? false : AXIsProcessTrusted(), sessionAvailable: ForegroundSessionAvailability.isAvailable(),
                idleSeconds: UserInputActivityClock.secondsSinceLastInput(),
                privacy: history ? GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory) : emptyPolicy,
                pauseRevision: history ? try? GoalongGlobalPause.admit() : nil,
                secureInputEnabled: IsSecureEventInputEnabled(), permissionRevision: permissionRevision)
        }

        var rejectedRequestCount: Int { operations.rejectedCount }

        func invalidateHistory() {
            historyGeneration = UUID()
            lastCaptureBoundary = nil
            for permit in permits.values { permit.revoke() }
            historyQueue.async { self.presenceProbe.reset() }
        }

        private func valid(_ input: ContextReadParameters, generation: UUID) -> Bool {
            historyGeneration == generation && input.hasSameAuthority(as: parameters())
        }

        private func workerPermits(_ input: ContextReadParameters, permit: AXRequestPermit) -> Bool {
            guard permit.isValid else { return false }
            guard live else { return true }
            guard !IsSecureEventInputEnabled(), ForegroundSessionAvailability.isAvailable(),
                  let revision = input.pauseRevision,
                  (try? GoalongGlobalPause.revalidate(revision)) != nil else { return false }
            return GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory) == input.privacy
        }

        func requestCapture(blockingSink: ((BlockingObservation) -> Void)? = nil, historyEnabled: Bool = true,
                            includePresence: Bool = false, blockingCompletion: (() -> Void)? = nil,
                            completion: @escaping (ContextSnapshot?) -> Void) {
            if backend == .legacy {
                legacyCapture(blockingSink: blockingSink, historyEnabled: historyEnabled, completion: completion)
                blockingCompletion?()
                return
            }
            let input = historyEnabled ? parameters() : nil
            let generation = historyGeneration
            let jobID = UUID(), permit = AXRequestPermit()
            let observedAt = client.clock.date(), admittedAt = client.clock.uptime()
            let requestID = client.clock.identifier()
            var blockingReady = blockingSink == nil
            var blockingResult: BlockingObservation?
            var resume: (() -> Void)?
            var finished = false
            let accepted = operations.enqueue { done in
                let finish: (ContextSnapshot?) -> Void = { snapshot in
                    finished = true
                    self.permits[jobID] = nil
                    self.client.measure(.publication, requestID: requestID) { completion(snapshot) }
                    done()
                }
                let read = {
                    guard let input, self.valid(input, generation: generation) else { finish(nil); return }
                    let privateApp = blockingResult.flatMap { observation in
                        observation.privateWindow ? AppSnapshot(name: observation.bundleIdentifier,
                            bundleIdentifier: observation.bundleIdentifier, processIdentifier: observation.pid) : nil
                    }
                    let blockingBoundary = privateApp == nil ? blockingResult?.windowBoundary : nil
                    // Resolve uncatalogued system focus by a main continuation, never a sync hop.
                    self.historyQueue.async {
                        self.client.metric?(AXOperationMetric(requestID: requestID, stage: .waiting, operation: "history",
                            duration: max(0, self.client.clock.uptime() - admittedAt), onMain: false, error: 0))
                        guard self.workerPermits(input, permit: permit) else {
                            DispatchQueue.main.async { finish(nil) }; return
                        }
                        let focusPID = AXAccess.withBackgroundClient(self.client, requestID: requestID, permit: permit) {
                            input.pauseRevision != nil && privateApp == nil && input.accessibilityAvailable
                                ? AXReader.focusedApplicationProcessIdentifier() : nil
                        }
                        DispatchQueue.main.async {
                            guard self.valid(input, generation: generation), permit.isValid else { finish(nil); return }
                            let resolved = focusPID.flatMap { input.applications[$0] ?? self.applicationResolver($0) }
                                .flatMap { $0.isTerminated ? nil : $0 } ?? input.foregroundApplication
                            self.historyQueue.async {
                                guard self.workerPermits(input, permit: permit) else {
                                    DispatchQueue.main.async { finish(nil) }; return
                                }
                                // The public blocking decision belongs to this window.
                                // A private result bypasses *all* historical AX, including
                                // these identity probes. A changed public window needs a
                                // new reserved-lane decision, never the previous result.
                                let blockingWindowMatches = AXAccess.withBackgroundClient(self.client, requestID: requestID, permit: permit) {
                                    blockingBoundary?.matchesFocusedWindow(allowMainWindow: true) != false
                                }
                                guard blockingWindowMatches else {
                                    DispatchQueue.main.async { finish(nil) }; return
                                }
                                let result = self.client.measure(.execution, requestID: requestID) {
                                    AXAccess.withBackgroundClient(self.client, requestID: requestID, permit: permit) {
                                        self.historyReader.capture(parameters: input, blockingPrivateApp: privateApp,
                                            resolvedApplication: resolved)
                                    }
                                }
                                let capturedWindowMatches = AXAccess.withBackgroundClient(self.client, requestID: requestID, permit: permit) {
                                    result.boundary?.matchesFocusedWindow() != false
                                }
                                guard capturedWindowMatches else {
                                    DispatchQueue.main.async { finish(nil) }; return
                                }
                                let snapshot = result.snapshot.map { captured in
                                    guard includePresence else { return captured }
                                    let presence = AXAccess.withBackgroundClient(self.client, requestID: requestID, permit: permit) {
                                        self.presenceProbe.observe(captured, labelsEnabled: input.config.captureElementLabels,
                                            idleSeconds: input.idleSeconds, idleLimitSeconds: input.config.effectiveForegroundIdleSeconds,
                                            at: observedAt)
                                    }
                                    return captured.withForegroundUsage(presence)
                                }
                                DispatchQueue.main.async {
                                    guard self.valid(input, generation: generation), permit.isValid else { finish(nil); return }
                                    self.lastCaptureProvedExternalAX = result.provedExternalAX
                                    self.lastCaptureBoundary = result.boundary
                                    if let browser = result.discoveredBrowser { self.blockingLane.rememberBrowser(browser) }
                                    if let update = result.privateWindowUpdate { self.privateWindowSink(update) }
                                    finish(snapshot)
                                }
                            }
                        }
                    }
                }
                if blockingReady { read() } else { resume = read }
            }
            if !accepted { finished = true; completion(nil) }
            if accepted && !finished { permits[jobID] = permit }
            // This reservation happens at admission, independently of the history FIFO.
            if let blockingSink {
                requestBlocking { observation in
                    blockingResult = observation
                    blockingReady = true
                    if let observation { blockingSink(observation) }
                    blockingCompletion?()
                    // An unavailable/revoked blocking observation never authorizes history.
                    if observation == nil { permit.revoke() }
                    let continuation = resume; resume = nil; continuation?()
                }
            }
        }

        private func legacyCapture(blockingSink: ((BlockingObservation) -> Void)? = nil, historyEnabled: Bool = true,
                            completion: @escaping (ContextSnapshot?) -> Void) {
            var blockingPrivateApp: AppSnapshot?
            if let blockingSink, let observation = blockingProbe == nil ? captureBlocking() : blockingProbe?() {
                blockingSink(observation)
                if observation.privateWindow {
                    blockingPrivateApp = AppSnapshot(name: observation.bundleIdentifier,
                        bundleIdentifier: observation.bundleIdentifier, processIdentifier: observation.pid)
                }
            }
            guard historyEnabled else { completion(nil); return }
            let requestID = client.clock.identifier()
            let input = parameters()
            let result = client.measure(.execution, requestID: requestID) {
                AXAccess.withClient(client, requestID: requestID) {
                    // The legacy bridge resolves an uncatalogued focus owner on
                    // main, outside the reader. The eventual background backend
                    // must resume this bridge by continuation, never main.sync.
                    var resolved = input.foregroundApplication
                    if input.pauseRevision != nil, blockingPrivateApp == nil, input.accessibilityAvailable,
                       let front = resolved, let pid = AXReader.focusedApplicationProcessIdentifier(),
                       pid != front.processIdentifier,
                       let application = input.applications[pid] ?? applicationResolver(pid), !application.isTerminated {
                        resolved = application
                    }
                    return historyReader.capture(parameters: input, blockingPrivateApp: blockingPrivateApp,
                                                 resolvedApplication: resolved)
                }
            }
            client.measure(.publication, requestID: requestID) {
                lastCaptureProvedExternalAX = result.provedExternalAX
                // Transfer immutable capability evidence, never share mutable caches.
                if let browser = result.discoveredBrowser {
                    blockingReader.rememberBrowser(browser)
                    blockingLane.rememberBrowser(browser)
                }
                if let privateWindowUpdate = result.privateWindowUpdate { privateWindowSink(privateWindowUpdate) }
                completion(result.snapshot)
            }
        }

        func capture(blockingSink: ((BlockingObservation) -> Void)? = nil, historyEnabled: Bool = true) -> ContextSnapshot? {
            precondition(backend == .legacy, "Synchronous capture is a parity-only backend")
            var result: ContextSnapshot?
            legacyCapture(blockingSink: blockingSink, historyEnabled: historyEnabled) { result = $0 }
            return result
        }

        func invalidateBlocking() { blockingGeneration = UUID() }

        func requestBlocking(of application: NSRunningApplication? = nil, completion: @escaping (BlockingObservation?) -> Void) {
            // Fixture probes remain synchronous and do not issue AX calls.
            if let blockingProbe { completion(blockingProbe()); return }
            let input = blockingParameters()
            let generation = blockingGeneration
            blockingLane.request(input, application: application.map(ForegroundAXApplication.init)) { [weak self] observation in
                guard let self, self.blockingGeneration == generation else { completion(nil); return }
                let current = self.blockingParameters()
                guard current.config == input.config,
                      current.foregroundApplication?.processIdentifier == input.foregroundApplication?.processIdentifier,
                      current.foregroundApplication?.instanceStartedAt == input.foregroundApplication?.instanceStartedAt,
                      current.sessionAvailable == input.sessionAvailable,
                      current.blockingAXTrusted == input.blockingAXTrusted else { completion(nil); return }
                completion(observation)
            }
        }

        func captureBlocking(of application: NSRunningApplication? = nil) -> BlockingObservation? {
            precondition(backend == .legacy, "Synchronous blocking capture is parity-only")
            let input = blockingParameters()
            return AXAccess.withClient(client, requestID: client.clock.identifier()) {
                blockingReader.captureBlocking(parameters: input, of: application.map(ForegroundAXApplication.init))
            }
        }

        private func requestRead<T>(_ read: @escaping (ContextReadParameters) -> T,
                                    revoked: T, completion: @escaping (T) -> Void) {
            let input = parameters(), generation = historyGeneration
            if backend == .legacy {
                completion(AXAccess.withClient(client) { read(input) }); return
            }
            let jobID = UUID(), permit = AXRequestPermit()
            // enqueue() may finish synchronously, so register before admission.
            permits[jobID] = permit
            let accepted = operations.enqueue { done in
                guard self.valid(input, generation: generation) else {
                    self.permits[jobID] = nil
                    completion(revoked); done(); return
                }
                self.historyQueue.async {
                    let result = self.workerPermits(input, permit: permit)
                        ? AXAccess.withBackgroundClient(self.client, permit: permit) { read(input) } : revoked
                    DispatchQueue.main.async {
                        self.permits[jobID] = nil
                        completion(self.valid(input, generation: generation) && permit.isValid ? result : revoked)
                        done()
                    }
                }
            }
            if !accepted { permits[jobID] = nil; completion(revoked) }
        }

        func requestSuppression(completion: @escaping (SuppressionReason?) -> Void) {
            requestRead({ self.historyReader.fastSuppressionReason(parameters: $0) },
                        revoked: .sessionUnavailable, completion: completion)
        }
        func requestInput(at point: CGPoint?, expectedProcessIdentifier: pid_t,
                          completion: @escaping (AXInputRead) -> Void) {
            requestRead({ input in
                let suppression = self.historyReader.fastSuppressionReason(parameters: input)
                let element = suppression == nil ? point.flatMap {
                    self.historyReader.element(at: $0, expectedProcessIdentifier: expectedProcessIdentifier, parameters: input)
                } : nil
                return AXInputRead(suppression: suppression, element: element)
            }, revoked: AXInputRead(suppression: .sessionUnavailable, element: nil), completion: completion)
        }
        func requestElement(at point: CGPoint, expectedProcessIdentifier: pid_t? = nil,
                            completion: @escaping (ElementSnapshot?) -> Void) {
            requestRead({ self.historyReader.element(at: point, expectedProcessIdentifier: expectedProcessIdentifier,
                                                     parameters: $0) }, revoked: nil, completion: completion)
        }
        func frontmostProcessIdentifier() -> pid_t? { foregroundPID() }

        static func provesExternalAX(pid: Int32, ownPID: Int32, protectedReadSucceeded: Bool) -> Bool {
            ContextAXReader.provesExternalAX(pid: pid, ownPID: ownPID, protectedReadSucceeded: protectedReadSucceeded)
        }
        static func shouldProbeBrowserCapability(isKnownBrowser: Bool, capturesURLs: Bool) -> Bool {
            ContextAXReader.shouldProbeBrowserCapability(isKnownBrowser: isKnownBrowser, capturesURLs: capturesURLs)
        }
        static func shouldProbeWebPrivacyOnInput(isWebContainer: Bool, privateWindowCapable: Bool, hasDomainRules: Bool) -> Bool {
            ContextAXReader.shouldProbeWebPrivacyOnInput(isWebContainer: isWebContainer,
                privateWindowCapable: privateWindowCapable, hasDomainRules: hasDomainRules)
        }
    }
#endif
