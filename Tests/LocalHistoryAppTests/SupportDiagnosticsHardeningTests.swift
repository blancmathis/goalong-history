#if os(macOS)
import Foundation
import Darwin
import XCTest
@testable import LocalHistoryApp

final class SupportDiagnosticsHardeningTests: XCTestCase {
    private func isolated() throws -> (URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-support-hardening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "goalong.support.hardening." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        return (root, defaults)
    }
    func testDiskFailureStillProvidesMemoryEventsAndHonestIncompleteFlag() throws {
        let (root, defaults) = try isolated()
        let journal = SupportDiagnostics(root: root.appendingPathComponent("missing-parent/journal"), defaults: defaults)
        journal.start(); defer { journal.stop() }
        journal.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), component: .storage)
        let snapshot = journal.snapshot()
        XCTAssertTrue(snapshot.diskSnapshotIncomplete)
        XCTAssertGreaterThan(snapshot.writeFailures, 0)
        XCTAssertTrue(snapshot.records.contains { $0.values["errorCode"] == .count(Int(ENOSPC)) })
    }
    func testLockedJournalCannotBlockExportOrQuitIndefinitely() throws {
        let (root, defaults) = try isolated()
        let directory = root.appendingPathComponent("journal")
        let journal = SupportDiagnostics(root: directory, defaults: defaults)
        journal.start(); XCTAssertTrue(journal.flush())
        let bucket = directory.appendingPathComponent(SupportDiagnostics.day(Date()))
        let fd = open(bucket.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { journal.stop(); return }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(fd, LOCK_UN); _ = close(fd); journal.stop() }
        journal.record(.userMarkedIssue, component: .support)
        let before = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(journal.flush(timeout: 0.05))
        let result = journal.snapshot(timeout: 0.05)
        XCTAssertTrue(result.diskSnapshotIncomplete)
        XCTAssertTrue(result.records.contains { $0.event == .userMarkedIssue })
        for _ in 0..<10 { XCTAssertTrue(journal.snapshot(timeout: 0.01).diskSnapshotIncomplete) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 1)
    }
    func testSafeReportWriterReplacesSymlinkWithoutTouchingTarget() throws {
        let (root, _) = try isolated()
        let privateFile = root.appendingPathComponent("private-file")
        let destination = root.appendingPathComponent("support.json")
        try Data("PRIVATE_CANARY".utf8).write(to: privateFile)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: privateFile)
        try SupportReportWriter.write(Data("{\"safe\":true}".utf8), to: destination)
        XCTAssertEqual(try String(contentsOf: privateFile), "PRIVATE_CANARY")
        XCTAssertEqual(try String(contentsOf: destination), "{\"safe\":true}")
        var status = stat(); XCTAssertEqual(lstat(destination.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG); XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".goalong-report-") })
    }
    func testFullExportNeverReadsOrIncludesLegacyRawLogs() throws {
        let (root, defaults) = try isolated()
        try Data("PRIVATE_CANARY_secret-token_https://private.invalid".utf8).write(to: root.appendingPathComponent("diagnostics.log"))
        let journal = SupportDiagnostics(root: root.appendingPathComponent("journal"), defaults: defaults)
        journal.start(); defer { journal.stop() }
        journal.record(.userMarkedIssue, component: .support)
        let report = SupportReport.build(journal: journal, live: [.tapRunning: .flag(false)], crashLoader: { [] })
        let text = String(decoding: try report.data(), as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_CANARY")); XCTAssertFalse(text.contains(NSHomeDirectory()))
        XCTAssertTrue(text.contains("userMarkedIssue")); XCTAssertFalse(report.diskSnapshotIncomplete)
        XCTAssertTrue(report.crashSummaries.isEmpty)
    }
    func testRepairRequiresAnInstalledNonTranslocatedCopy() {
        XCTAssertFalse(PermissionRepair.canResetInstallation(path: "/Volumes/Goalong/Goalong History.app"))
        XCTAssertFalse(PermissionRepair.canResetInstallation(path: "/private/var/folders/AppTranslocation/a/d/Goalong History.app"))
        XCTAssertFalse(PermissionRepair.canResetInstallation(path: "/tmp/debug/LocalHistory"))
        XCTAssertTrue(PermissionRepair.canResetInstallation(path: "/Applications/Goalong History.app"))
    }
    func testRevisionCannotContainPrivateOrArbitraryData() {
        XCTAssertTrue(SupportRecord.revisionIsSafe(nil)); XCTAssertTrue(SupportRecord.revisionIsSafe("0afaca3"))
        for value in ["a@example.com", "/Users/private", "PRIVATE_CANARY", "123", String(repeating: "a", count: 65)] {
            XCTAssertFalse(SupportRecord.revisionIsSafe(value))
        }
    }
    func testResponsivenessAllowsOnlyOnePingAndOneWarningUntilRecovery() {
        var state = SupportResponsivenessState()
        guard case .ping(let token) = state.tick(at: 0) else { return XCTFail("Missing ping") }
        XCTAssertEqual(state.tick(at: 10), .none)
        XCTAssertEqual(state.tick(at: 30), .warning(30))
        XCTAssertEqual(state.tick(at: 40), .none)
        XCTAssertEqual(state.acknowledge(token, at: 45), 45)
        guard case .ping(let next) = state.tick(at: 50) else { return XCTFail("Missing recovery ping") }
        XCTAssertNotEqual(next, token); XCTAssertNil(state.acknowledge(token, at: 51))
        XCTAssertNil(state.acknowledge(next, at: 52))
    }
    func testSleepAndClockRollbackInvalidatePendingPingWithoutWarning() {
        var state = SupportResponsivenessState()
        guard case .ping(let old) = state.tick(at: 0), case .ping = state.tick(at: 90) else { return XCTFail("Sleep must reset") }
        XCTAssertNil(state.acknowledge(old, at: 91))
        guard case .ping = state.tick(at: 5) else { return XCTFail("Clock rollback must reset") }
        XCTAssertEqual(state.tick(at: 10), .none)
    }
}
#endif
