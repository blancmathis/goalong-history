#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class JevStabilityTests: XCTestCase {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var number = 0
        func increment() { lock.lock(); number += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return number }
    }

    /// Reproduces the actual 0.6.40 wait cycle: the main thread is draining the
    /// writer while the writer emits a protection boundary to a queue:.main observer.
    /// Use a finite semaphore wait so the old implementation fails rather than
    /// permanently hanging the suite. No real recorder, history or API is started.
    @MainActor func testWriterPrivacyBoundaryNeverWaitsForMainThread() throws {
        let center = NotificationCenter(), count = Count()
        let inbox = JevIngress(notificationCenter: center)
        let observer = center.addObserver(forName: .jevBoundaryChanged, object: nil, queue: .main) { _ in
            XCTAssertTrue(Thread.isMainThread)
            count.increment()
        }
        defer { center.removeObserver(observer) }
        let writer = DispatchQueue(label: "test.goalong.writer-boundary")
        let now = Date()
        for kind in [EventKind.sessionLocked, .systemSleep, .captureSuppressed, .secureInputSuppressed, .historyCleared, .recorderStopped, .recordingPaused] {
            inbox.configure(enabled: true, now: now)
            let previous = inbox.generation
            let drained = DispatchSemaphore(value: 0)
            writer.async {
                inbox.receive(HistoryEvent(sessionID: "synthetic-stability", kind: kind))
                drained.signal()
            }
            // Deliberately do not run the main loop before the writer is done.
            XCTAssertEqual(drained.wait(timeout: .now() + 2), .success, "Writer must drain during \(kind)")
            XCTAssertTrue(inbox.isBlocked, "Privacy must be invalidated synchronously")
            XCTAssertGreaterThan(inbox.generation, previous)
            XCTAssertNil(inbox.take(start: now, end: now.addingTimeInterval(15)))
        }
        let deadline = Date().addingTimeInterval(2)
        while count.value < 7 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(count.value, 7, "Deferred cancellation is still delivered to the UI")
    }
    @MainActor func testRepeatedBlockedEventsCoalesceAndNeverDelayWriter() {
        let center = NotificationCenter(), count = Count()
        let inbox = JevIngress(notificationCenter: center)
        let observer = center.addObserver(forName: .jevBoundaryChanged, object: nil, queue: .main) { _ in count.increment() }
        defer { center.removeObserver(observer) }
        inbox.configure(enabled: true)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.goalong.boundary-stress").async {
            for _ in 0..<1000 { inbox.boundary() }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(inbox.isBlocked)
        let deadline = Date().addingTimeInterval(2)
        while count.value == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(count.value, 1, "Repeated protected events must not flood the UI")
    }
}
#endif
