#if os(macOS)
import AppleScreenTime
import AppleSystemScreenTime
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongSiteExportTests: XCTestCase {
    func testStructuredReportUsesSelectedBudgetsWithoutInventingProductivityOrHours() throws {
        let payload = try GoalongSiteExport.payload(record: fixture(), options: .init(deviceIDs: ["mac"], includeApplications: true, structuredReport: true))
        let json = try object(payload), day = try firstDay(json)
        XCTAssertEqual(json["version"] as? Int, 3)
        let budgets = try XCTUnwrap(day["duration_budgets"] as? [[String: Any]])
        let activities = try XCTUnwrap(day["activities"] as? [[String: Any]])
        XCTAssertEqual(budgets.count, 1)
        XCTAssertEqual(budgets[0]["seconds"] as? Int, 800)
        XCTAssertEqual(budgets[0]["basis"] as? String, "application_usage")
        XCTAssertEqual(budgets[0]["device_ref"] as? String, "apple-screen-time:mac")
        XCTAssertNil(budgets[0]["start"])
        XCTAssertTrue(activities[0]["category"] is NSNull)
        XCTAssertEqual(activities[0]["productive_proposal"] as? String, "unknown")
        XCTAssertNil(activities[0]["start"])
        XCTAssertNotNil(day["telemetry"])
    }

    func testStructuredTotalsOnlyDoesNotLeakAppNamesOrStoredSummary() throws {
        let payload = try GoalongSiteExport.payload(record: fixture(), options: .init(structuredReport: true), recap: "private-title")
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("secret.app"))
        XCTAssertFalse(text.contains("private-title"))
        let day = try firstDay(object(payload))
        XCTAssertEqual((day["duration_budgets"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((day["coverage"] as? [String: String])?["day_accounting"], "complete")
    }
    func testTotalsOnlyDefaultsOmitAllSensitiveDetailsAndKeepSourceTotal() throws {
        let record = try fixture()
        let payload = try GoalongSiteExport.payload(record: record)
        let json = try object(payload)
        let day = try firstDay(json)
        let telemetry = try XCTUnwrap(day["telemetry"] as? [String: Any])
        let devices = try XCTUnwrap(telemetry["devices"] as? [[String: Any]])
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertEqual(json["source"] as? String, "goalong-history")
        XCTAssertEqual(day["date"] as? String, "2026-09-02")
        XCTAssertEqual(telemetry["timezone"] as? String, "Europe/Paris")
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0]["screenSeconds"] as? Int, 600)
        XCTAssertEqual(devices[0]["appsCoverage"] as? String, "unknown")
        XCTAssertTrue((devices[0]["apps"] as? [Any])?.isEmpty == true)
        XCTAssertTrue(devices[0]["hourly"] is NSNull)
        XCTAssertTrue(telemetry["websites"] is NSNull)
        XCTAssertTrue(telemetry["agent"] is NSNull)
        XCTAssertEqual(day["summary"] as? String, "")
        XCTAssertTrue((day["activities"] as? [Any])?.isEmpty == true)
        for forbidden in ["secret.app", "private-title", "fingerprint", "transcript", "verified", "rootDirectory"] {
            XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(forbidden))
        }
    }

    func testSelectedAppsPreserveIndependentTotalsAndDailyAggregateHasNoInventedHours() throws {
        let payload = try GoalongSiteExport.payload(record: fixture(), options: .init(
            deviceIDs: ["mac"], includeApplications: true, includeHourly: true))
        let devices = try deviceRows(payload)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0]["screenSeconds"] as? Int, 600)
        let apps = try XCTUnwrap(devices[0]["apps"] as? [[String: Any]])
        XCTAssertEqual(apps[0]["seconds"] as? Int, 800)
        XCTAssertEqual(apps[0]["category"] as? String, "other")
        XCTAssertEqual(devices[0]["appsCoverage"] as? String, "partial")
        XCTAssertTrue(devices[0]["hourly"] is NSNull)
        XCTAssertEqual(devices[0]["provenance"] as? String, "apple-private-aggregate")
        XCTAssertThrowsError(try GoalongSiteExport.payload(record: fixture(), options: .init(deviceIDs: ["missing"])))
        XCTAssertThrowsError(try GoalongSiteExport.payload(record: fixture(), options: .init(deviceIDs: ["mac", "mac"])))
    }

    func testCoverageDistinguishesReconstructionAndCurrentDay() throws {
        let record = try fixture(reconstructed: true)
        let devices = try deviceRows(GoalongSiteExport.payload(record: record, options: .init(includeApplications: true)))
        XCTAssertEqual(devices[0]["provenance"] as? String, "apple-reconstructed")
        XCTAssertEqual(devices[0]["coverage"] as? String, "partial")
        XCTAssertEqual(devices[0]["appsCoverage"] as? String, "partial")
        let current = try firstDay(object(GoalongSiteExport.payload(record: fixture(), now: record.dayStart.addingTimeInterval(3600))))
        let telemetry = try XCTUnwrap(current["telemetry"] as? [String: Any])
        XCTAssertEqual(telemetry["state"] as? String, "in-progress")
    }

    func testHourlyBinsHandleTwentyFiveHourDSTDayWithoutLosingRepeatedHour() throws {
        let record = try fixture(date: "2026-10-25", hourly: true)
        let rows = try deviceRows(GoalongSiteExport.payload(record: record, options: .init(includeHourly: true),
                                                         now: record.dayEnd.addingTimeInterval(3600)))
        XCTAssertEqual(rows[0]["screenSeconds"] as? Int, 90_000)
        let hours = try XCTUnwrap(rows[0]["hourly"] as? [Int])
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[2], 7200)
        XCTAssertEqual(hours.reduce(0, +), 90_000)
    }

    func testRecapIsOptInAndBounded() throws {
        let record = try fixture()
        let ignored = try firstDay(object(GoalongSiteExport.payload(record: record, recap: "private-title")))
        XCTAssertEqual(ignored["summary"] as? String, "")
        let selected = try firstDay(object(GoalongSiteExport.payload(record: record, options: .init(includeRecap: true), recap: "My chosen summary")))
        XCTAssertEqual(selected["summary"] as? String, "My chosen summary")
        XCTAssertThrowsError(try GoalongSiteExport.payload(record: record, options: .init(includeRecap: true), recap: String(repeating: "a", count: 3001)))
    }

    func testWebsiteDetailsAreExplicitPartialAndNeverIncreaseScreenTime() throws {
        let site = DailyWebsiteUsage(host: "example.org", foregroundSeconds: 900, activeMinuteCount: 15,
            eventCount: 2, sourceApplications: ["Safari"], primaryBundleIdentifier: "com.apple.Safari",
            category: nil, identityProofAvailable: false)
        let hidden = try firstDay(object(GoalongSiteExport.payload(record: fixture(), websites: [site])))
        XCTAssertTrue((hidden["telemetry"] as? [String: Any])?["websites"] is NSNull)
        let payload = try GoalongSiteExport.payload(record: fixture(), options: .init(includeWebsites: true), websites: [site])
        let day = try firstDay(object(payload))
        let telemetry = try XCTUnwrap(day["telemetry"] as? [String: Any])
        let website = try XCTUnwrap(telemetry["websites"] as? [String: Any])
        XCTAssertEqual(website["includedInApplicationTotals"] as? Bool, true)
        XCTAssertEqual(website["coverage"] as? String, "partial")
        XCTAssertEqual(try deviceRows(payload)[0]["screenSeconds"] as? Int, 600)
        let rows = try XCTUnwrap(website["rows"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["domain"] as? String, "example.org")
        XCTAssertEqual(rows[0]["seconds"] as? Int, 900)
        let unsafe = DailyWebsiteUsage(host: "https://example.org/private?q=secret", foregroundSeconds: 10,
            activeMinuteCount: 1, eventCount: 1, sourceApplications: ["Safari"],
            primaryBundleIdentifier: nil, category: nil, identityProofAvailable: false)
        XCTAssertThrowsError(try GoalongSiteExport.payload(record: fixture(), options: .init(includeWebsites: true), websites: [unsafe]))
    }

    func testMeasuredZeroRemainsDistinctFromEmptyDeviceReport() throws {
        let base = try fixture()
        let source = try XCTUnwrap(base.collection.storedExport)
        let devices = base.collection.availableDevices
        let reports = [
            AppleScreenTimeDeviceReport(device: devices[0], lastUpdatedAt: base.dayEnd, segments: []),
            AppleScreenTimeDeviceReport(device: devices[1], lastUpdatedAt: base.dayEnd, segments: [
                .init(start: base.dayStart, end: base.dayEnd, totalScreenOnDuration: 0)
            ])
        ]
        let stored = AppleScreenTimeStoredExport(verification: .unsigned, envelope: .init(
            requestedStart: base.dayStart, requestedEnd: base.dayEnd, requestedScope: .allDevices,
            provenance: source.envelope.provenance, reports: reports))
        let collection = AppleSystemScreenTimeCollection(storedExport: stored, availableDevices: devices,
            status: base.collection.status, deviceSourceLabels: [:], latestAppleUpdate: base.dayEnd,
            knowledgeIntervalCount: 0, biomeIntervalCount: 0)
        let record = AppleSystemScreenTimeDailyArchiveRecord(dayStart: base.dayStart, dayEnd: base.dayEnd,
            timeZoneIdentifier: base.timeZoneIdentifier, state: .completed, storedAt: base.dayEnd, collection: collection)
        let rows = try deviceRows(GoalongSiteExport.payload(record: record))
        let missing = try XCTUnwrap(rows.first { $0["id"] as? String == "mac" })
        let measured = try XCTUnwrap(rows.first { $0["id"] as? String == "phone" })
        XCTAssertTrue(missing["screenSeconds"] is NSNull)
        XCTAssertEqual(missing["coverage"] as? String, "unknown")
        XCTAssertEqual(measured["screenSeconds"] as? Int, 0)
    }

    func testArchiveExportRespectsConsentAndLeavesFilesByteIdentical() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try fixture()
        let archiveRoot = root.appendingPathComponent("apple-screen-time/days")
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let file = archiveRoot.appendingPathComponent("2026-09-02.json")
        let original = try AppleScreenTimeJSON.encode(record)
        try original.write(to: file)
        XCTAssertThrowsError(try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: "2026-09-02"))
        let consent = Data(#"{"schemaVersion":1,"policyVersion":1,"capabilities":{"appleScreenTime":{"enabled":true}}}"#.utf8)
        try consent.write(to: root.appendingPathComponent("capability-consent.json"))
        _ = try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: "2026-09-02")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["apple-screen-time", "capability-consent.json"])
        XCTAssertThrowsError(try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: "2026-09-01"))
        XCTAssertThrowsError(try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: "2026-09-02", options: .init(includeWebsites: true)))
        XCTAssertThrowsError(try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: "2026-09-02", options: .init(includeRecap: true)))
        try original.write(to: archiveRoot.appendingPathComponent("2026-09-03.json"))
        XCTAssertThrowsError(try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: "2026-09-03"))
    }

    func testUploadOriginRefusesCredentialsInsecureRemoteAndAmbiguousPaths() throws {
        XCTAssertEqual(try GoalongSiteSubmission.endpoint(origin: "https://goalong.example").absoluteString,
                       "https://goalong.example/api/goalong/v1/import")
        XCTAssertNoThrow(try GoalongSiteSubmission.endpoint(origin: "http://127.0.0.1:4173/"))
        for origin in ["http://goalong.example", "https://token@goalong.example", "https://goalong.example?q=token", "https://goalong.example/path", "file:///tmp/test", "http://localhost.evil.example", "https://goalong.example/#token"] {
            XCTAssertThrowsError(try GoalongSiteSubmission.endpoint(origin: origin))
        }
    }

    func testExplicitTokenPathAcceptsLocalFilesWithoutDiscoveryOrRemoteURLs() throws {
        XCTAssertEqual(try GoalongSiteSubmission.tokenFileURL(path: " /tmp/Token File.txt ").path, "/tmp/Token File.txt")
        XCTAssertEqual(try GoalongSiteSubmission.tokenFileURL(path: "file:///tmp/Token%20File.txt").path, "/tmp/Token File.txt")
        XCTAssertEqual(try GoalongSiteSubmission.tokenFileURL(path: "~/Downloads/token.txt").path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/token.txt").path)
        for invalid in ["token.txt", "https://example.org/token.txt", "file://example.org/token.txt",
                        "file:///tmp/token.txt?secret=value", "file:///tmp/token.txt#fragment",
                        "~someone/token.txt", "synthetic-token-value", ""] {
            XCTAssertThrowsError(try GoalongSiteSubmission.tokenFileURL(path: invalid))
        }
    }

    func testUploadTokenFileRequiresOwnerOnlyPermissionsAndRefusesSymlink() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("upload-token")
        try Data("synthetic-token-for-tests\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try GoalongSiteSubmission.readToken(file: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try GoalongSiteSubmission.readToken(file: file), "synthetic-token-for-tests")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try GoalongSiteSubmission.readToken(file: link))
        try Data("synthetic token with spaces".utf8).write(to: file)
        XCTAssertThrowsError(try GoalongSiteSubmission.readToken(file: file))
    }

    func testExplicitTokenProtectionRestrictsOnlyTheReviewedRegularFile() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("downloaded-token")
        let unrelated = root.appendingPathComponent("unrelated")
        let original = Data("synthetic-upload-only-token".utf8)
        try original.write(to: file)
        try original.write(to: unrelated)
        for item in [file, unrelated] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: item.path)
        }
        let reviewed = try GoalongSiteSubmission.reviewTokenFile(file: file)
        XCTAssertTrue(reviewed.requiresProtection)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o644,
                       "Review must not modify permissions before the user confirms")
        try GoalongSiteSubmission.protectTokenFile(file: file, reviewed: reviewed)
        XCTAssertFalse(try GoalongSiteSubmission.reviewTokenFile(file: file).requiresProtection)
        XCTAssertEqual(try GoalongSiteSubmission.readToken(file: file), "synthetic-upload-only-token")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: unrelated.path)[.posixPermissions] as? Int, 0o644)
    }

    func testTokenProtectionRefusesChangedTargetSymlinkAndDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("downloaded-token")
        try Data("synthetic-upload-only-token".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let reviewed = try GoalongSiteSubmission.reviewTokenFile(file: file)
        let moved = root.appendingPathComponent("original-moved")
        try FileManager.default.moveItem(at: file, to: moved)
        try Data("synthetic-replacement-token".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try GoalongSiteSubmission.protectTokenFile(file: file, reviewed: reviewed))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o644)
        let link = root.appendingPathComponent("token-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
        XCTAssertThrowsError(try GoalongSiteSubmission.reviewTokenFile(file: link))
        XCTAssertThrowsError(try GoalongSiteSubmission.protectTokenFile(file: link, reviewed: reviewed))
        XCTAssertThrowsError(try GoalongSiteSubmission.reviewTokenFile(file: root))
        XCTAssertThrowsError(try GoalongSiteSubmission.protectTokenFile(file: root, reviewed: reviewed))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: moved.path)[.posixPermissions] as? Int, 0o644)
    }

    func testReceiptRequiresUnverifiedAndNeverReflectsServerFieldsOrCredentials() throws {
        let response = Data(#"{"imported":1,"updated":0,"skipped":0,"verification":"unverified","token":"secret"}"#.utf8)
        let result = try GoalongSiteSubmission.validatedResponse(response, status: 200)
        XCTAssertFalse(String(decoding: result, as: UTF8.self).contains("secret"))
        XCTAssertEqual(try object(result)["sharing"] as? String, "managed-on-site")
        for status in [302, 401, 403, 409, 413, 429, 500] {
            XCTAssertThrowsError(try GoalongSiteSubmission.validatedResponse(response, status: status))
        }
        XCTAssertThrowsError(try GoalongSiteSubmission.validatedResponse(Data(#"{"imported":true,"updated":0,"skipped":0,"verification":"unverified"}"#.utf8), status: 200))
        XCTAssertThrowsError(try GoalongSiteSubmission.validatedResponse(Data(#"{"imported":1,"updated":0,"skipped":0,"verification":"verified"}"#.utf8), status: 200))
        let request = GoalongSiteSubmission.request(payload: Data("{}".utf8), endpoint: try GoalongSiteSubmission.endpoint(origin: "https://goalong.example"), token: "test-token", idempotencyKey: "operation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "operation")
        XCTAssertFalse(request.url!.absoluteString.contains("test-token"))
    }

    private func object(_ payload: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }

    private func firstDay(_ json: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((json["days"] as? [[String: Any]])?.first)
    }

    private func deviceRows(_ payload: Data) throws -> [[String: Any]] {
        let day = try firstDay(object(payload))
        let telemetry = try XCTUnwrap(day["telemetry"] as? [String: Any])
        return try XCTUnwrap(telemetry["devices"] as? [[String: Any]])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("goalong-site-tests-\(UUID().uuidString)")
    }

    private func fixture(date: String = "2026-09-02", reconstructed: Bool = false,
                         hourly: Bool = false) throws -> AppleSystemScreenTimeDailyArchiveRecord {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = try XCTUnwrap(formatter.date(from: date))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let devices = [AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac),
                       AppleScreenTimeDevice(id: "phone", name: "iPhone", kind: .iPhone)]
        let app = AppleScreenTimeApplicationUsage(bundleIdentifier: "secret.app", displayName: "Private application", duration: 800)
        let segments: [AppleScreenTimeSegment]
        if hourly {
            segments = stride(from: 0.0, to: end.timeIntervalSince(start), by: 3600).map {
                AppleScreenTimeSegment(start: start.addingTimeInterval($0), end: start.addingTimeInterval($0 + 3600), totalScreenOnDuration: 3600)
            }
        } else {
            segments = [AppleScreenTimeSegment(start: start, end: end, totalScreenOnDuration: 600, applications: [app])]
        }
        let stored = AppleScreenTimeStoredExport(verification: .unsigned, envelope: .init(
            requestedStart: start, requestedEnd: end, requestedScope: .allDevices,
            provenance: .init(api: reconstructed ? "Apple usage streams" : AppleScreenTimeProvenance.screenTimeAgentAggregateAPI,
                              collectorBundleIdentifier: "test", collectorVersion: "test", collectorPlatform: "macOS",
                              authorization: .unknown, fetchPolicy: .cached, euCustomerRequirementAcknowledged: false),
            reports: devices.map { AppleScreenTimeDeviceReport(device: $0, lastUpdatedAt: end, segments: segments) }))
        let collection = AppleSystemScreenTimeCollection(storedExport: stored, availableDevices: devices,
            status: .init(kind: reconstructed ? .partial : .ready, title: "Fixture", message: "Synthetic"),
            deviceSourceLabels: [:], latestAppleUpdate: end, knowledgeIntervalCount: 0, biomeIntervalCount: 0)
        return .init(dayStart: start, dayEnd: end, timeZoneIdentifier: calendar.timeZone.identifier,
                     state: .completed, storedAt: end, collection: collection)
    }
}
#endif
