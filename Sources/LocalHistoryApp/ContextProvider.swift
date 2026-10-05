#if os(macOS)
    import AppKit
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

    /// Main-owned facade. Only the legacy backend is enabled in lot 2: every
    /// mutable reader has one owner, and continuations preserve existing effects.
    final class ContextProvider {
        enum Backend { case legacy }
        let backend: Backend = .legacy
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

        init(configManager: ConfigManager, permissions: PermissionManager,
             blockingProbe: (() -> BlockingObservation?)? = nil, client: AXClient = .system) {
            self.client = client
            self.blockingProbe = blockingProbe
            self.privateWindowSink = { JevIngress.shared.setPrivateWindow($0) }
            historyReader = ContextAXReader(clock: client.clock)
            blockingReader = ContextAXReader(clock: client.clock)
            blockingLane = BlockingAXLane(client: client)
            parameters = { Self.liveParameters(config: configManager.config, accessibility: permissions.currentStatus.accessibility, history: true) }
            blockingParameters = { Self.liveParameters(config: configManager.config, accessibility: false, history: false) }
            foregroundPID = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            applicationResolver = { NSRunningApplication(processIdentifier: $0).map(ForegroundAXApplication.init) }
        }

        /// Fixture injection avoids AppKit, permission probes and user storage.
        init(client: AXClient, parameters: @escaping () -> ContextReadParameters,
             privateWindowSink: @escaping (Bool) -> Void = { _ in },
             applicationResolver: @escaping (pid_t) -> ForegroundAXApplication? = { _ in nil }) {
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

        private static func liveParameters(config: RecorderConfig, accessibility: Bool, history: Bool) -> ContextReadParameters {
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
                pauseRevision: history ? try? GoalongGlobalPause.admit() : nil)
        }

        /// Completion API intentionally uses the same legacy execution order until
        /// the complete consumer group changes backend together in lot 4.
        func requestCapture(blockingSink: ((BlockingObservation) -> Void)? = nil, historyEnabled: Bool = true,
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
            var result: ContextSnapshot?
            requestCapture(blockingSink: blockingSink, historyEnabled: historyEnabled) { result = $0 }
            return result
        }

        func invalidateBlocking() { blockingGeneration = UUID() }

        func requestBlocking(completion: @escaping (BlockingObservation?) -> Void) {
            // Fixture probes remain synchronous and do not issue AX calls.
            if let blockingProbe { completion(blockingProbe()); return }
            let input = blockingParameters()
            let generation = blockingGeneration
            blockingLane.request(input) { [weak self] observation in
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
            let input = blockingParameters()
            return AXAccess.withClient(client, requestID: client.clock.identifier()) {
                blockingReader.captureBlocking(parameters: input, of: application.map(ForegroundAXApplication.init))
            }
        }

        func requestSuppression(completion: @escaping (SuppressionReason?) -> Void) {
            let input = parameters()
            completion(AXAccess.withClient(client, requestID: client.clock.identifier()) {
                historyReader.fastSuppressionReason(parameters: input)
            })
        }
        func fastSuppressionReason() -> SuppressionReason? {
            var result: SuppressionReason?
            requestSuppression { result = $0 }
            return result
        }
        func requestElement(at point: CGPoint, expectedProcessIdentifier: pid_t? = nil,
                            completion: @escaping (ElementSnapshot?) -> Void) {
            let input = parameters()
            completion(AXAccess.withClient(client, requestID: client.clock.identifier()) {
                historyReader.element(at: point, expectedProcessIdentifier: expectedProcessIdentifier, parameters: input)
            })
        }
        func element(at point: CGPoint, expectedProcessIdentifier: pid_t? = nil) -> ElementSnapshot? {
            var result: ElementSnapshot?
            requestElement(at: point, expectedProcessIdentifier: expectedProcessIdentifier) { result = $0 }
            return result
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
