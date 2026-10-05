#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class AXAdversarialReviewTests: XCTestCase {
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


    private func tick(_ seconds: Double = 0.02) {
        let e = expectation(description: "main-loop tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 3)
    }
    private func contextMonitor(_ rig: Rig, _ provider: ContextProvider) -> ContextMonitor {
        ContextMonitor(provider: provider, recorder: rig.recorder, state: rig.state,
            configManager: rig.config, permissions: rig.permissions, captureHealth: rig.health,
            semanticContextStore: rig.semantic, memoryStore: rig.memory)
    }
    private func permits(_ provider: ContextProvider) -> Int {
        let field = Mirror(reflecting: provider).children.first { $0.label == "permits" }!
        return (field.value as! [UUID: AXRequestPermit]).count
    }

    func testReviewRevokedQueuedReadsReleaseAllPermits() {
        let tree = ScriptedAXTree(), params = input()
        let provider = ContextProvider(client: tree.client, parameters: { params })
        let entered = expectation(description: "first read held"), done = expectation(description: "nine terminals")
        done.expectedFulfillmentCount = 9
        let release = DispatchSemaphore(value: 0)
        var held = false
        tree.beforeRead = { _ in
            if !held { held = true; entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        }
        provider.requestSuppression { _ in done.fulfill() }
        wait(for: [entered], timeout: 3)
        for _ in 0..<8 { provider.requestSuppression { _ in done.fulfill() } }
        XCTAssertEqual(permits(provider), 9, "Admitted jobs must own revocable permits")
        provider.invalidateHistory(); release.signal()
        wait(for: [done], timeout: 3)
        print("REVIEW permits retained after nine terminal callbacks: \(permits(provider))")
        XCTAssertEqual(permits(provider), 0, "Each terminal path must release its permit")
    }

    func testReviewMixedAdmissionCannotSuppressReservedBlockingAtSaturation() {
        let tree = ScriptedAXTree(), params = input()
        let provider = ContextProvider(client: tree.client, parameters: { params })
        let entered = expectation(description: "held head"), done = expectation(description: "all admitted reads")
        done.expectedFulfillmentCount = 256
        let release = DispatchSemaphore(value: 0); var held = false, blocking = 0
        tree.beforeRead = { _ in
            if !held { held = true; entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        }
        provider.requestSuppression { _ in done.fulfill() }
        wait(for: [entered], timeout: 3)
        for _ in 0..<255 { provider.requestSuppression { _ in done.fulfill() } }
        provider.requestCapture(blockingSink: { _ in blocking += 1 }) { _ in }
        let direct = expectation(description: "separate direct blocking request is alive")
        provider.requestBlocking { XCTAssertNotNil($0); direct.fulfill() }
        wait(for: [direct], timeout: 3)
        print("REVIEW mixed blocking deliveries at full history queue: \(blocking), independent request completed")
        XCTAssertEqual(blocking, 1, "History saturation must not suppress the reserved blocking lane")
        provider.invalidateHistory(); release.signal(); wait(for: [done], timeout: 3)
    }

    func testReviewSlowHistoryMustNotSuspendMixedBlockingPoll() throws {
        richConsent(false)
        let rig = try rig(at: Date()), tree = ScriptedAXTree(), params = input()
        let provider = ContextProvider(client: tree.client, parameters: { params })
        let monitor = contextMonitor(rig, provider)
        monitor.configureForAdversarialReview(blocking: true, polling: true)
        let entered = expectation(description: "history held after blocking"), terminal = expectation(description: "history terminal")
        let release = DispatchSemaphore(value: 0)
        tree.beforeRead = { name in if name == "AXFocusedApplication" { entered.fulfill(); _ = release.wait(timeout: .now() + 4) } }
        var blocking = 0
        monitor.blockingSink = { _ in blocking += 1 }
        monitor.sampleNow { _ in terminal.fulfill() }
        wait(for: [entered], timeout: 3)
        tick(0.95)
        print("REVIEW blocking observations during 0.95s history stall: \(blocking), poll timer active: \(monitor.hasPollForAdversarialReview)")
        XCTAssertGreaterThanOrEqual(blocking, 2, "The 0.75s blocking poll must run while history is held")
        monitor.configureForAdversarialReview(blocking: false, polling: false)
        release.signal(); wait(for: [terminal], timeout: 3)
        try rig.recorder.closeAndWait()
    }

    func testReviewOldFailedSampleMustNotRevokeNewForegroundSample() throws {
        richConsent(false)
        let rig = try rig(at: Date()), tree = ScriptedAXTree()
        var params = input()
        let provider = ContextProvider(client: tree.client, parameters: { params })
        let monitor = contextMonitor(rig, provider)
        monitor.configureForAdversarialReview(blocking: false, polling: false)
        let entered = expectation(description: "A held"), done = expectation(description: "A and B terminal")
        done.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0); var held = false
        tree.beforeRead = { _ in if !held { held = true; entered.fulfill(); _ = release.wait(timeout: .now() + 3) } }
        monitor.sampleNow { XCTAssertNil($0); done.fulfill() }
        wait(for: [entered], timeout: 3)
        let b = ForegroundAXApplication(pid: 84, name: "B", bundleIdentifier: "test.b")
        params = ContextReadParameters(foregroundApplication: b, applications: [84: b], config: params.config,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true, idleSeconds: 1,
            privacy: params.privacy, pauseRevision: params.pauseRevision)
        tree.client.getPID = { _, out in out.pointee = 84; return .success }
        var bResult: ContextSnapshot?
        monitor.sampleNow { bResult = $0; done.fulfill() }
        release.signal(); wait(for: [done], timeout: 3)
        print("REVIEW valid B capture after rejection of A: \(bResult?.app.processIdentifier.description ?? "nil")")
        XCTAssertEqual(bResult?.app.processIdentifier, 84, "Discarding stale A must not cancel already-admitted B")
        let control = expectation(description: "fresh B control")
        monitor.sampleNow { XCTAssertEqual($0?.app.processIdentifier, 84); control.fulfill() }
        wait(for: [control], timeout: 3)
        try rig.recorder.closeAndWait()
    }

    func testReviewRevokedSemanticReservationMustNotPoisonDeduplication() throws {
        richConsent(true)
        let held = expectation(description: "writer held"), release = DispatchSemaphore(value: 0)
        let date = Date(), params = input(), tree = ScriptedAXTree()
        let rig = try rig(at: date) { row in if row.kind == .heartbeat { held.fulfill(); _ = release.wait(timeout: .now() + 5) } }
        let snapshot = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: params).snapshot })
        let evidence = AXContextEvidence(snapshot: snapshot, boundary: AXReadBoundary(window: tree.window, pid: 42))
        let runtime = ActivityAnalysisRuntime(client: tree.client, applicationWitness: { _ in { true } }, allowsSemantic: { _ in true }, semanticRead: { _, _, _ in
            AXRichContextCapture(text: "Public fixture text", source: "visible", redacted: false, truncated: false, fingerprint: "unchanged-F")
        })
        var validations = 0
        var prepared: XCTestExpectation?
        func start() {
            runtime.start(recorder: rig.recorder, state: rig.state, configManager: rig.config, currentContext: { completion in
                validations += 1; completion(evidence)
                if validations == 2 { DispatchQueue.main.async { prepared?.fulfill() } }
            }, semanticContextStore: rig.semantic, memoryStore: rig.memory, automaticWork: false)
        }
        rig.recorder.record(kind: .heartbeat, timestamp: date)
        wait(for: [held], timeout: 3)
        start(); prepared = expectation(description: "first capture reserved")
        runtime.captureObservedContext(trigger: "focus_changed", context: snapshot)
        wait(for: [prepared!], timeout: 3)
        XCTAssertEqual(runtime.pendingSemanticJobsForTesting, 1)
        runtime.stop(); release.signal(); try rig.recorder.flushAndWait(); tick()
        validations = 0; prepared = expectation(description: "second identical capture")
        start(); runtime.captureObservedContext(trigger: "focus_changed", context: snapshot)
        wait(for: [prepared!], timeout: 3); tick()
        let rows = try events(stream(rig, date: date))
        let count = rows.filter { $0.kind == .semanticSnapshot }.count
        print("REVIEW semantic rows after revoked reservation then retry unchanged public text: \(count)")
        XCTAssertEqual(count, 1, "A revoked, never-written fingerprint must remain capturable")
        runtime.stop(); try rig.recorder.closeAndWait()
    }

    func testReviewOlderSemanticTerminalCannotReleaseNewReservation() throws {
        richConsent(true)
        let held = expectation(description: "writer held"), release = DispatchSemaphore(value: 0)
        let date = Date(), params = input(), tree = ScriptedAXTree()
        let rig = try rig(at: date) { row in
            if row.kind == .heartbeat { held.fulfill(); _ = release.wait(timeout: .now() + 5) }
        }
        let snapshot = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: params).snapshot })
        let evidence = AXContextEvidence(snapshot: snapshot, boundary: AXReadBoundary(window: tree.window, pid: 42))
        let runtime = ActivityAnalysisRuntime(client: tree.client, applicationWitness: { _ in { true } }, allowsSemantic: { _ in true }, semanticRead: { _, _, _ in
            AXRichContextCapture(text: "Public reservation fixture", source: "visible", redacted: false, truncated: false, fingerprint: "owned-F")
        })
        func reserve() {
            let prepared = expectation(description: "capture reserved"), validations = Counter()
            runtime.start(recorder: rig.recorder, state: rig.state, configManager: rig.config, currentContext: { completion in
                validations.value += 1; completion(evidence)
                if validations.value == 2 { DispatchQueue.main.async { prepared.fulfill() } }
            }, semanticContextStore: rig.semantic, memoryStore: rig.memory, automaticWork: false)
            runtime.captureObservedContext(trigger: "focus_changed", context: snapshot)
            wait(for: [prepared], timeout: 3)
        }
        rig.recorder.record(kind: .heartbeat, timestamp: date); wait(for: [held], timeout: 3)
        reserve(); runtime.stop(); reserve()
        XCTAssertEqual(runtime.pendingSemanticJobsForTesting, 2)
        release.signal(); try rig.recorder.flushAndWait(); tick()
        XCTAssertEqual(runtime.pendingSemanticJobsForTesting, 0)
        XCTAssertEqual(try events(stream(rig, date: date)).filter { $0.kind == .semanticSnapshot }.count, 1)
        runtime.stop(); try rig.recorder.closeAndWait()
    }
    private final class Counter { var value = 0 }

    func testReviewSemanticTimestampMustNotMovePastLaterReservedEvent() throws {
        richConsent(true)
        let held = expectation(description: "writer held"), release = DispatchSemaphore(value: 0)
        let date = Date(), params = input(), tree = ScriptedAXTree()
        let rig = try rig(at: date) { row in if row.kind == .heartbeat { held.fulfill(); _ = release.wait(timeout: .now() + 8) } }
        let snapshot = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: params).snapshot })
        let evidence = AXContextEvidence(snapshot: snapshot, boundary: AXReadBoundary(window: tree.window, pid: 42))
        let runtime = ActivityAnalysisRuntime(client: tree.client, applicationWitness: { _ in { true } }, allowsSemantic: { _ in true }, semanticRead: { _, _, _ in
            AXRichContextCapture(text: "Public timestamp fixture", source: "visible", redacted: false, truncated: false, fingerprint: "timestamp-F")
        })
        let reserved = expectation(description: "semantic reserved before later event")
        var validations = 0
        runtime.start(recorder: rig.recorder, state: rig.state, configManager: rig.config, currentContext: { completion in
            validations += 1; completion(evidence)
            if validations == 2 { DispatchQueue.main.async { reserved.fulfill() } }
        }, semanticContextStore: rig.semantic, memoryStore: rig.memory, automaticWork: false)
        rig.recorder.record(kind: .heartbeat, timestamp: date); wait(for: [held], timeout: 3)
        runtime.captureInteractionContext(interactionID: "timestamp", phase: "after", trigger: "click", context: snapshot)
        wait(for: [reserved], timeout: 3)
        let laterDate = Date()
        rig.recorder.record(kind: .mouseClick, context: snapshot, timestamp: laterDate)
        tick(2.1); release.signal(); try rig.recorder.flushAndWait(); tick()
        let rows = try events(stream(rig, date: date))
        XCTAssertEqual(rows.map(\.kind), [.heartbeat, .semanticSnapshot, .mouseClick])
        let semantic = try XCTUnwrap(rows.first { $0.kind == .semanticSnapshot })
        let later = try XCTUnwrap(rows.first { $0.kind == .mouseClick })
        print("REVIEW semantic timestamp minus later click timestamp: \(semantic.timestamp.timeIntervalSince(later.timestamp)); reference capturedAt: \(semantic.semanticContext!.capturedAt.timeIntervalSince(later.timestamp))")
        XCTAssertLessThanOrEqual(semantic.timestamp, later.timestamp, "FIFO reservation must not receive a timestamp from after later events")
        XCTAssertLessThanOrEqual(semantic.semanticContext!.capturedAt, later.timestamp)
        runtime.stop(); try rig.recorder.closeAndWait()
    }

    func testReviewObserverCommandsRemainFIFOAcrossThreadStartup() {
        for attempt in 0..<100 {
            let thread = AXObservationThread(), done = expectation(description: "observer command batch")
            var delivered: [Int] = [], snapshot: [Int] = []
            for i in 0..<500 { thread.submit { delivered.append(i) } }
            thread.shutdown { snapshot = delivered; done.fulfill() }
            wait(for: [done], timeout: 3)
            if snapshot != Array(0..<500) {
                let first = snapshot.enumerated().first { $0.offset != $0.element }?.offset
                print("REVIEW observer startup command order diverged in attempt \(attempt), delivered \(snapshot.count); first mismatch \(String(describing: first)); first 24: \(Array(snapshot.prefix(24)))")
                XCTFail("Observer commands executed out of submission order across thread startup")
                return
            }
        }
    }

    func testReviewTabExpiryDuringFinalAXCheckCannotAuthorizeAction() {
        let tree = ScriptedAXTree(browser: true), menu = AXUIElementCreateApplication(50_095)
        tree.attributes[Int(CFHash(tree.app))]?["AXMenuBar"] = menu
        tree.attributes[Int(CFHash(menu))] = ["AXTitle": "Close Tab" as CFString, "AXMenuItemCmdChar": "w" as CFString]
        let lock = NSLock(); var finalPhase = false, expired = false, actions = 0
        tree.beforeRead = { name in
            lock.lock(); defer { lock.unlock() }
            if finalPhase && name == "AXDocument" { expired = true }
        }
        tree.client.perform = { _, _ in
            lock.lock(); defer { lock.unlock() }
            XCTAssertTrue(expired); actions += 1; return .success
        }
        var target = BlockingObservation(bundleIdentifier: "com.apple.Safari", pid: 42, windowFrame: nil,
            isBrowser: true, url: "example.com/work", privateWindow: false, at: Date())
        target.windowBoundary = AXReadBoundary(window: tree.window, pid: 42)
        let done = expectation(description: "tab action terminal")
        BlockingTabAXLane(client: tree.client).request(target, permit: AXRequestPermit(), stillCurrent: { true }, revalidate: { completion in
            lock.lock(); let allowed = !expired; finalPhase = true; lock.unlock()
            completion(allowed)
        }, fallback: { XCTFail("Unexpected keyboard fallback") }) { result in
            print("REVIEW tab expiry during final AX: \(result), action count \(actions)")
            XCTAssertEqual(result, .revoked, "Rules must remain valid at the side-effect, not only before the last AX read")
            done.fulfill()
        }
        wait(for: [done], timeout: 3); XCTAssertEqual(actions, 0)
    }
    func testReviewTypingBurstParityWhileSecondInputAXCrossesFlushDeadline() throws {
        richConsent(false)
        var bursts: [[Int]] = []
        for backend in [ContextProvider.Backend.legacy, .background] {
            let date = Date(), params = input(), tree = ScriptedAXTree(), rig = try rig(at: date)
            let snapshot = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: params).snapshot })
            let provider = ContextProvider(client: tree.client, backend: backend, parameters: { params })
            let tap = monitor(rig, provider: provider)
            func replay(_ kind: EventTapPendingInput.Kind) {
                let done = expectation(description: "one input reduced")
                tap.replayInputsForTesting([.init(kind: kind, observedAt: Date(), targetProcessIdentifier: 42, observedContext: snapshot)]) { done.fulfill() }
                wait(for: [done], timeout: 4)
            }
            replay(.keyDown)
            tick(0.85)
            var delayedReads = 0
            tree.beforeRead = { _ in
                if delayedReads < 4 {
                    delayedReads += 1
                    Thread.sleep(forTimeInterval: 0.075)
                }
            }
            replay(.keyDown)
            replay(.scrollWheel)
            tap.stop()
            XCTAssertEqual(tap.privacyInputDropCount, 0); XCTAssertEqual(tap.staleInputDropCount, 0)
            let rows = try events(stream(rig, date: date))
            let counts = rows.filter { $0.kind == .typingBurst }.map { Int($0.metadata?["keystroke_count"] ?? "-1") ?? -1 }
            print("REVIEW \(backend) typing burst sizes after same two public keys and four 75ms AX reads across the 1.1s flush deadline: \(counts)")
            bursts.append(counts)
            try rig.recorder.closeAndWait()
        }
        XCTAssertEqual(bursts[0], [2])
        XCTAssertEqual(bursts[1], bursts[0], "Moving AX off-main must not let the flush timer split an already-pending input burst")
    }
    func testReviewScrollBurstParityWhileSecondInputAXCrossesFlushDeadline() throws {
        richConsent(false)
        var bursts: [[Int]] = []
        for backend in [ContextProvider.Backend.legacy, .background] {
            let date = Date(), params = input(), tree = ScriptedAXTree(), rig = try rig(at: date)
            let snapshot = try XCTUnwrap(AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: params).snapshot })
            let provider = ContextProvider(client: tree.client, backend: backend, parameters: { params })
            let tap = monitor(rig, provider: provider)
            func replay(_ kind: EventTapPendingInput.Kind) {
                let done = expectation(description: "one input reduced")
                tap.replayInputsForTesting([.init(kind: kind, observedAt: Date(), targetProcessIdentifier: 42, observedContext: snapshot)]) { done.fulfill() }
                wait(for: [done], timeout: 4)
            }
            replay(.scrollWheel)
            tick(0.85)
            var delayedReads = 0
            tree.beforeRead = { _ in
                if delayedReads < 4 {
                    delayedReads += 1
                    Thread.sleep(forTimeInterval: 0.075)
                }
            }
            replay(.scrollWheel)
            replay(.keyDown)
            tap.stop()
            XCTAssertEqual(tap.privacyInputDropCount, 0); XCTAssertEqual(tap.staleInputDropCount, 0)
            let rows = try events(stream(rig, date: date))
            let counts = rows.filter { $0.kind == .scrollBurst }.map { $0.scroll?.eventCount ?? -1 }
            print("REVIEW \(backend) scroll burst sizes after same two public scroll inputs and four 75ms AX reads across the 1.1s flush deadline: \(counts)")
            bursts.append(counts)
            try rig.recorder.closeAndWait()
        }
        XCTAssertEqual(bursts[0], [2])
        XCTAssertEqual(bursts[1], bursts[0], "Moving AX off-main must not let the flush timer split an already-pending input burst")
    }

}
#endif
