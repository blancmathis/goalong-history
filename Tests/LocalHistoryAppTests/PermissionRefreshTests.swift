#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class PermissionRefreshTests: XCTestCase {
        func testSharedSnapshotReadsNeverProbeTCCOrAX() {
            var probeCalls = 0
            let manager = PermissionManager(statusProbe: {
                probeCalls += 1
                return self.missingStatus
            })

            for _ in 0..<20_000 {
                _ = manager.snapshot
                _ = manager.currentStatus
            }

            XCTAssertEqual(probeCalls, 1)
            XCTAssertEqual(manager.probeCount, 1)
        }

        func testRefreshIsAgeGatedButForceBypassesWatchdogCache() {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            var live = missingStatus
            var probeCalls = 0
            let manager = PermissionManager(
                statusProbe: {
                    probeCalls += 1
                    return live
                },
                clock: { now }
            )

            live = healthyStatus
            XCTAssertEqual(manager.refresh(minimumInterval: 60), missingStatus)
            XCTAssertEqual(probeCalls, 1)

            now = now.addingTimeInterval(60)
            XCTAssertEqual(manager.refresh(minimumInterval: 60), healthyStatus)
            XCTAssertEqual(probeCalls, 2)

            live = missingStatus
            XCTAssertEqual(manager.refresh(force: true), missingStatus)
            XCTAssertEqual(probeCalls, 3)
        }

        func testWatchdogUsesOneMinuteWhenHealthyAndThreeSecondsForRecovery() {
            XCTAssertEqual(
                PermissionWatchdogPolicy.interval(status: healthyStatus, eventTapRunning: true),
                60
            )
            XCTAssertEqual(
                PermissionWatchdogPolicy.interval(status: healthyStatus, eventTapRunning: false),
                3
            )
            XCTAssertEqual(
                PermissionWatchdogPolicy.interval(status: missingStatus, eventTapRunning: true),
                3
            )
        }

        func testFunctionalProbeAcceptsBoundedFrontmostAppFallback() {
            XCTAssertTrue(
                PermissionManager.functionalProbeIsUsable(
                    systemWideReadable: true,
                    frontmostApplicationReadable: false
                )
            )
            XCTAssertTrue(
                PermissionManager.functionalProbeIsUsable(
                    systemWideReadable: false,
                    frontmostApplicationReadable: true
                )
            )
            XCTAssertFalse(
                PermissionManager.functionalProbeIsUsable(
                    systemWideReadable: false,
                    frontmostApplicationReadable: false
                )
            )
        }

        func testCaptureHealthSkipsUnchangedPermissionBooleans() throws {
            let manager = PermissionManager(statusProbe: { self.healthyStatus })
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CaptureHealthStore(
                permissions: manager,
                fileURL: directory.appendingPathComponent("capture-health.json")
            )

            XCTAssertFalse(store.updatePermissions(healthyStatus))
            XCTAssertTrue(store.updatePermissions(missingStatus))
            XCTAssertFalse(store.updatePermissions(missingStatus))
            store.flush()
        }

        func testCaptureHealthUsesOnePendingPersistenceWakeup() throws {
            let manager = PermissionManager(statusProbe: { self.healthyStatus })
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let virtual = VirtualCaptureHealthPersistenceScheduler()
            let writeLock = NSLock()
            var writes = 0
            let store = CaptureHealthStore(
                permissions: manager,
                fileURL: directory.appendingPathComponent("capture-health.json"),
                persistenceWriter: { _, _ in
                    writeLock.lock()
                    writes += 1
                    writeLock.unlock()
                },
                persistenceSchedule: virtual.schedule
            )
            store.flush()
            writeLock.lock()
            let baseline = writes
            writeLock.unlock()

            for index in 0..<200 {
                _ = store.updatePermissions(index.isMultiple(of: 2) ? missingStatus : healthyStatus)
            }
            XCTAssertEqual(virtual.scheduledTaskCount, 1)
            XCTAssertEqual(virtual.activeTaskCount, 1)

            store.flush()
            XCTAssertEqual(virtual.activeTaskCount, 0)
            virtual.fireAllEvenIfCancelled()

            writeLock.lock()
            let finalWrites = writes
            writeLock.unlock()
            XCTAssertEqual(finalWrites, baseline + 1)
        }

        func testCaptureHealthFlushIncludesMutationArrivingDuringWrite() throws {
            let manager = PermissionManager(statusProbe: { self.healthyStatus })
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let virtual = VirtualCaptureHealthPersistenceScheduler()
            let writer = BlockingCaptureHealthWriter()
            let store = CaptureHealthStore(
                permissions: manager,
                fileURL: directory.appendingPathComponent("capture-health.json"),
                persistenceWriter: writer.write,
                persistenceSchedule: virtual.schedule
            )
            store.flush()
            let baseline = writer.writeCount

            writer.blockNextWrite()
            let flushFinished = expectation(description: "flush caught up")
            DispatchQueue.global(qos: .userInitiated).async {
                store.flush()
                flushFinished.fulfill()
            }
            XCTAssertEqual(writer.waitUntilBlocked(), .success)

            store.setPaused(true)
            writer.releaseBlockedWrite()
            wait(for: [flushFinished], timeout: 2)

            XCTAssertEqual(writer.writeCount, baseline + 2)
            XCTAssertTrue(try XCTUnwrap(writer.lastSnapshot).isManuallyPaused)
            XCTAssertEqual(virtual.activeTaskCount, 0)
        }

        func testCaptureHealthFlushIsReentrantOnPersistenceQueue() throws {
            let manager = PermissionManager(statusProbe: { self.healthyStatus })
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let writer = ReentrantCaptureHealthWriter()
            let store = CaptureHealthStore(
                permissions: manager,
                fileURL: directory.appendingPathComponent("capture-health.json"),
                persistenceWriter: writer.write
            )
            store.flush()
            writer.arm(store: store)

            store.beginControlledInputValidation()
            let drained = expectation(description: "reentrant flush did not deadlock")
            DispatchQueue.global(qos: .userInitiated).async {
                store.flush()
                drained.fulfill()
            }
            wait(for: [drained], timeout: 2)

            XCTAssertTrue(writer.didReenter)
            XCTAssertNotNil(writer.lastSnapshot?.expectedInputAfter)
        }

        func testDashboardMenuAndAgentActivityUseCachedSingleOwnerState() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appDelegate = try source("AppDelegate.swift", root: repositoryRoot)
            let dashboard = try source("DashboardViewModel.swift", root: repositoryRoot)
            let menu = try source("MenuBarController.swift", root: repositoryRoot)

            XCTAssertTrue(appDelegate.contains("onCaptured: { _ in }"))
            XCTAssertFalse(appDelegate.contains("recordAgentCaptures"))
            XCTAssertFalse(appDelegate.contains("kind: .agentArtifactCaptured"))
            XCTAssertTrue(dashboard.contains("permissions.snapshot"))
            XCTAssertFalse(dashboard.contains("permissions.currentStatus"))
            XCTAssertTrue(menu.contains("permissions.snapshot"))
            XCTAssertFalse(menu.contains("permissions.currentStatus"))
        }

        private var healthyStatus: PermissionStatus {
            PermissionStatus(
                accessibility: true,
                inputMonitoring: true,
                accessibilityPreflight: true,
                accessibilityFunctionalProbe: true,
                inputMonitoringDirectlyGranted: true,
                inputMonitoringProvidedByAccessibility: false
            )
        }

        private var missingStatus: PermissionStatus {
            PermissionStatus(
                accessibility: false,
                inputMonitoring: false,
                accessibilityPreflight: false,
                accessibilityFunctionalProbe: false,
                inputMonitoringDirectlyGranted: false,
                inputMonitoringProvidedByAccessibility: false
            )
        }

        private func source(_ name: String, root: URL) throws -> String {
            try String(
                contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/\(name)"),
                encoding: .utf8
            )
        }
    }

    private final class VirtualCaptureHealthPersistenceScheduler {
        private final class Task: CaptureHealthScheduledTask {
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

        lazy var schedule: CaptureHealthStore.PersistenceSchedule = { [weak self] _, action in
            let task = Task(action: action)
            self?.tasks.append(task)
            return task
        }

        var scheduledTaskCount: Int {
            tasks.count
        }

        var activeTaskCount: Int {
            tasks.filter { !$0.isCancelled }.count
        }

        func fireAllEvenIfCancelled() {
            let pending = tasks
            tasks.removeAll()
            for task in pending {
                task.action()
            }
        }
    }

    private final class BlockingCaptureHealthWriter {
        private let lock = NSLock()
        private let blocked = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var shouldBlockNextWrite = false
        private var snapshots: [CaptureHealthSnapshot] = []

        var writeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return snapshots.count
        }

        var lastSnapshot: CaptureHealthSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return snapshots.last
        }

        func blockNextWrite() {
            lock.lock()
            shouldBlockNextWrite = true
            lock.unlock()
        }

        func waitUntilBlocked() -> DispatchTimeoutResult {
            blocked.wait(timeout: .now() + 2)
        }

        func releaseBlockedWrite() {
            release.signal()
        }

        func write(_ snapshot: CaptureHealthSnapshot, _: URL) {
            lock.lock()
            let shouldBlock = shouldBlockNextWrite
            shouldBlockNextWrite = false
            lock.unlock()

            if shouldBlock {
                blocked.signal()
                _ = release.wait(timeout: .now() + 2)
            }

            lock.lock()
            snapshots.append(snapshot)
            lock.unlock()
        }
    }

    private final class ReentrantCaptureHealthWriter {
        private let lock = NSLock()
        private weak var store: CaptureHealthStore?
        private var shouldReenter = false
        private var snapshots: [CaptureHealthSnapshot] = []
        private var reentered = false

        var didReenter: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reentered
        }

        var lastSnapshot: CaptureHealthSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return snapshots.last
        }

        func arm(store: CaptureHealthStore) {
            lock.lock()
            self.store = store
            shouldReenter = true
            lock.unlock()
        }

        func write(_ snapshot: CaptureHealthSnapshot, _: URL) {
            lock.lock()
            snapshots.append(snapshot)
            let reenter = shouldReenter
            shouldReenter = false
            let store = self.store
            lock.unlock()

            if reenter {
                store?.flush()
                lock.lock()
                reentered = true
                lock.unlock()
            }
        }
    }
#endif
