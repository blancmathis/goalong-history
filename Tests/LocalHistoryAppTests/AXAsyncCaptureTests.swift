#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class AXAsyncCaptureTests: XCTestCase {
    private func input(bundle: String = "test.native", configure: (inout RecorderConfig) -> Void = { _ in }) -> ContextReadParameters {
        let app = ForegroundAXApplication(pid: 42, name: "Fixture", bundleIdentifier: bundle, instanceStartedAt: Date(timeIntervalSince1970: 1))
        var config = RecorderConfig.default
        config.captureWindowTitles = true; config.captureElementLabels = true
        configure(&config)
        var privacy = GoalongPrivacyPolicy(); privacy.revision = "none"
        return ContextReadParameters(foregroundApplication: app, applications: [42: app], config: config,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true, idleSeconds: 1,
            privacy: privacy, pauseRevision: "initial")
    }

    func testProductionDefaultAndGlobalRPCAssertionAreBackground() {
        XCTAssertTrue(AXClient.system.requiresBackgroundThread)
        let tree = ScriptedAXTree(), input = input()
        let provider = ContextProvider(client: tree.client, parameters: { input })
        XCTAssertEqual(provider.backend, .background)
        let done = expectation(description: "public capture")
        tree.beforeRead = { _ in XCTAssertFalse(Thread.isMainThread) }
        provider.requestCapture { snapshot in
            XCTAssertTrue(Thread.isMainThread); XCTAssertNotNil(snapshot); done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    func testBackgroundCorpusMatchesLegacyWithoutFilteringAnySnapshotField() throws {
        for (bundle, secure, excluded, domain, labels) in [
            ("test.native", false, false, false, true),
            ("com.apple.Safari", false, false, false, true),
            ("test.wrapper", false, false, false, true),
            ("test.native", true, false, false, true),
            ("test.native", false, true, false, true),
            ("com.apple.Safari", false, false, true, true),
            ("test.native", false, false, false, false)
        ] {
            let input = input(bundle: bundle) {
                $0.captureElementLabels = labels
                if excluded { $0.excludedBundleIdentifiers = [bundle] }
                if domain { $0.excludedDomains = ["example.com"] }
            }
            let baselineTree = ScriptedAXTree(secure: secure, browser: bundle != "test.native")
            let baseline = ContextProvider(client: baselineTree.client, backend: .legacy, parameters: { input }).capture()
            let tree = ScriptedAXTree(secure: secure, browser: bundle != "test.native")
            tree.beforeRead = { _ in XCTAssertFalse(Thread.isMainThread) }
            let provider = ContextProvider(client: tree.client, parameters: { input })
            let done = expectation(description: bundle)
            provider.requestCapture { snapshot in XCTAssertEqual(snapshot, baseline); done.fulfill() }
            wait(for: [done], timeout: 3)
        }
    }

    func testMixedPrivateResultGatesEveryHistoricalRPCInTheSameRequest() {
        let tree = ScriptedAXTree(browser: true), input = input(bundle: "com.apple.Safari")
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "Private Browsing" as CFString
        let baselineTree = ScriptedAXTree(browser: true)
        baselineTree.attributes[Int(CFHash(baselineTree.window))]?["AXTitle"] = "Private Browsing" as CFString
        _ = AXAccess.withClient(baselineTree.client) { ContextAXReader().captureBlocking(parameters: input) }
        tree.beforeRead = { _ in XCTAssertFalse(Thread.isMainThread) }
        let provider = ContextProvider(client: tree.client, parameters: { input })
        let done = expectation(description: "private terminal result")
        var sequence: [String] = []
        provider.requestCapture(blockingSink: { observation in
            XCTAssertTrue(observation.privateWindow); sequence.append("blocking")
        }) { snapshot in
            XCTAssertEqual(snapshot?.suppressionReason, .privateBrowserWindow)
            XCTAssertNil(snapshot?.window); XCTAssertNil(snapshot?.url); XCTAssertNil(snapshot?.focusedElement)
            sequence.append("history"); done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(sequence, ["blocking", "history"])
        XCTAssertEqual(tree.reads, baselineTree.reads, "Only the blocking classifier may read; history adds zero RPCs")
        for forbidden in ["AXFocusedApplication", "AXFocusedUIElement", "AXDocument", "AXValue", "AXSelectedText"] {
            XCTAssertFalse(tree.reads.contains(forbidden), forbidden)
        }
    }

    func testBlockingStillCompletesWhenHistoryRPCIsHeldAndMainContinues() {
        let tree = ScriptedAXTree(browser: true), input = input(bundle: "com.apple.Safari")
        let entered = expectation(description: "held history RPC"), history = expectation(description: "history terminal")
        let blocking = expectation(description: "reserved lane not held behind history")
        let main = expectation(description: "main responds while history is held")
        let release = DispatchSemaphore(value: 0)
        tree.beforeRead = { name in
            XCTAssertFalse(Thread.isMainThread)
            if name == "AXFocusedApplication" {
                entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            }
        }
        let provider = ContextProvider(client: tree.client, parameters: { input })
        provider.requestCapture { XCTAssertNotNil($0); history.fulfill() }
        wait(for: [entered], timeout: 3)
        provider.requestBlocking { XCTAssertEqual($0?.url, "example.com/work"); blocking.fulfill() }
        DispatchQueue.main.async { main.fulfill() }
        wait(for: [blocking, main], timeout: 3)
        release.signal()
        wait(for: [history], timeout: 3)
    }

    func testChangedWindowAfterPublicBlockingCannotAuthorizeHistoricalContent() {
        let tree = ScriptedAXTree(browser: true), input = input(bundle: "com.apple.Safari")
        let privateWindow = AXUIElementCreateApplication(50_091)
        tree.attributes[Int(CFHash(privateWindow))] = ["AXRole": "AXWindow" as CFString,
            "AXTitle": "Private Browsing" as CFString, "AXDocument": "https://private.example" as CFString]
        let provider = ContextProvider(client: tree.client, parameters: { input })
        let done = expectation(description: "changed boundary terminal")
        provider.requestCapture(blockingSink: { observation in
            XCTAssertFalse(observation.privateWindow)
            tree.attributes[Int(CFHash(tree.app))]?["AXFocusedWindow"] = privateWindow
            tree.reads.removeAll()
        }) { snapshot in XCTAssertNil(snapshot); done.fulfill() }
        wait(for: [done], timeout: 3)
        for content in ["AXTitle", "AXDescription", "AXDocument", "AXValue", "AXSelectedText", "AXFocusedUIElement"] {
            XCTAssertFalse(tree.reads.contains(content), content)
        }
    }

    func testHistoryAndInputContinuationsAreFIFODespiteSlowFirstRead() {
        let tree = ScriptedAXTree(), input = input()
        let entered = expectation(description: "first RPC"), done = expectation(description: "FIFO")
        done.expectedFulfillmentCount = 3
        let release = DispatchSemaphore(value: 0)
        var held = false
        tree.beforeRead = { _ in
            XCTAssertFalse(Thread.isMainThread)
            if !held { held = true; entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success) }
        }
        let provider = ContextProvider(client: tree.client, parameters: { input })
        var delivered: [String] = []
        provider.requestCapture { _ in delivered.append("context"); done.fulfill() }
        provider.requestInput(at: .zero, expectedProcessIdentifier: 42) { result in
            XCTAssertNil(result.suppression); XCTAssertEqual(result.element?.label, "Editor")
            delivered.append("down"); done.fulfill()
        }
        provider.requestInput(at: nil, expectedProcessIdentifier: 42) { _ in delivered.append("up"); done.fulfill() }
        wait(for: [entered], timeout: 3)
        XCTAssertTrue(delivered.isEmpty)
        release.signal(); wait(for: [done], timeout: 3)
        XCTAssertEqual(delivered, ["context", "down", "up"])
    }

    func testRecycledPIDCannotPublishOldHistoryAndDoesNotClearNewJob() {
        let tree = ScriptedAXTree()
        var current = input()
        let entered = expectation(description: "old job entered"), done = expectation(description: "terminal jobs")
        done.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        var held = false
        tree.beforeRead = { _ in
            if !held { held = true; entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success) }
        }
        let provider = ContextProvider(client: tree.client, parameters: { current })
        provider.requestCapture { XCTAssertNil($0); done.fulfill() }
        wait(for: [entered], timeout: 3)
        let app = ForegroundAXApplication(pid: 42, name: "Fixture", bundleIdentifier: "test.native", instanceStartedAt: Date(timeIntervalSince1970: 2))
        current = ContextReadParameters(foregroundApplication: app, applications: [42: app], config: current.config,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true, idleSeconds: 1,
            privacy: current.privacy, pauseRevision: "initial")
        provider.invalidateHistory()
        provider.requestCapture { XCTAssertNotNil($0); done.fulfill() }
        release.signal(); wait(for: [done], timeout: 3)
    }

    func testUncataloguedFocusBridgeResolvesOnMainWithExactlyOneAXProbe() {
        let tree = ScriptedAXTree(), input = input()
        tree.client.getPID = { _, output in output.pointee = 84; return .success }
        var resolutions: [pid_t] = []
        let provider = ContextProvider(client: tree.client, parameters: { input }, applicationResolver: { pid in
            XCTAssertTrue(Thread.isMainThread); resolutions.append(pid)
            return ForegroundAXApplication(pid: pid, name: "Control Center", bundleIdentifier: "com.apple.controlcenter")
        })
        let done = expectation(description: "system focus")
        provider.requestCapture { XCTAssertEqual($0?.app.processIdentifier, 84); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(resolutions, [84]); XCTAssertEqual(tree.reads.filter { $0 == "AXFocusedApplication" }.count, 1)
    }

    func testSecureInputReadHasNoHitTestOrContentEnrichment() {
        let tree = ScriptedAXTree(secure: true), input = input()
        tree.client.hitTest = { _, _, _, _ in XCTFail("Secure input must not hit-test"); return .failure }
        let provider = ContextProvider(client: tree.client, parameters: { input })
        let done = expectation(description: "secure terminal")
        provider.requestInput(at: .zero, expectedProcessIdentifier: 42) {
            XCTAssertEqual($0.suppression, .secureInput); XCTAssertNil($0.element); done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(Set(tree.reads).isSubset(of: ["AXFocusedUIElement", "AXRole", "AXSubrole", "AXProtectedContent"]))
    }

    func testRevocationStopsSubsequentRPCsAtTheClientBoundary() {
        let tree = ScriptedAXTree(), permit = AXRequestPermit()
        let done = expectation(description: "worker revoked between calls")
        DispatchQueue.global().async {
            AXAccess.withBackgroundClient(tree.client, permit: permit) {
                XCTAssertEqual(AXReader.string(tree.window, attribute: "AXTitle" as CFString), "Document")
                permit.revoke()
                var value: CFTypeRef?
                XCTAssertEqual(AXAccess.copyAttributeValue(tree.focus, "AXValue" as CFString, &value), .cannotComplete)
                XCTAssertNil(value)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(tree.reads, ["AXTitle"])
    }

    func testEqualTitlesDoNotAuthorizeADifferentAXWindow() {
        let tree = ScriptedAXTree(), original = AXReadBoundary(window: treeWindow(), pid: 42)
        XCTAssertNotEqual(original, AXReadBoundary(window: tree.window, pid: 42))
        let done = expectation(description: "retained identity check")
        DispatchQueue.global().async {
            AXAccess.withBackgroundClient(tree.client) { XCTAssertFalse(original.matchesFocusedWindow()) }
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
    private func treeWindow() -> AXUIElement { AXUIElementCreateApplication(50_090) }

    func testContinuationQueueSaturationIsBoundedCountedAndFIFO() {
        let queue = AXContinuationQueue(capacity: 2)
        var release: (() -> Void)?, values: [Int] = []
        XCTAssertTrue(queue.enqueue { done in values.append(1); release = done })
        let done = expectation(description: "second admitted job")
        XCTAssertTrue(queue.enqueue { finish in values.append(2); finish(); done.fulfill() })
        XCTAssertFalse(queue.enqueue { _ in XCTFail("Saturated job cannot run") })
        XCTAssertEqual(queue.rejectedCount, 1); XCTAssertEqual(values, [1])
        release?(); wait(for: [done], timeout: 3); XCTAssertEqual(values, [1, 2])
    }

    func testTabActionTimeoutIsUncertainAndNeverFallsBackToKeyboard() {
        let tree = ScriptedAXTree(browser: true), menu = AXUIElementCreateApplication(50_095)
        tree.attributes[Int(CFHash(tree.app))]?["AXMenuBar"] = menu
        tree.attributes[Int(CFHash(menu))] = ["AXTitle": "Close Tab" as CFString, "AXMenuItemCmdChar": "w" as CFString]
        var actions = 0, fallbacks = 0, validations = 0
        tree.client.perform = { _, _ in XCTAssertFalse(Thread.isMainThread); actions += 1; return .cannotComplete }
        tree.beforeRead = { _ in XCTAssertFalse(Thread.isMainThread) }
        var target = BlockingObservation(bundleIdentifier: "com.apple.Safari", pid: 42, windowFrame: nil,
            isBrowser: true, url: "example.com/work", privateWindow: false, at: Date())
        target.windowBoundary = AXReadBoundary(window: tree.window, pid: 42)
        let lane = BlockingTabAXLane(client: tree.client), done = expectation(description: "ambiguous action")
        lane.request(target, permit: AXRequestPermit(), stillCurrent: { true }, revalidate: {
            XCTAssertTrue(Thread.isMainThread); validations += 1; $0(true)
        }, fallback: { fallbacks += 1 }) { result in
            XCTAssertEqual(result, .uncertain); done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(actions, 1); XCTAssertEqual(fallbacks, 0); XCTAssertEqual(validations, 1)
    }
}
#endif
