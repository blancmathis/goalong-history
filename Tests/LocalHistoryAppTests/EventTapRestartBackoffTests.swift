#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    final class EventTapRestartBackoffTests: XCTestCase {
        func testUnexpectedRestartDelayUsesExponentialBackoffAndCap() {
            XCTAssertEqual(
                EventTapMonitor.unexpectedRestartDelay(
                    consecutiveAttempt: 1,
                    jitterUnit: 0.5
                ),
                1,
                accuracy: 0.0001
            )
            XCTAssertEqual(
                EventTapMonitor.unexpectedRestartDelay(
                    consecutiveAttempt: 2,
                    jitterUnit: 0.5
                ),
                2,
                accuracy: 0.0001
            )
            XCTAssertEqual(
                EventTapMonitor.unexpectedRestartDelay(
                    consecutiveAttempt: 16,
                    jitterUnit: 0.5
                ),
                60,
                accuracy: 0.0001
            )
        }

        func testUnexpectedRestartDelayClampsJitterAndInvalidAttempts() {
            XCTAssertEqual(
                EventTapMonitor.unexpectedRestartDelay(
                    consecutiveAttempt: 0,
                    jitterUnit: -10
                ),
                0.85,
                accuracy: 0.0001
            )
            XCTAssertEqual(
                EventTapMonitor.unexpectedRestartDelay(
                    consecutiveAttempt: 1,
                    jitterUnit: 10
                ),
                1.15,
                accuracy: 0.0001
            )
            XCTAssertEqual(
                EventTapMonitor.unexpectedRestartDelay(
                    consecutiveAttempt: 1,
                    jitterUnit: .nan
                ),
                1,
                accuracy: 0.0001
            )
        }

        func testStableRuntimeResetThresholdIsLongerThanAFlap() {
            XCTAssertGreaterThanOrEqual(
                EventTapMonitor.stableRunDurationBeforeRestartReset,
                EventTapMonitor.maximumUnexpectedRestartDelay
            )
        }

        func testRestartGateKeepsOnlyOnePendingAttempt() {
            let virtual = VirtualEventTapRestartScheduler()
            let gate = EventTapRestartGate(schedule: virtual.schedule)
            var attempts = 0

            XCTAssertTrue(gate.schedule(after: 1) { attempts += 1 })
            XCTAssertFalse(gate.schedule(after: 2) { attempts += 100 })
            XCTAssertTrue(gate.isScheduled)
            XCTAssertEqual(virtual.scheduledDelays, [1])

            virtual.fireNextEvenIfCancelled()

            XCTAssertEqual(attempts, 1)
            XCTAssertFalse(gate.isScheduled)
        }

        func testCancelledRestartCannotFireOrRestartAfterStop() {
            let virtual = VirtualEventTapRestartScheduler()
            let gate = EventTapRestartGate(schedule: virtual.schedule)
            var attempts = 0

            XCTAssertTrue(gate.schedule(after: 60) { attempts += 1 })
            gate.cancel()
            XCTAssertFalse(gate.isScheduled)

            // Model a hostile scheduler that invokes an already-submitted closure
            // despite cancellation. The gate token must still reject it.
            virtual.fireNextEvenIfCancelled()

            XCTAssertEqual(attempts, 0)
            XCTAssertEqual(virtual.cancelledTaskCount, 1)
        }

        func testConsumedRestartCanScheduleTheNextBackoffAttempt() {
            let virtual = VirtualEventTapRestartScheduler()
            let gate = EventTapRestartGate(schedule: virtual.schedule)
            var attempts = 0

            XCTAssertTrue(
                gate.schedule(after: 1) {
                    attempts += 1
                    XCTAssertTrue(gate.schedule(after: 2) { attempts += 1 })
                })

            virtual.fireNextEvenIfCancelled()
            XCTAssertTrue(gate.isScheduled)
            XCTAssertEqual(virtual.scheduledDelays, [1, 2])

            virtual.fireNextEvenIfCancelled()
            XCTAssertEqual(attempts, 2)
            XCTAssertFalse(gate.isScheduled)
        }
    }

    private final class VirtualEventTapRestartScheduler {
        private final class Task: EventTapRestartScheduledTask {
            let action: () -> Void
            private(set) var isCancelled = false

            init(action: @escaping () -> Void) {
                self.action = action
            }

            func cancel() {
                isCancelled = true
            }
        }

        private var tasks: [Task] = []
        private var nextTaskIndex = 0
        private(set) var scheduledDelays: [TimeInterval] = []

        lazy var schedule: EventTapRestartGate.Schedule = { [weak self] delay, action in
            let task = Task(action: action)
            self?.scheduledDelays.append(delay)
            self?.tasks.append(task)
            return task
        }

        var cancelledTaskCount: Int {
            tasks.filter(\.isCancelled).count
        }

        func fireNextEvenIfCancelled() {
            guard nextTaskIndex < tasks.count else {
                XCTFail("Expected a scheduled restart task")
                return
            }
            let task = tasks[nextTaskIndex]
            nextTaskIndex += 1
            task.action()
        }
    }
#endif
