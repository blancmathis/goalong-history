#if os(macOS)
import Foundation
import Darwin
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class SupportDiagnosticsTests: XCTestCase {
    private func fixture(now: @escaping () -> Date = Date.init) throws -> (SupportDiagnostics, URL, UserDefaults) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-support-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "goalong.support.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = parent.appendingPathComponent("SupportDiagnostics")
        let journal = SupportDiagnostics(root: root, defaults: defaults, clock: now)
        journal.start()
        addTeardownBlock { journal.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: parent) }
        return (journal, root, defaults)
    }

    func testOnlyTypedTechnicalFieldsSurviveErrorWithPrivatePayload() throws {
        let (journal, _, _) = try fixture()
        let secret = "PRIVATE_CANARY_alice@example.invalid_very-secret-token"
        journal.failure(NSError(domain: "private-domain-" + secret, code: 73,
            userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: "/Users/" + secret,
                       NSUnderlyingErrorKey: NSError(domain: secret, code: 1)]), component: .storage)
        journal.record(.requestFinished, component: .monitoring, values: [.httpStatus: .count(429), .durationMS: .number(12.5)])
        let records = journal.snapshot().records
        let data = try SupportDiagnostics.encoder().encode(records)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains("/Users/"))
        XCTAssertTrue(text.contains("otherError")); XCTAssertTrue(text.contains("429"))
        XCTAssertEqual(records.filter { $0.event == .operationFailed }.count, 1)
    }

    func testLegacyBridgeDoesNotEvenEvaluatePotentiallyPrivateMessage() {
        var evaluated = false
        func privateValue() -> String { evaluated = true; return "private-content" }
        Diagnostics.write(privateValue())
        XCTAssertFalse(evaluated)
    }

    func testUnknownStatesFieldsAndSourceNamesAreNeverExported() throws {
        let (journal, root, _) = try fixture()
        let first = try XCTUnwrap(journal.snapshot().records.first)
        let encoded = try SupportDiagnostics.encoder().encode(first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let file = root.appendingPathComponent(SupportDiagnostics.day(Date())).appendingPathComponent("diagnostics.log")
        let h = try FileHandle(forWritingTo: file); defer { try? h.close() }; try h.seekToEnd()
        for mutation in 0..<3 {
            var record = object
            if mutation == 0 { record["values"] = ["windowTitle": "PRIVATE_CANARY"] }
            if mutation == 1 { record["source"] = "/Users/PRIVATE_CANARY/file.swift" }
            if mutation == 2 { record["values"] = ["state": "PRIVATE_CANARY"] }
            var bytes = try JSONSerialization.data(withJSONObject: record); bytes.append(10); try h.write(contentsOf: bytes)
        }
        // Even unknown top-level keys on an otherwise valid record are discarded by decoding/re-encoding.
        object["privateContent"] = "PRIVATE_CANARY"
        var bytes = try JSONSerialization.data(withJSONObject: object); bytes.append(10); try h.write(contentsOf: bytes)
        let snapshot = journal.snapshot()
        XCTAssertEqual(snapshot.rejected, 3)
        XCTAssertFalse(String(decoding: try SupportDiagnostics.encoder().encode(snapshot.records), as: UTF8.self).contains("PRIVATE_CANARY"))
    }

    func testJournalIsPrivateAndDisabledLoggingAddsNoRecords() throws {
        let (journal, root, _) = try fixture()
        let before = journal.snapshot().records.count
        journal.setEnabled(false)
        for _ in 0..<30 { journal.record(.userMarkedIssue, component: .support) }
        XCTAssertEqual(journal.snapshot().records.count, before)
        XCTAssertFalse(journal.snapshot().enabled)
        var s = stat(); XCTAssertEqual(lstat(root.path, &s), 0); XCTAssertEqual(s.st_mode & 0o777, 0o700)
        let file = root.appendingPathComponent(SupportDiagnostics.day(Date())).appendingPathComponent("diagnostics.log")
        XCTAssertEqual(lstat(file.path, &s), 0); XCTAssertEqual(s.st_mode & 0o777, 0o600)
        journal.setEnabled(true); journal.record(.userMarkedIssue, component: .support)
        XCTAssertEqual(journal.snapshot().records.count, before + 1)
    }

    func testRetentionKeepsOnlySevenDatesAndDoesNotTouchHistoryOrUnknownFiles() throws {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let (journal, root, _) = try fixture(now: { now })
        let unrelated = root.deletingLastPathComponent().appendingPathComponent("history.jsonl")
        try Data("PRIVATE_HISTORY".utf8).write(to: unrelated)
        for _ in 0..<10 { journal.record(.heartbeat, component: .app); journal.flush(); now += 86400 }
        journal.record(.heartbeat, component: .app); journal.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(Set(names), Set(SupportDiagnostics.days(ending: now)))
        try journal.clear()
        XCTAssertTrue(journal.snapshot().records.isEmpty)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "PRIVATE_HISTORY")
    }

    func testBurstAndRotationRemainBounded() throws {
        let (journal, root, _) = try fixture()
        DispatchQueue.concurrentPerform(iterations: 5_000) { n in
            journal.record(.heartbeat, component: .app, values: [.eventCount: .count(n)])
        }
        let snapshot = journal.snapshot()
        XCTAssertTrue(snapshot.records.allSatisfy(\.isShareable))
        XCTAssertGreaterThan(snapshot.records.count, 0)
        let bucket = root.appendingPathComponent(SupportDiagnostics.day(Date()))
        for name in ["diagnostics.log", "diagnostics.log.1"] {
            let url = bucket.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertLessThanOrEqual((attrs[.size] as! NSNumber).intValue, SupportDiagnostics.segmentBytes)
            }
        }
    }

    func testSymlinkAndHardlinkInputsAreRejected() throws {
        let (journal, root, _) = try fixture(); journal.flush()
        let parent = root.deletingLastPathComponent()
        let original = parent.appendingPathComponent("original")
        try Data("PRIVATE_CANARY".utf8).write(to: original)
        let symlink = parent.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        XCTAssertThrowsError(try SupportDiagnostics.readPrivateFile(symlink, maximum: 1_024))
        let hardlink = parent.appendingPathComponent("hardlink")
        XCTAssertEqual(link(original.path, hardlink.path), 0)
        XCTAssertThrowsError(try SupportDiagnostics.readPrivateFile(hardlink, maximum: 1_024))
    }

    func testCrashSummaryIncludesOnlyOwnOffsetsAndNotRawCrashPayload() throws {
        let id = UUID()
        let object: [String: Any] = [
            "procName": "Goalong History", "procPath": "/Users/PRIVATE_CANARY/Goalong History.app",
            "bundleInfo": ["CFBundleIdentifier": "ai.goalong.localhistory"],
            "exception": ["type": "EXC_BAD_ACCESS", "codes": "PRIVATE_CANARY"],
            "faultingThread": 0,
            "usedImages": [["name": "Goalong History", "uuid": id.uuidString, "path": "PRIVATE_CANARY"], ["name": "PRIVATE_CANARY"]],
            "threads": [["frames": [["imageIndex": 0, "imageOffset": 12345, "symbol": "PRIVATE_CANARY"],
                                    ["imageIndex": 1, "imageOffset": 999, "symbol": "PRIVATE_CANARY"]],
                          "threadState": ["register": "PRIVATE_CANARY"]]]
        ]
        let body = try JSONSerialization.data(withJSONObject: object)
        let ips = Data("{\"headerPrivate\":\"PRIVATE_CANARY\"}\n".utf8) + body
        let crash = try XCTUnwrap(SupportCrash.parse(ips))
        XCTAssertEqual(crash.type, .EXC_BAD_ACCESS); XCTAssertEqual(crash.binaryUUID, id)
        XCTAssertEqual(crash.ownBinaryOffsets, [12345])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(crash), as: UTF8.self).contains("PRIVATE_CANARY"))
        var other = object; other["bundleInfo"] = ["CFBundleIdentifier": "com.some.other.app"]
        XCTAssertNil(SupportCrash.parse(try JSONSerialization.data(withJSONObject: other)))
        XCTAssertNil(SupportCrash.parse(Data(repeating: 65, count: 2 * 1_024 * 1_024 + 1)))
    }

    func testBuildFieldsAreCategoricalAndValidateVersion() {
        XCTAssertEqual(SupportBuild.installation(path: "/Applications/Goalong History.app"), .applications)
        XCTAssertEqual(SupportBuild.installation(path: "/private/var/folders/private/AppTranslocation/secret/d/Goalong History.app"), .translocated)
        XCTAssertEqual(SupportBuild.installation(path: "/Volumes/private/Goalong History.app"), .diskImage)
        XCTAssertNil(SupportBuild.validated("PRIVATE_CANARY", pattern: "^[0-9]+$"))
    }
}

final class PermissionReconciliationTests: XCTestCase {
    func testGenericFunctionalReadCannotGrantPermission() {
        let status = PermissionStatus.resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: true, inputMonitoringDirectlyGranted: false)
        XCTAssertFalse(status.accessibility); XCTAssertFalse(status.canAttemptInputTap)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(status), .accessibility)
    }
    func testProtectedExternalEvidenceCanReconcileStaleNegativePreflight() {
        let status = PermissionStatus.resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: true,
            inputMonitoringDirectlyGranted: false, accessibilityCrossProcessProbe: true)
        XCTAssertTrue(status.accessibility); XCTAssertTrue(status.accessibilityUsable)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(status), .ready)
        let observation = CapturePermissionObservation(accessibilityPreflight: false, accessibilityFunctionalProbe: true,
            inputMonitoringPreflight: false, observedAt: Date(), accessibilityCrossProcessProbe: true)
        XCTAssertTrue(observation.accessibilityUsable)
    }
    func testGrantedButTemporaryAXFailureDoesNotRevokePermission() {
        let status = PermissionStatus.resolved(accessibilityPreflight: true, accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: false)
        XCTAssertTrue(status.accessibility); XCTAssertFalse(status.accessibilityUsable)
        XCTAssertEqual(SourceAccessService.computerHistoryAccess(status), .ready)
    }
    func testSelfPIDAndInvalidPIDCannotProveExternalAuthorization() {
        XCTAssertFalse(PermissionManager.isExternalProbeTarget(pid: 40, ownPID: 40))
        XCTAssertFalse(PermissionManager.isExternalProbeTarget(pid: 0, ownPID: 40))
        XCTAssertFalse(PermissionManager.isExternalProbeTarget(pid: -1, ownPID: 40))
        XCTAssertTrue(PermissionManager.isExternalProbeTarget(pid: 41, ownPID: 40))
    }
    func testRevocationNeverRetainsOldFunctionalEvidence() {
        var live = PermissionStatus.resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: true,
            inputMonitoringDirectlyGranted: false, accessibilityCrossProcessProbe: true)
        let manager = PermissionManager(statusProbe: { live })
        XCTAssertTrue(manager.snapshot.accessibility)
        live = .resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: false, inputMonitoringDirectlyGranted: false)
        XCTAssertFalse(manager.refresh(force: true).accessibility)
    }
    func testOldPersistedHealthSnapshotRemainsDecodable() throws {
        let json = Data("{\"accessibilityPreflight\":true,\"accessibilityFunctionalProbe\":true,\"inputMonitoringPreflight\":false,\"observedAt\":0}".utf8)
        let observation = try JSONDecoder().decode(CapturePermissionObservation.self, from: json)
        XCTAssertNil(observation.accessibilityCrossProcessProbe); XCTAssertTrue(observation.accessibilityUsable)
    }
    func testRepairScopeNeverTargetsAllOrAnotherApplication() {
        for (status, service) in [(SourceAccessStatus.accessibility, "Accessibility"), (.inputMonitoring, "ListenEvent"), (.fullDiskAccess, "SystemPolicyAllFiles")] {
            XCTAssertEqual(PermissionRepair.arguments(for: status, bundleID: "ai.goalong.localhistory"), ["reset", service, "ai.goalong.localhistory"])
            XCTAssertNil(PermissionRepair.arguments(for: status, bundleID: "com.other.app"))
            XCTAssertNil(PermissionRepair.arguments(for: status, bundleID: nil))
        }
        for status in [SourceAccessStatus.ready, .screenTimeSetup, .unavailable("PRIVATE_CANARY")] {
            XCTAssertNil(PermissionRepair.arguments(for: status, bundleID: "ai.goalong.localhistory"))
        }
    }
}
#endif
