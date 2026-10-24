#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    /// R44: wakeup policies for agent signals, the blocking fallback poll and the permission watchdog.
    final class EnergyWakeupPolicyTests: XCTestCase {
        // MARK: Agent signals (virtual clock)

        /// Drives the coalescer like the runtime: a signal arms a one-shot deadline, the deadline fires a scan.
        private func scans(signals: [TimeInterval], until end: TimeInterval) -> [TimeInterval] {
            var coalescer = AgentSignalCoalescer()
            var armed: TimeInterval?
            var scans: [TimeInterval] = []
            func fireDue(at now: TimeInterval) {
                if let deadline = armed, deadline <= now {
                    armed = nil
                    if coalescer.fire() { scans.append(deadline) }
                }
            }
            for time in signals.sorted() {
                fireDue(at: time)
                if let deadline = coalescer.signal(at: time) { armed = deadline }
            }
            fireDue(at: end)
            return scans
        }

        func testHundredSignalsInOneSecondGiveOneScanAfterTheBurst() {
            let signals = (0..<100).map { Double($0) / 100 }
            let result = scans(signals: signals, until: 60)
            XCTAssertEqual(result.count, 1)
            XCTAssertGreaterThanOrEqual(result[0], signals.last!)
            XCTAssertLessThanOrEqual(result[0], 5)
        }

        func testSteadySignalsScanAtMostOncePerWindowAndAlwaysAfterTheLastOne() {
            let signals = (0..<100).map { Double($0) / 10 }  // one every 0.1 s for 10 s
            let result = scans(signals: signals, until: 60)
            XCTAssertLessThanOrEqual(result.count, 6)
            for (earlier, later) in zip(result, result.dropFirst()) {
                XCTAssertGreaterThanOrEqual(later - earlier, AgentSignalCoalescer.window - 0.000_1)
            }
            XCTAssertGreaterThanOrEqual(result.last!, signals.last!)
        }

        func testLoneSignalStillGetsItsScanAndResetDisarms() {
            XCTAssertEqual(scans(signals: [42], until: 60), [42 + AgentSignalCoalescer.window])
            var coalescer = AgentSignalCoalescer()
            XCTAssertNotNil(coalescer.signal(at: 0))
            coalescer.reset()
            XCTAssertFalse(coalescer.fire())
            XCTAssertNotNil(coalescer.signal(at: 1), "A stop/start must not leave a dead armed window")
        }

        func testSignalWatcherGoesThroughTheCoalescer() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent(
                "Sources/LocalHistoryApp/AgentActivity/AgentActivityRuntime.swift"), encoding: .utf8)
            let watcher = try XCTUnwrap(source.components(separatedBy: "private func scheduleSignalWatcher()").last?
                .components(separatedBy: "static func effectivePollingInterval").first)
            XCTAssertTrue(watcher.contains("self?.noteSignalEvent()"))
            XCTAssertFalse(watcher.contains("watcher.setEventHandler { [weak self] in\n                self?.scanNow"))
        }

        // MARK: Blocking fallback poll

        private func blockingInterval(idle: TimeInterval, session: Bool = true) -> TimeInterval {
            ContextMonitor.blockingPollInterval(idleSeconds: idle, sessionAvailable: session)
        }

        func testBlockingPollNeverSlowsWhileTheUserActs() {
            for idle in stride(from: 0.0, to: 15, by: 0.5) {
                XCTAssertEqual(blockingInterval(idle: idle), 0.75, "idle \(idle) s")
            }
        }

        func testBlockingPollBacksOffWhenIdle() {
            XCTAssertEqual(blockingInterval(idle: 30), 2)
            XCTAssertGreaterThanOrEqual(blockingInterval(idle: 120), 5)
            XCTAssertGreaterThanOrEqual(blockingInterval(idle: 3_600), 5)
            // R49 (E1): the back-off no longer depends on AX coverage; app activation stays immediate.
        }

        func testBlockingPollNearlyStopsWhileLockedAndResumesAtOnce() {
            XCTAssertGreaterThanOrEqual(blockingInterval(idle: 0, session: false), 60)
            XCTAssertGreaterThanOrEqual(blockingInterval(idle: 600, session: false), 60)
            // Back from the lock with fresh input: fast again (unlock also calls resetAndSample()).
            XCTAssertEqual(blockingInterval(idle: 0, session: true), 0.75)
        }

        // MARK: Permission watchdog

        private let missing = PermissionStatus(
            accessibility: false, inputMonitoring: false, accessibilityPreflight: false,
            accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: false,
            inputMonitoringProvidedByAccessibility: false)

        func testPermissionWatchdogBacksOffFromThreeSecondsToOneMinute() {
            XCTAssertEqual(PermissionWatchdogPolicy.recoveryInterval(degradedFor: 0), 3)
            XCTAssertEqual(PermissionWatchdogPolicy.recoveryInterval(degradedFor: 119), 3)
            XCTAssertEqual(PermissionWatchdogPolicy.recoveryInterval(degradedFor: 3_600 * 24), 60)
            var previous: TimeInterval = 0
            for degraded in stride(from: 0.0, through: 900, by: 15) {
                let interval = PermissionWatchdogPolicy.recoveryInterval(degradedFor: degraded)
                XCTAssertGreaterThanOrEqual(interval, previous, "never faster as recovery lasts")
                XCTAssertTrue((3...60).contains(interval))
                previous = interval
            }
            XCTAssertEqual(PermissionWatchdogPolicy.interval(status: missing, eventTapRunning: false, degradedFor: 3_600), 60)
            // Back to Goalong or the guide restarts the clock: 3 s again.
            XCTAssertEqual(PermissionWatchdogPolicy.interval(status: missing, eventTapRunning: false, degradedFor: 0), 3)
        }

        func testPermissionAttentionResetsTheBackoff() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let app = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/AppDelegate.swift"), encoding: .utf8)
            let observers = try XCTUnwrap(app.components(separatedBy: "private func installPermissionAttentionObservers()").last?
                .components(separatedBy: "private func installCapabilityConsentObserver()").first)
            XCTAssertTrue(observers.contains("NSApplication.didBecomeActiveNotification"))
            XCTAssertTrue(observers.contains(".goalongPermissionGuideDidOpen"))
            XCTAssertTrue(observers.contains("self.permissionRecoverySince = Date()"))
            XCTAssertTrue(app.contains("installPermissionAttentionObservers()\n"))
        }
    }
#endif
