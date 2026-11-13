#if os(macOS)
import ApplicationServices
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-061: AppKit serves AX requests on Goalong's own elements in-process, on the
/// calling thread. Off main they race the main thread and corrupt the heap, so
/// every AX path refuses Goalong's own PID there. Scripted clients: no real AX RPC.
final class AXSelfProcessGuardTests: XCTestCase {
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private func offMain<T>(_ body: @escaping () -> T) -> T {
        var value: T?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { value = body(); done.signal() }
        done.wait()
        return value!
    }

    private func scriptedClient(reads: @escaping (String) -> Void) -> AXClient {
        AXClient(read: { _, attribute in reads(attribute as String); return AXReadResult(error: .success, value: nil) })
    }

    func testDefaultOwnPIDIsThisProcess() {
        XCTAssertEqual(AXClient().ownPID, ownPID)
        XCTAssertEqual(AXClient.system.ownPID, ownPID)
    }

    func testOwnProcessAttributeReadRefusedOffMainOnly() {
        var reads: [String] = []
        let lock = NSLock()
        let client = scriptedClient { name in lock.lock(); reads.append(name); lock.unlock() }
        let own = AXUIElementCreateApplication(ownPID)
        let foreign = AXUIElementCreateApplication(50_101)
        let results: (AXError, AXError) = offMain {
            AXAccess.withClient(client) {
                var value: CFTypeRef?
                return (AXAccess.copyAttributeValue(own, "AXFocusedUIElement" as CFString, &value),
                        AXAccess.copyAttributeValue(foreign, "AXTitle" as CFString, &value))
            }
        }
        XCTAssertEqual(results.0, .cannotComplete)
        XCTAssertEqual(results.1, .success)
        XCTAssertEqual(reads, ["AXTitle"])
        // On main AppKit serves its own tree on its own thread: no race, no refusal.
        XCTAssertFalse(client.refusesOwnProcess(own, onMain: true))
        XCTAssertTrue(client.refusesOwnProcess(own, onMain: false))
        XCTAssertFalse(client.refusesOwnProcess(foreign, onMain: false))
    }

    func testOwnProcessObserverAndActionsRefusedOffMain() {
        let client = scriptedClient { _ in }
        var calls: [String] = []
        let lock = NSLock()
        func log(_ name: String) { lock.lock(); calls.append(name); lock.unlock() }
        client.createObserver = { _, _, _ in log("create"); return .success }
        client.perform = { _, _ in log("perform"); return .success }
        client.setTimeout = { _, _ in log("timeout"); return .success }
        let own = AXUIElementCreateApplication(ownPID)
        let ownPID = ownPID
        let errors: [AXError] = offMain {
            AXAccess.withClient(client) {
                var observer: AXObserver?
                return [AXAccess.createObserver(ownPID, { _, _, _, _ in }, &observer),
                        AXAccess.performAction(own, kAXPressAction as CFString),
                        AXAccess.setMessagingTimeout(own, 0.1)]
            }
        }
        XCTAssertEqual(errors, [.cannotComplete, .cannotComplete, .cannotComplete])
        XCTAssertEqual(calls, [])
    }

    func testSystemWideHitTestOverOwnWindowRefusedOffMain() {
        let client = scriptedClient { _ in }
        var hitTests = 0
        client.hitTest = { _, _, _, _ in hitTests += 1; return .success }
        var target: pid_t? = ownPID
        client.systemWideTarget = { _ in target }
        let systemWide = AXUIElementCreateSystemWide()
        var errors: [AXError] = offMain {
            AXAccess.withClient(client) {
                var element: AXUIElement?
                return [AXAccess.copyElementAtPosition(systemWide, 10, 10, &element)]
            }
        }
        target = 50_102
        errors += offMain {
            AXAccess.withClient(client) {
                var element: AXUIElement?
                return [AXAccess.copyElementAtPosition(systemWide, 10, 10, &element)]
            }
        }
        XCTAssertEqual(errors, [.cannotComplete, .success])
        XCTAssertEqual(hitTests, 1)
    }

    func testObserverOwnerNeverAttachesToGoalongItself() {
        let client = scriptedClient { _ in }
        var created = 0
        client.createObserver = { _, _, _ in created += 1; return .cannotComplete }
        let published = expectation(description: "coverage published")
        let owner = AXObserverOwner(client: client) { _, coverage, trigger in
            XCTAssertFalse(coverage); XCTAssertNil(trigger); published.fulfill()
        }
        let thread = AXObservationThread()
        let goalong = ForegroundAXApplication(pid: ownPID, name: "Goalong", bundleIdentifier: "ai.goalong.localhistory")
        thread.submit { owner.attach(to: goalong, generation: UUID()) }
        wait(for: [published], timeout: 3)
        let finished = expectation(description: "shutdown")
        thread.shutdown { owner.detach(); finished.fulfill() }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(created, 0)
    }
}
#endif
