#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class AXAsyncWorkflowTests: XCTestCase {
    private final class Identity: MinuteSealSigningIdentity {
        let info = DeviceIdentityInfo(deviceID: "ax-fixture", publicKeyBase64: Data("key".utf8).base64EncodedString(),
                                      trustTier: "test", algorithm: "test-signature")
        func sign(_ message: Data) throws -> Data { Data(SHA256Digest.hashHex(message).utf8) }
    }
    private struct Rig {
        let root: URL, recorder: EventRecorder, state: CaptureState, config: ConfigManager
        let permissions: PermissionManager, health: CaptureHealthStore, semantic: SemanticContextStore
        let memory: LocalActivityMemoryStore
    }
    private func rig(at date: Date, beforePersist: ((HistoryEvent) -> Void)? = nil) throws -> Rig {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".perf-work/async-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("semantic"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try JSONLStore(retentionDays: 0, eventsDirectory: root.appendingPathComponent("events"), prepareApplicationStorage: false)
        let integrity = IntegrityStateStore(fileURL: root.appendingPathComponent("integrity.json"), prepareStorage: {})
        let sealer = MinuteSealer(stateStore: integrity, identity: Identity(), initialDate: date,
            sealDirectory: root.appendingPathComponent("seals"), prepareStorage: {}, sealAppender: { _, _ in })
        var ordinal = 0
        let recorder = EventRecorder(store: store,
            integrityJournal: IntegrityJournal(stateStore: integrity, saltBytes: { Data(repeating: 7, count: $0) }),
            minuteSealer: sealer, beforePersist: beforePersist, clock: { date }, sessionID: "fixture-session",
            eventIdentifier: { ordinal += 1; return "event-\(ordinal)" })
        let permissions = PermissionManager(statusProbe: { Self.healthy })
        var config = RecorderConfig.default
        config.captureClicks = true; config.captureScroll = true; config.captureKeyboardActivity = true
        return Rig(root: root, recorder: recorder, state: CaptureState(isGloballyPaused: { false }), config: ConfigManager(config: config),
            permissions: permissions, health: CaptureHealthStore(permissions: permissions, fileURL: root.appendingPathComponent("health.json")),
            semantic: SemanticContextStore(semanticDirectory: root.appendingPathComponent("semantic"), secureInputEnabled: { false }),
            memory: LocalActivityMemoryStore(rootDirectory: root))
    }
    private static var healthy: PermissionStatus {
        PermissionStatus.resolved(accessibilityPreflight: true, accessibilityFunctionalProbe: true,
                                  inputMonitoringDirectlyGranted: true, accessibilityCrossProcessProbe: true)
    }
    private func input() -> ContextReadParameters {
        let app = ForegroundAXApplication(pid: 42, name: "Fixture", bundleIdentifier: "test.native")
        var config = RecorderConfig.default; config.captureElementLabels = true; config.captureWindowTitles = true
        var privacy = GoalongPrivacyPolicy(); privacy.revision = "none"
        return ContextReadParameters(foregroundApplication: app, applications: [42: app], config: config,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true, idleSeconds: 1,
            privacy: privacy, pauseRevision: try? GoalongGlobalPause.admit())
    }
    private func monitor(_ rig: Rig, provider: ContextProvider) -> EventTapMonitor {
        let context = ContextMonitor(provider: provider, recorder: rig.recorder, state: rig.state, configManager: rig.config,
            permissions: rig.permissions, captureHealth: rig.health, semanticContextStore: rig.semantic, memoryStore: rig.memory)
        var ordinal = 0
        return EventTapMonitor(recorder: rig.recorder, contextMonitor: context, contextProvider: provider,
            state: rig.state, configManager: rig.config, captureHealth: rig.health,
            interactionIdentifier: { ordinal += 1; return "interaction-\(ordinal)" })
    }
    private func stream(_ rig: Rig, date: Date) throws -> Data {
        try rig.recorder.flushAndWait()
        return try Data(contentsOf: rig.root.appendingPathComponent("events/" + AppPaths.localDayString(for: date) + ".jsonl"))
    }
    private func events(_ data: Data) throws -> [HistoryEvent] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 10).map { try decoder.decode(HistoryEvent.self, from: Data($0)) }
    }
    private func richConsent(_ enabled: Bool) {
        let key = ActivityAnalysisPreferences.richContextEnabledKey, previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        addTeardownBlock {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testActualInputReducersProduceIdenticalJSONLAndHashChainWithBothBackends() throws {
        richConsent(false)
        let date = Date().addingTimeInterval(-0.2), parameters = input()
        var streams: [Data] = []
        for backend in [ContextProvider.Backend.legacy, .background] {
            let rig = try rig(at: date), tree = ScriptedAXTree()
            let snapshot = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: parameters).snapshot })
            let provider = ContextProvider(client: tree.client, backend: backend, parameters: { parameters })
            let tap = monitor(rig, provider: provider)
            let kinds: [EventTapPendingInput.Kind] = [.keyDown, .keyDown, .scrollWheel, .leftMouseDown, .leftMouseUp,
                .leftMouseDown, .leftMouseDragged, .leftMouseUp, .leftMouseDown, .leftMouseUp]
            let inputs = kinds.enumerated().map { index, kind in
                EventTapPendingInput(kind: kind, observedAt: date.addingTimeInterval(Double(index) / 100),
                    locationX: Double(index * 10), locationY: 20, scrollDeltaY: 3,
                    targetProcessIdentifier: 42, observedContext: snapshot)
            }
            if backend == .background { tree.beforeRead = { _ in XCTAssertFalse(Thread.isMainThread) } }
            let done = expectation(description: "real ingress + reducer replay")
            tap.replayInputsForTesting(inputs) { done.fulfill() }
            wait(for: [done], timeout: 3)
            tap.stop()
            XCTAssertEqual(tap.privacyInputDropCount, 0); XCTAssertEqual(tap.staleInputDropCount, 0)
            XCTAssertEqual(rig.recorder.persistenceSnapshot.acceptedEventCount, 5)
            streams.append(try stream(rig, date: date))
            XCTAssertEqual(tap.privacyInputDropCount, 0); XCTAssertEqual(tap.staleInputDropCount, 0)
            try rig.recorder.closeAndWait()
        }
        XCTAssertEqual(streams[0], streams[1], "All fields, dates, interaction IDs, input sequences, salts and chain order are retained")
        let rows = try events(streams[1])
        XCTAssertEqual(rows.map(\.kind), [.typingBurst, .scrollBurst, .mouseClick, .mouseClick, .mouseClick])
        XCTAssertEqual(rows.map { $0.integrity?.sequence }, [1, 2, 3, 4, 5])
    }

    func testStoppingDuringMouseDownDoesNotLoseOrOvertakeItsQueuedMouseUp() throws {
        richConsent(false)
        let date = Date(), parameters = input(), tree = ScriptedAXTree(), rig = try rig(at: date)
        let snapshot = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: parameters).snapshot })
        let entered = expectation(description: "input AX entered"), stopped = expectation(description: "asynchronous stop drained")
        let release = DispatchSemaphore(value: 0); var held = false
        tree.beforeRead = { _ in
            XCTAssertFalse(Thread.isMainThread)
            if !held { held = true; entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success) }
        }
        let provider = ContextProvider(client: tree.client, parameters: { parameters }), tap = monitor(rig, provider: provider)
        tap.replayInputsForTesting([.init(kind: .leftMouseDown, observedAt: date, targetProcessIdentifier: 42, observedContext: snapshot),
            .init(kind: .leftMouseUp, observedAt: date.addingTimeInterval(0.01), targetProcessIdentifier: 42, observedContext: snapshot)]) {}
        wait(for: [entered], timeout: 3)
        tap.stop { stopped.fulfill() }
        XCTAssertTrue(tap.isRunning, "Main did not join the outstanding AX request")
        release.signal(); wait(for: [stopped], timeout: 3)
        XCTAssertEqual(tap.privacyInputDropCount, 0); XCTAssertEqual(rig.recorder.persistenceSnapshot.acceptedEventCount, 1)
        let rows = try events(stream(rig, date: date))
        XCTAssertEqual(rows.map(\.kind), [.mouseClick]); XCTAssertEqual(rows.first?.metadata?["computer_history.input_sequence"], "1")
        XCTAssertFalse(tap.isRunning); XCTAssertEqual(tap.stopDiscardedInputCount, 0)
        try rig.recorder.closeAndWait()
    }

    func testSemanticWriterReservationCannotBeOvertakenByALaterRawEvent() throws {
        let date = Date(), rig = try rig(at: date)
        let entered = expectation(description: "writer slot held"), completed = expectation(description: "ordered commit finished")
        let release = DispatchSemaphore(value: 0)
        XCTAssertTrue(rig.recorder.performOrderedCommit(timestamp: date, operation: { identifier in
            XCTAssertFalse(Thread.isMainThread); entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            XCTAssertTrue(rig.recorder.record(kind: .semanticSnapshot, metadata: ["fixture": "reserved"], timestamp: date, identifier: identifier))
        }, completion: { completed.fulfill() }))
        wait(for: [entered], timeout: 3)
        XCTAssertTrue(rig.recorder.record(kind: .heartbeat, timestamp: date.addingTimeInterval(1)))
        release.signal(); wait(for: [completed], timeout: 3)
        let rows = try events(stream(rig, date: date))
        XCTAssertEqual(rows.map(\.kind), [.semanticSnapshot, .heartbeat])
        XCTAssertEqual(rows.map(\.id), ["event-1", "event-2"])
        XCTAssertEqual(rows.map { $0.integrity?.sequence }, [1, 2])
        try rig.recorder.closeAndWait()
    }

    func testSemanticAppendRechecksRevocationAtTheWritePoint() throws {
        let date = Date(), rig = try rig(at: date), tree = ScriptedAXTree(), parameters = input()
        let context = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: parameters).snapshot })
        let capture = AXRichContextCapture(text: "Synthetic public text", source: "visible", redacted: false, truncated: false, fingerprint: "fixture")
        var checks = 0
        XCTAssertThrowsError(try rig.semantic.append(capture: capture, context: context, timestamp: date, validateBeforeAppend: {
            checks += 1; return checks == 1
        }))
        XCTAssertEqual(checks, 2)
        let file = rig.root.appendingPathComponent("semantic/" + AppPaths.localDayString(for: date) + ".semantic.jsonl")
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
        try rig.recorder.closeAndWait()
    }

    func testSemanticOldCompletionCannotReleaseANewSessionJob() throws {
        richConsent(true)
        let date = Date(), parameters = input(), tree = ScriptedAXTree()
        let oldEntered = expectation(description: "old semantic read"), newEntered = expectation(description: "new semantic read")
        let persisted = expectation(description: "new semantic payload/reference")
        let oldRelease = DispatchSemaphore(value: 0), newRelease = DispatchSemaphore(value: 0)
        let rig = try rig(at: date) { row in if row.kind == .semanticSnapshot { persisted.fulfill() } }
        let context = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: parameters).snapshot })
        let evidence = AXContextEvidence(snapshot: context, boundary: AXReadBoundary(window: tree.window, pid: 42))
        var reads = 0
        let runtime = ActivityAnalysisRuntime(client: tree.client, applicationWitness: { _ in { true } }, allowsSemantic: { _ in true }, semanticRead: { pid, chars, nodes in
            XCTAssertFalse(Thread.isMainThread); reads += 1
            if reads == 1 { oldEntered.fulfill(); XCTAssertEqual(oldRelease.wait(timeout: .now() + 3), .success) }
            else { newEntered.fulfill(); XCTAssertEqual(newRelease.wait(timeout: .now() + 3), .success) }
            return AXRichContextReader.capture(processIdentifier: pid, maximumCharacters: chars, maximumNodes: nodes)
        })
        func start() {
            runtime.start(recorder: rig.recorder, state: rig.state, configManager: rig.config,
                currentContext: { completion in XCTAssertTrue(Thread.isMainThread); completion(evidence) },
                semanticContextStore: rig.semantic, memoryStore: rig.memory, automaticWork: false)
        }
        start(); runtime.captureInteractionContext(interactionID: "old", phase: "after", trigger: "click", context: context)
        wait(for: [oldEntered], timeout: 3)
        runtime.stop(); start()
        runtime.captureInteractionContext(interactionID: "new", phase: "after", trigger: "click", context: context)
        XCTAssertEqual(runtime.pendingSemanticJobsForTesting, 2)
        oldRelease.signal(); wait(for: [newEntered], timeout: 3)
        let mainTurn = expectation(description: "old terminal callback delivered")
        DispatchQueue.main.async { mainTurn.fulfill() }; wait(for: [mainTurn], timeout: 3)
        XCTAssertEqual(runtime.pendingSemanticJobsForTesting, 1)
        newRelease.signal(); wait(for: [persisted], timeout: 3)
        let rows = try events(stream(rig, date: date))
        XCTAssertEqual(rows.map(\.kind), [.semanticSnapshot])
        XCTAssertEqual(rows.first?.metadata?[ComputerHistoryMetadata.interactionID], "new")
        let finished = expectation(description: "writer terminal on main")
        DispatchQueue.main.async { finished.fulfill() }; wait(for: [finished], timeout: 3)
        XCTAssertEqual(runtime.pendingSemanticJobsForTesting, 0)
        runtime.stop(); try rig.recorder.closeAndWait()
    }

    func testPermissionInitializationAndForcedRefreshNeverRunAXOnMain() {
        let tree = ScriptedAXTree(), entered = expectation(description: "permission worker entered"), done = expectation(description: "fresh status")
        let release = DispatchSemaphore(value: 0)
        let manager = PermissionManager(statusProbe: {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            AXAccess.withBackgroundClient(tree.client) { _ = AXReader.string(tree.window, attribute: "AXRole" as CFString) }
            return Self.healthy
        }, probeOnBackground: true)
        wait(for: [entered], timeout: 3)
        XCTAssertTrue(manager.refresh(force: true).observationPending)
        release.signal()
        manager.refreshAsync { XCTAssertTrue($0.accessibilityUsable); XCTAssertTrue(Thread.isMainThread); done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testJevRevokedIngressGenerationCannotReadTextOrReleaseBeforeTerminalValidation() throws {
        richConsent(true)
        let tree = ScriptedAXTree(), parameters = input()
        let original = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: parameters).snapshot })
        let presence = ForegroundUsageObservation(observedAt: Date(), idleSeconds: 1, idleLimitSeconds: 120,
                                                isForegroundVisible: true, evidence: .mediaPlayback)
        let context = original.withForegroundUsage(presence)
        let evidence = AXContextEvidence(snapshot: context, boundary: AXReadBoundary(window: tree.window, pid: 42))
        let inbox = JevIngress(notificationCenter: NotificationCenter(), contextIsPermitted: { _ in true })
        inbox.configure(enabled: true, includeText: true)
        tree.reads.removeAll()
        let entered = expectation(description: "Jev classification RPC"), terminal = expectation(description: "revoked Jev terminal")
        let release = DispatchSemaphore(value: 0)
        tree.beforeRead = { name in
            XCTAssertFalse(Thread.isMainThread)
            if name == "AXRole" { entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success) }
        }
        var validations = 0
        let sampler = JevVisibleContextSampler(inbox: inbox, client: tree.client, read: { _, _ in
            _ = AXReader.string(tree.window, attribute: "AXRole" as CFString)
            return AXReader.string(tree.focus, attribute: "AXValue" as CFString)
        }, onTerminal: { XCTAssertTrue(Thread.isMainThread); terminal.fulfill() })
        sampler.observe(context, presence: presence) { completion in
            XCTAssertTrue(Thread.isMainThread); validations += 1; completion(evidence)
        }
        wait(for: [entered], timeout: 3)
        XCTAssertTrue(sampler.hasPendingReadForTesting)
        inbox.configure(enabled: false)
        release.signal(); wait(for: [terminal], timeout: 3)
        XCTAssertFalse(sampler.hasPendingReadForTesting)
        XCTAssertFalse(tree.reads.contains("AXValue")); XCTAssertEqual(validations, 1)
    }

    @MainActor func testQueuedSiteActionRevalidatesExpiryBeforeTheNextBlockingTimer() {
        var now = Date()
        let list = BlockList(name: "Fixture", sites: [BlockSiteRule(pattern: "example.com")])
        let controller = BlockingController(document: BlockingDocument(lists: [list]), clock: { now })
        controller.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        let target = BlockingObservation(bundleIdentifier: "com.apple.Safari", pid: 42, windowFrame: nil,
            isBrowser: true, url: "example.com/work", privateWindow: false, at: now)
        XCTAssertTrue(controller.siteActionStillRequired(target))
        now = now.addingTimeInterval(601)
        XCTAssertFalse(controller.siteActionStillRequired(target), "The old decision cannot close a tab after its rules expired")
    }
}
#endif
