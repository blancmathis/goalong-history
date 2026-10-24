#if os(macOS)
    import ApplicationServices
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    /// R49: second energy pass (E1-E4 of the R48 audit).
    final class EnergyPass2Tests: XCTestCase {
        // MARK: E1 / E2 — context fallback poll

        private func historyInterval(idle: TimeInterval, coverage: Bool) -> TimeInterval? {
            ContextMonitor.nextPollInterval(configuredInterval: 0.65, idleSeconds: idle, isCapturing: true,
                                            suppressionReason: nil, eventDrivenCoverageAvailable: coverage)
        }

        func testHistoryPollBacksOffWhenIdleEvenWithoutAXCoverage() {
            XCTAssertEqual(historyInterval(idle: 0, coverage: false), 0.65)
            XCTAssertEqual(historyInterval(idle: 14.9, coverage: false), 0.65)
            XCTAssertEqual(historyInterval(idle: 15, coverage: false), 2)
            XCTAssertEqual(historyInterval(idle: 59, coverage: false), 2)
            XCTAssertEqual(historyInterval(idle: 60, coverage: false), 5)
            XCTAssertEqual(historyInterval(idle: 3_600, coverage: false), 5)
        }

        func testHistoryPollFloorIsTwoSecondsWhileTypingWithReliableCoverage() {
            for idle in stride(from: 0.0, to: 15, by: 0.5) {
                XCTAssertEqual(historyInterval(idle: idle, coverage: true), 2, "idle \(idle) s")
            }
            // A slower configured cadence is still honoured.
            XCTAssertEqual(ContextMonitor.nextPollInterval(configuredInterval: 3, idleSeconds: 0, isCapturing: true,
                                                           suppressionReason: nil, eventDrivenCoverageAvailable: true), 3)
        }

        func testBlockingPollBacksOffWhenIdleAndStaysFastAfterRecentInput() {
            for idle in stride(from: 0.0, to: 15, by: 0.5) {
                XCTAssertEqual(ContextMonitor.blockingPollInterval(idleSeconds: idle, sessionAvailable: true), 0.75)
            }
            XCTAssertEqual(ContextMonitor.blockingPollInterval(idleSeconds: 15, sessionAvailable: true), 2)
            XCTAssertEqual(ContextMonitor.blockingPollInterval(idleSeconds: 60, sessionAvailable: true), 5)
            XCTAssertEqual(ContextMonitor.blockingPollInterval(idleSeconds: 3_600, sessionAvailable: true), 5)
            XCTAssertEqual(ContextMonitor.blockingPollInterval(idleSeconds: 0, sessionAvailable: false), 60)
        }

        // MARK: E3 — checkpoint barrier, seal full sync

        func testCheckpointUsesABarrierAndSealsKeepTheFullSync() {
            XCTAssertEqual(IntegrityStateStore.checkpointSync, .barrier)
            XCTAssertEqual(MinuteSealer.sealSync, .full)
        }

        private func hash(_ value: Int) -> String { String(format: "%064x", value) }

        /// After a crash the checkpoint may be missing, torn or older than the journals.
        /// Startup rebuilds it from the journal tails and raises no integrity error.
        func testLostTornOrOlderCheckpointIsRebuiltWithoutIntegrityAlarm() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("r49-checkpoint-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("integrity-state.json")

            let live = IntegrityStateStore(fileURL: file, prepareStorage: {})
            for sequence in 1...3 { try live.commitPersistedEvent(sequence: UInt64(sequence), eventHash: hash(sequence)) }
            try live.checkpointPersistedEvents()
            XCTAssertNil(try live.commitPersistedAnchor(sequence: 1, anchorHash: hash(100)))
            let older = try Data(contentsOf: file)
            for sequence in 4...5 { try live.commitPersistedEvent(sequence: UInt64(sequence), eventHash: hash(sequence)) }
            try live.checkpointPersistedEvents()
            XCTAssertNil(try live.commitPersistedAnchor(sequence: 2, anchorHash: hash(101)))
            let expected = live.snapshot

            let crashes: [(String, () throws -> Void)] = [
                ("older", { try older.write(to: file) }),
                ("lost", { try FileManager.default.removeItem(at: file) }),
                ("torn", { try older.prefix(older.count / 2).write(to: file) }),
                ("empty", { try Data().write(to: file) }),
            ]
            for (name, crash) in crashes {
                try crash()
                let restarted = IntegrityStateStore(fileURL: file, prepareStorage: {})
                XCTAssertNoThrow(try restarted.reconcilePersistedEventTail(sequence: 5, eventHash: hash(5)), name)
                XCTAssertNoThrow(try restarted.reconcilePersistedAnchorTail(sequence: 2, anchorHash: hash(101)), name)
                XCTAssertEqual(restarted.snapshot, expected, name)
                // The rebuilt checkpoint is itself valid for the next launch.
                let next = IntegrityStateStore(fileURL: file, prepareStorage: {})
                XCTAssertEqual(next.snapshot, expected, name)
            }
        }

        // MARK: E4 — AX notifications coalesced on the AX thread

        private let value = kAXValueChangedNotification as String
        private let focusWindow = kAXFocusedWindowChangedNotification as String

        func testValueStormGivesOneTriggerAfterTheBurstWithTheOldTrailingDelay() {
            var coalescer = AXNotificationCoalescer()
            var deadline: TimeInterval = 0
            for step in 0..<100 { deadline = coalescer.add(value, at: Double(step) * 0.05) }
            XCTAssertEqual(deadline, 4.95 + 1.4, accuracy: 0.000_1)
            XCTAssertNil(coalescer.fire(at: deadline - 0.01))
            XCTAssertEqual(coalescer.fire(at: deadline), AccessibilityEventMonitor.shortName(value))
            XCTAssertNil(coalescer.fire(at: deadline + 10), "one trigger per burst")
        }

        func testStructuralChangeShortensTheBurstAndJoinsItsTrigger() {
            var coalescer = AXNotificationCoalescer()
            _ = coalescer.add(value, at: 0)
            let deadline = coalescer.add(focusWindow, at: 0.5)
            XCTAssertEqual(deadline, 0.5 + 0.18, accuracy: 0.000_1)
            XCTAssertEqual(coalescer.fire(at: deadline),
                           [value, focusWindow].map(AccessibilityEventMonitor.shortName).sorted().joined(separator: "+"))
        }

        func testResetDropsAPendingBurst() {
            var coalescer = AXNotificationCoalescer()
            _ = coalescer.add(value, at: 0)
            coalescer.reset()
            XCTAssertNil(coalescer.fire(at: 100))
            XCTAssertNil(coalescer.deadline)
        }

        func testMainFacadeNoLongerSchedulesOneHopPerNotification() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent(
                "Sources/LocalHistoryApp/AccessibilityEventMonitor.swift"), encoding: .utf8)
            XCTAssertFalse(source.contains("DispatchQueue.main.asyncAfter"))
            XCTAssertTrue(source.contains("coalescer.add(notification"))
        }
    }
#endif
