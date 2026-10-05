#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class AXBackgroundLaneTests: XCTestCase {
    private func input() -> ContextReadParameters {
        let app = ForegroundAXApplication(pid: 42, name: "Fixture", bundleIdentifier: "com.apple.Safari")
        return ContextReadParameters(foregroundApplication: app, applications: [42: app], config: .default,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true, idleSeconds: 1,
            privacy: GoalongPrivacyPolicy(), pauseRevision: "initial")
    }

    func testBlockingLaneMatchesLegacyAndDoesNotWaitForUnrelatedWork() {
        let tree = ScriptedAXTree(browser: true)
        let parameters = input()
        let baseline = AXAccess.withClient(tree.client) { ContextAXReader().captureBlocking(parameters: parameters) }
        let complete = expectation(description: "reserved lane result")
        let lane = BlockingAXLane(client: tree.client)
        tree.beforeRead = { _ in XCTAssertFalse(Thread.isMainThread) }
        lane.request(parameters) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result?.url, baseline?.url)
            XCTAssertEqual(result?.bundleIdentifier, baseline?.bundleIdentifier)
            XCTAssertEqual(result?.pid, baseline?.pid)
            XCTAssertEqual(result?.privateWindow, baseline?.privateWindow)
            XCTAssertEqual(result?.isBrowser, baseline?.isBrowser)
            XCTAssertEqual(result?.windowIdentity, baseline?.windowIdentity)
            complete.fulfill()
        }
        wait(for: [complete], timeout: 3)
    }

    func testBlockedReaderDoesNotBlockMainAndOldGenerationCannotPublish() {
        let tree = ScriptedAXTree(browser: true)
        let input = input()
        let started = expectation(description: "worker entered AX")
        let finished = expectation(description: "revoked result has terminal completion")
        let release = DispatchSemaphore(value: 0)
        var held = false
        tree.beforeRead = { _ in
            XCTAssertFalse(Thread.isMainThread)
            if !held {
                held = true
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            }
        }
        let provider = ContextProvider(client: tree.client, parameters: { input })
        provider.requestBlocking { observation in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(observation)
            finished.fulfill()
        }
        // Reaching this line proves request admission did not wait for the reader.
        wait(for: [started], timeout: 3)
        provider.invalidateBlocking()
        release.signal()
        wait(for: [finished], timeout: 3)
    }

    func testPrivateBlockingLaneReadsNoAddressOrText() {
        let tree = ScriptedAXTree(browser: true)
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "Private Browsing" as CFString
        let complete = expectation(description: "private observation")
        let lane = BlockingAXLane(client: tree.client)
        lane.request(input()) { result in
            XCTAssertTrue(result?.privateWindow == true)
            XCTAssertNil(result?.url)
            XCTAssertFalse(tree.reads.contains("AXDocument"))
            XCTAssertFalse(tree.reads.contains("AXValue"))
            XCTAssertFalse(tree.reads.contains("AXSelectedText"))
            complete.fulfill()
        }
        wait(for: [complete], timeout: 3)
    }

    func testObserverLifecycleAllRPCsOffMainAndRetiredCallbacksIgnored() throws {
        let tree = ScriptedAXTree()
        let thread = AXObservationThread()
        let attached = expectation(description: "attached")
        let detached = expectation(description: "detached asynchronously")
        var callback: AXObserverCallback?
        var savedObserver: AXObserver?
        var tokens: [AXObserverOwner.Attachment] = []
        var notifications = 0
        tree.client.createObserver = { _, cb, output in
            XCTAssertFalse(Thread.isMainThread)
            callback = cb
            let error = AXObserverCreate(ProcessInfo.processInfo.processIdentifier, cb, output)
            savedObserver = output.pointee
            return error
        }
        tree.client.addNotification = { _, _, _, pointer in
            XCTAssertFalse(Thread.isMainThread)
            tokens.append(Unmanaged<AXObserverOwner.Attachment>.fromOpaque(pointer!).takeUnretainedValue())
            return .success
        }
        tree.client.removeNotification = { _, _, _ in XCTAssertFalse(Thread.isMainThread); return .success }
        tree.beforeRead = { _ in XCTAssertFalse(Thread.isMainThread) }
        let owner = AXObserverOwner(client: tree.client) { _, coverage, notification in
            XCTAssertFalse(Thread.isMainThread)
            if notification != nil { notifications += 1 }
            else { XCTAssertTrue(coverage); attached.fulfill() }
        }
        let application = ForegroundAXApplication(pid: 42, name: "Fixture", bundleIdentifier: "test.fixture")
        thread.submit { owner.attach(to: application, generation: UUID()) }
        wait(for: [attached], timeout: 3)
        XCTAssertFalse(tokens.isEmpty)
        thread.shutdown {
            owner.detach()
            if let callback, let observer = savedObserver, let token = tokens.first {
                callback(observer, tree.focus, kAXValueChangedNotification as CFString, Unmanaged.passUnretained(token).toOpaque())
            }
            XCTAssertEqual(notifications, 0)
            detached.fulfill()
        }
        wait(for: [detached], timeout: 3)
    }
}
#endif
