#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class DiagnosticsLogTests: XCTestCase {
        func testRotationKeepsOneBoundedBackupAndPrivatePermissions() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let logger = BoundedDiagnosticsLog(
                directoryURL: fixture.logDirectory,
                maximumFileBytes: 256
            )

            for index in 0..<8 {
                try logger.append("entry-\(index)-\(String(repeating: "x", count: 80))\n")
            }

            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            let backup = fixture.logDirectory.appendingPathComponent("diagnostics.log.1")
            XCTAssertLessThanOrEqual(try fileSize(at: log), 256)
            XCTAssertLessThanOrEqual(try fileSize(at: backup), 256)
            XCTAssertEqual(try permissions(at: fixture.logDirectory), 0o700)
            XCTAssertEqual(try permissions(at: log), 0o600)
            XCTAssertEqual(try permissions(at: backup), 0o600)
            XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("entry-7-"))

            let names = try FileManager.default.contentsOfDirectory(
                atPath: fixture.logDirectory.path
            )
            XCTAssertEqual(
                Set(names),
                ["diagnostics.log", "diagnostics.log.1"]
            )
        }

        func testOversizedLegacyLogIsCompactedFromABoundedTail() throws {
            let fixture = try makeFixture(createLogDirectory: true)
            defer { fixture.remove() }
            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            let legacy = Data(
                (String(repeating: "old-diagnostic-line\n", count: 2_000) + "legacy-tail\n").utf8
            )
            try legacy.write(to: log)

            let logger = BoundedDiagnosticsLog(
                directoryURL: fixture.logDirectory,
                maximumFileBytes: 256
            )
            try logger.append("fresh-entry\n")

            let backup = fixture.logDirectory.appendingPathComponent("diagnostics.log.1")
            let backupData = try Data(contentsOf: backup)
            XCTAssertLessThanOrEqual(backupData.count, 256)
            let backupText = try XCTUnwrap(String(data: backupData, encoding: .utf8))
            XCTAssertTrue(backupText.hasPrefix("[older diagnostics omitted]\n"))
            XCTAssertTrue(backupText.hasSuffix("legacy-tail\n"))
            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "fresh-entry\n")
            XCTAssertEqual(try permissions(at: log), 0o600)
            XCTAssertEqual(try permissions(at: backup), 0o600)
        }

        func testOversizedExistingBackupIsCompactedEvenWhenActiveLogDoesNotRotate() throws {
            let fixture = try makeFixture(createLogDirectory: true)
            defer { fixture.remove() }
            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            let backup = fixture.logDirectory.appendingPathComponent("diagnostics.log.1")
            try Data("active-entry\n".utf8).write(to: log)
            try Data(
                (String(repeating: "old-backup-line\n", count: 2_000) + "backup-tail\n").utf8
            ).write(to: backup)
            let logger = BoundedDiagnosticsLog(
                directoryURL: fixture.logDirectory,
                maximumFileBytes: 256
            )

            try logger.append("fresh-entry\n")

            XCTAssertEqual(
                try String(contentsOf: log, encoding: .utf8),
                "active-entry\nfresh-entry\n"
            )
            let backupData = try Data(contentsOf: backup)
            XCTAssertLessThanOrEqual(backupData.count, 256)
            let backupText = try XCTUnwrap(String(data: backupData, encoding: .utf8))
            XCTAssertTrue(backupText.hasPrefix("[older diagnostics omitted]\n"))
            XCTAssertTrue(backupText.hasSuffix("backup-tail\n"))
            XCTAssertEqual(try permissions(at: backup), 0o600)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.logDirectory.appendingPathComponent(
                        ".diagnostics.log.rotation.tmp"
                    ).path
                )
            )
        }

        func testOversizedSingleEntryRemainsBoundedValidUTF8() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let logger = BoundedDiagnosticsLog(
                directoryURL: fixture.logDirectory,
                maximumFileBytes: 256
            )

            try logger.append(String(repeating: "é", count: 2_000) + "\n")

            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            let data = try Data(contentsOf: log)
            XCTAssertLessThanOrEqual(data.count, 256)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(text.hasSuffix("[diagnostic entry truncated]\n"))
        }

        func testConcurrentLoggerInstancesKeepCompleteRows() throws {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let loggers = [
                BoundedDiagnosticsLog(
                    directoryURL: fixture.logDirectory,
                    maximumFileBytes: 128 * 1_024
                ),
                BoundedDiagnosticsLog(
                    directoryURL: fixture.logDirectory,
                    maximumFileBytes: 128 * 1_024
                ),
            ]

            DispatchQueue.concurrentPerform(iterations: 500) { index in
                do {
                    try loggers[index % loggers.count].append("entry-\(index)\n")
                } catch {
                    XCTFail("Concurrent diagnostics append failed: \(error)")
                }
            }

            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            let rows = try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            XCTAssertEqual(rows.count, 500)
            XCTAssertEqual(Set(rows), Set((0..<500).map { "entry-\($0)" }))
            XCTAssertLessThanOrEqual(try fileSize(at: log), 128 * 1_024)
        }

        func testIngressKeepsOneDrainAndBoundedMemoryDuringTenThousandMessageBurst() throws {
            let scheduler = ManualDiagnosticsScheduler()
            let outputs = LockedDiagnosticOutputs()
            let sinkStarted = DispatchSemaphore(value: 0)
            let releaseSink = DispatchSemaphore(value: 0)
            let drainFinished = DispatchSemaphore(value: 0)
            let ingress = BoundedDiagnosticsIngress(
                capacity: 128,
                maximumPendingBytes: 128 * 1_024,
                maximumMessageBytes: 2 * 1_024,
                scheduler: scheduler.schedule,
                sink: { _, message in
                    if outputs.append(message) == 1 {
                        sinkStarted.signal()
                        _ = releaseSink.wait(timeout: .now() + 5)
                    }
                }
            )

            ingress.submit("first")
            let drain = try XCTUnwrap(scheduler.takeNext())
            DispatchQueue.global(qos: .utility).async {
                drain()
                drainFinished.signal()
            }
            XCTAssertEqual(sinkStarted.wait(timeout: .now() + 2), .success)

            for index in 0..<10_000 {
                ingress.submit("diagnostic-\(index)")
            }
            let saturated = ingress.snapshot
            XCTAssertEqual(scheduler.scheduledCount, 1)
            XCTAssertEqual(saturated.scheduledDrainCount, 1)
            XCTAssertTrue(saturated.drainScheduled)
            XCTAssertLessThanOrEqual(saturated.pendingCount, saturated.capacity)
            XCTAssertLessThanOrEqual(
                saturated.pendingBytes,
                saturated.maximumPendingBytes
            )
            XCTAssertLessThanOrEqual(
                saturated.maximumObservedCount,
                saturated.capacity
            )
            XCTAssertLessThanOrEqual(
                saturated.maximumObservedBytes,
                saturated.maximumPendingBytes
            )
            XCTAssertGreaterThan(saturated.totalDroppedCount, 0)

            releaseSink.signal()
            XCTAssertEqual(drainFinished.wait(timeout: .now() + 5), .success)
            let rendered = outputs.values
            let omissionMarkers = rendered.filter {
                $0.contains("diagnostics omitted during overload")
            }
            XCTAssertEqual(omissionMarkers.count, 1)
            XCTAssertTrue(
                omissionMarkers[0].contains(String(saturated.totalDroppedCount))
            )

            let idle = ingress.snapshot
            XCTAssertEqual(idle.pendingCount, 0)
            XCTAssertEqual(idle.pendingBytes, 0)
            XCTAssertFalse(idle.drainScheduled)
            XCTAssertEqual(idle.scheduledDrainCount, 1)
        }

        func testSymlinkedDirectoryIsRejectedWithoutTouchingTarget() throws {
            let fixture = try makeFixture(createLogDirectory: false)
            defer { fixture.remove() }
            let external = fixture.container.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let sentinel = external.appendingPathComponent("sentinel")
            let original = Data("must-remain-unchanged".utf8)
            try original.write(to: sentinel)
            try FileManager.default.createSymbolicLink(
                at: fixture.logDirectory,
                withDestinationURL: external
            )
            let logger = BoundedDiagnosticsLog(directoryURL: fixture.logDirectory)

            XCTAssertThrowsError(try logger.append("must-not-be-written\n"))
            XCTAssertEqual(try Data(contentsOf: sentinel), original)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: external.appendingPathComponent("diagnostics.log").path
                )
            )
        }

        func testSymlinkedLogOrBackupIsRejectedWithoutTouchingTarget() throws {
            let fixture = try makeFixture(createLogDirectory: true)
            defer { fixture.remove() }
            let external = fixture.container.appendingPathComponent("external.log")
            let original = Data("must-remain-unchanged".utf8)
            try original.write(to: external)
            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            try FileManager.default.createSymbolicLink(at: log, withDestinationURL: external)
            let logger = BoundedDiagnosticsLog(
                directoryURL: fixture.logDirectory,
                maximumFileBytes: 256
            )

            XCTAssertThrowsError(try logger.append("must-not-be-written\n"))
            XCTAssertEqual(try Data(contentsOf: external), original)

            try FileManager.default.removeItem(at: log)
            try Data(repeating: 0x78, count: 240).write(to: log)
            let backup = fixture.logDirectory.appendingPathComponent("diagnostics.log.1")
            try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: external)
            XCTAssertThrowsError(try logger.append(String(repeating: "y", count: 32)))
            XCTAssertEqual(try Data(contentsOf: external), original)
        }

        func testHardLinkedActiveLogIsRejectedWithoutTouchingTarget() throws {
            let fixture = try makeFixture(createLogDirectory: true)
            defer { fixture.remove() }
            let external = fixture.container.appendingPathComponent("external-active.log")
            let original = Data("active-target-must-remain-unchanged".utf8)
            try original.write(to: external)
            try setPermissions(0o640, at: external)
            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            try FileManager.default.linkItem(at: external, to: log)
            let logger = BoundedDiagnosticsLog(directoryURL: fixture.logDirectory)

            XCTAssertThrowsError(try logger.append("must-not-be-written\n"))
            XCTAssertEqual(try Data(contentsOf: external), original)
            XCTAssertEqual(try permissions(at: external), 0o640)
            XCTAssertEqual(try linkCount(at: external), 2)
        }

        func testHardLinkedBackupIsRejectedWithoutTouchingTarget() throws {
            let fixture = try makeFixture(createLogDirectory: true)
            defer { fixture.remove() }
            let external = fixture.container.appendingPathComponent("external-backup.log")
            let original = Data("backup-target-must-remain-unchanged".utf8)
            try original.write(to: external)
            try setPermissions(0o640, at: external)
            let backup = fixture.logDirectory.appendingPathComponent("diagnostics.log.1")
            try FileManager.default.linkItem(at: external, to: backup)
            let logger = BoundedDiagnosticsLog(directoryURL: fixture.logDirectory)

            XCTAssertThrowsError(try logger.append("must-not-be-written\n"))
            XCTAssertEqual(try Data(contentsOf: external), original)
            XCTAssertEqual(try permissions(at: external), 0o640)
            XCTAssertEqual(try linkCount(at: external), 2)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.logDirectory.appendingPathComponent("diagnostics.log").path
                )
            )
        }

        func testHardLinkedRotationTemporaryIsRejectedWithoutTouchingTarget() throws {
            let fixture = try makeFixture(createLogDirectory: true)
            defer { fixture.remove() }
            let external = fixture.container.appendingPathComponent("external-temporary.log")
            let original = Data("temporary-target-must-remain-unchanged".utf8)
            try original.write(to: external)
            try setPermissions(0o640, at: external)
            let temporary = fixture.logDirectory.appendingPathComponent(
                ".diagnostics.log.rotation.tmp"
            )
            try FileManager.default.linkItem(at: external, to: temporary)
            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            let active = Data(repeating: 0x61, count: 240)
            try active.write(to: log)
            let logger = BoundedDiagnosticsLog(
                directoryURL: fixture.logDirectory,
                maximumFileBytes: 256
            )

            XCTAssertThrowsError(try logger.append(String(repeating: "b", count: 32)))
            XCTAssertEqual(try Data(contentsOf: external), original)
            XCTAssertEqual(try permissions(at: external), 0o640)
            XCTAssertEqual(try linkCount(at: external), 2)
            XCTAssertEqual(try Data(contentsOf: log), active)
        }

        func testRotationReportsBackupRenameBeforeDirectorySyncAndActiveTruncate() throws {
            let fixture = try makeFixture(createLogDirectory: true)
            defer { fixture.remove() }
            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            try Data(repeating: 0x61, count: 240).write(to: log)
            var checkpoints: [BoundedDiagnosticsRotationCheckpoint] = []
            let logger = BoundedDiagnosticsLog(
                directoryURL: fixture.logDirectory,
                maximumFileBytes: 256,
                rotationObserver: { checkpoints.append($0) }
            )

            try logger.append(String(repeating: "b", count: 32))

            XCTAssertEqual(
                checkpoints,
                [.backupRenamed, .directorySynchronized, .activeLogTruncated]
            )
        }

        func testFailureAfterDirectorySyncLeavesActiveLogUntruncated() throws {
            let fixture = try makeFixture(createLogDirectory: true)
            defer { fixture.remove() }
            let log = fixture.logDirectory.appendingPathComponent("diagnostics.log")
            let original = Data(repeating: 0x61, count: 240)
            try original.write(to: log)
            var checkpoints: [BoundedDiagnosticsRotationCheckpoint] = []
            let logger = BoundedDiagnosticsLog(
                directoryURL: fixture.logDirectory,
                maximumFileBytes: 256,
                rotationObserver: { checkpoint in
                    checkpoints.append(checkpoint)
                    if checkpoint == .directorySynchronized {
                        throw DiagnosticsTestError.injectedAfterDirectorySync
                    }
                }
            )

            XCTAssertThrowsError(try logger.append(String(repeating: "b", count: 32)))
            XCTAssertEqual(
                checkpoints,
                [.backupRenamed, .directorySynchronized]
            )
            XCTAssertEqual(try Data(contentsOf: log), original)
            let backup = fixture.logDirectory.appendingPathComponent("diagnostics.log.1")
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(try permissions(at: backup), 0o600)
        }

        private func makeFixture(
            createLogDirectory: Bool = false
        ) throws -> DiagnosticsFixture {
            let container = FileManager.default.temporaryDirectory.appendingPathComponent(
                "DiagnosticsLogTests-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let logDirectory = container.appendingPathComponent("logs", isDirectory: true)
            if createLogDirectory {
                try FileManager.default.createDirectory(
                    at: logDirectory,
                    withIntermediateDirectories: true
                )
            }
            return DiagnosticsFixture(container: container, logDirectory: logDirectory)
        }

        private func fileSize(at url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)
        }

        private func permissions(at url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        }

        private func setPermissions(_ permissions: Int, at url: URL) throws {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        }

        private func linkCount(at url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try XCTUnwrap((attributes[.referenceCount] as? NSNumber)?.intValue)
        }
    }

    private enum DiagnosticsTestError: Error {
        case injectedAfterDirectorySync
    }

    private struct DiagnosticsFixture {
        var container: URL
        var logDirectory: URL

        func remove() {
            try? FileManager.default.removeItem(at: container)
        }
    }

    private final class ManualDiagnosticsScheduler {
        private let lock = NSLock()
        private var tasks: [() -> Void] = []
        private var scheduleCount = 0

        var scheduledCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return scheduleCount
        }

        func schedule(_ work: @escaping () -> Void) {
            lock.lock()
            scheduleCount += 1
            tasks.append(work)
            lock.unlock()
        }

        func takeNext() -> (() -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            guard !tasks.isEmpty else { return nil }
            return tasks.removeFirst()
        }
    }

    private final class LockedDiagnosticOutputs {
        private let lock = NSLock()
        private var storage: [String] = []

        @discardableResult
        func append(_ value: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            storage.append(value)
            return storage.count
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
#endif
