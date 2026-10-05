#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import LocalHistoryApp

/// The journal must explain real failures (type, case, errno) while staying free of
/// private content, and must stay readable when one error repeats thousands of times.
final class SupportDiagnosticsSignalTests: XCTestCase {
    private enum PlainFailure: Error { case writeOutcomeRequiresRecovery, http(Int), located(URL) }
    private enum CustomDescribed: Error, CustomStringConvertible {
        case leak
        var description: String { "PRIVATE_CANARY /Users/alice" }
    }

    private final class Clock { var now = Date(timeIntervalSince1970: 1_790_000_000) }

    private func journal(clock: Clock) throws -> (SupportDiagnostics, UserDefaults) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-signal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "goalong.signal.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let journal = SupportDiagnostics(root: parent.appendingPathComponent("SupportDiagnostics"), defaults: defaults, clock: { clock.now })
        addTeardownBlock { journal.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: parent) }
        return (journal, defaults)
    }

    func testSwiftErrorsExposeTypeCaseAndNumericPayloadOnly() {
        let plain = SupportDiagnostics.errorValues(PlainFailure.writeOutcomeRequiresRecovery)
        XCTAssertEqual(plain[.errorCase], .symbol("writeOutcomeRequiresRecovery"))
        XCTAssertEqual(plain[.errorType], .symbol("LocalHistoryAppTests.SupportDiagnosticsSignalTests.PlainFailure"))
        XCTAssertEqual(plain[.errorKind], .state(.swiftError))

        let http = SupportDiagnostics.errorValues(PlainFailure.http(402))
        XCTAssertEqual(http[.errorCase], .symbol("http"))
        XCTAssertEqual(http[.errorValue], .count(402))

        let located = SupportDiagnostics.errorValues(PlainFailure.located(URL(fileURLWithPath: "/Users/PRIVATE_CANARY")))
        XCTAssertEqual(located[.errorCase], .symbol("located"))
        XCTAssertNil(located[.errorValue])
        XCTAssertFalse(String(describing: located).contains("PRIVATE_CANARY"))

        let custom = SupportDiagnostics.errorValues(CustomDescribed.leak)
        XCTAssertNil(custom[.errorCase], "A custom description is never used as a case name")
        XCTAssertFalse(String(describing: custom).contains("PRIVATE_CANARY"))
    }

    func testUnderlyingPOSIXCodeIsKeptSoAFullDiskIsVisible() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [
            NSFilePathErrorKey: "/Users/PRIVATE_CANARY/file",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ])
        let values = SupportDiagnostics.errorValues(error)
        XCTAssertEqual(values[.errorType], .symbol("NSCocoaErrorDomain"))
        XCTAssertEqual(values[.errorCode], .count(NSFileWriteOutOfSpaceError))
        XCTAssertEqual(values[.underlyingErrorCode], .count(Int(ENOSPC)))
        XCTAssertEqual(values[.rootErrorKind], .state(.posixError))
        XCTAssertFalse(String(describing: values).contains("PRIVATE_CANARY"))
    }

    func testUnsafeSymbolsAreRejectedWhenReadBack() throws {
        let record = SupportRecord(schema: 1, revision: nil, timestamp: Date(), session: UUID(), sequence: 1,
                                   component: .app, event: .operationFailed, level: .error, source: nil, line: nil,
                                   values: ["errorType": .symbol("/Users/alice/secret")])
        XCTAssertFalse(record.isShareable)
        let version = SupportRecord(schema: 1, revision: nil, timestamp: Date(), session: UUID(), sequence: 1,
                                    component: .updates, event: .appUpdated, level: .info, source: nil, line: nil,
                                    values: ["version": .symbol("0.6.51"), "previousVersion": .symbol("alice")])
        XCTAssertFalse(version.isShareable)
        let symbolOnState = SupportRecord(schema: 1, revision: nil, timestamp: Date(), session: UUID(), sequence: 1,
                                          component: .app, event: .heartbeat, level: .info, source: nil, line: nil,
                                          values: ["state": .symbol("PRIVATE_CANARY")])
        XCTAssertFalse(symbolOnState.isShareable)
    }

    func testRepeatedErrorsAreCoalescedWithAnExactCount() throws {
        let clock = Clock()
        let (journal, _) = try journal(clock: clock)
        journal.start()
        for _ in 0..<500 { journal.failure(PlainFailure.writeOutcomeRequiresRecovery, component: .capture) }
        var records = journal.snapshot().records.filter { $0.component == .capture }
        XCTAssertEqual(records.filter { $0.event == .operationFailed }.count, SupportDiagnostics.repeatAllowance)

        clock.now += SupportDiagnostics.repeatWindow + 1
        journal.flushRepeatSummaries()
        records = journal.snapshot().records.filter { $0.component == .capture }
        let summary = try XCTUnwrap(records.first { $0.event == .repeatSummary })
        XCTAssertEqual(summary.values["suppressedCount"], .count(500 - SupportDiagnostics.repeatAllowance))
        XCTAssertEqual(summary.values["repeatedEvent"], .symbol("operationFailed"))
        XCTAssertEqual(summary.level, .error)
    }

    func testPeriodicRecordsAreWrittenOnlyWhenADiscreteValueChanges() throws {
        let clock = Clock()
        let (journal, _) = try journal(clock: clock)
        journal.start()
        func heartbeat(_ ready: Bool, delay: Double) {
            journal.recordIfChanged(.heartbeat, component: .app,
                                    values: [.tapRunning: .flag(ready), .elapsedMS: .number(delay), .inputCount: .count(Int(delay))])
        }
        for n in 0..<60 { heartbeat(true, delay: Double(n)); clock.now += 60 }
        XCTAssertEqual(journal.snapshot().records.filter { $0.event == .heartbeat }.count, 4, "Once, then every 15 minutes")
        heartbeat(false, delay: 1)
        heartbeat(false, delay: 2)
        XCTAssertEqual(journal.snapshot().records.filter { $0.event == .heartbeat }.count, 5)
    }

    func testErrorsSurviveABusyDayThatRotatesRoutineRecords() throws {
        let clock = Clock()
        let (journal, _) = try journal(clock: clock)
        journal.start()
        journal.record(.storageInterrupted, component: .capture, level: .error, values: [.state: .state(.diskFull)])
        for n in 0..<4_000 {
            journal.record(.sourceCheck, component: .permissions, values: [.itemCount: .count(n), .state: .state(.ready)])
            if n % 50 == 0 { journal.flush() }
        }
        journal.flush()
        let records = journal.snapshot().records
        XCTAssertFalse(records.contains { $0.event == .sourceCheck && $0.values["itemCount"] == .count(0) }, "Routine records rotated")
        XCTAssertTrue(records.contains { $0.event == .storageInterrupted }, "The root cause is kept")
    }

    func testFirstLaunchAfterAnUpdateRecordsTheVersionTransition() throws {
        let clock = Clock()
        let (journal, defaults) = try journal(clock: clock)
        defaults.set("0.6.49|30000000.1.1", forKey: SupportDiagnostics.lastLaunchKey)
        journal.start(version: "0.6.50", build: "30000000.2.1")
        let update = try XCTUnwrap(journal.snapshot().records.first { $0.event == .appUpdated })
        XCTAssertEqual(update.values["previousVersion"], .symbol("0.6.49"))
        XCTAssertEqual(update.values["version"], .symbol("0.6.50"))
        XCTAssertEqual(defaults.string(forKey: SupportDiagnostics.lastLaunchKey), "0.6.50|30000000.2.1")
    }

    func testFindingsExplainTheDiskFullIncidentInPlainFrench() throws {
        func record(_ event: SupportEvent, _ level: SupportLevel, _ values: [String: SupportValue], component: SupportComponent = .capture) -> SupportRecord {
            SupportRecord(schema: 1, revision: nil, timestamp: Date(), session: UUID(), sequence: 1, component: component,
                          event: event, level: level, source: nil, line: nil, values: values)
        }
        var timeline = [
            record(.appStarted, .info, ["previousExitUnclean": .flag(true)], component: .app),
            record(.storageInterrupted, .error, ["state": .state(.diskFull)]),
            record(.storageRecovered, .info, ["lostEvents": .count(12)]),
            record(.requestFinished, .warning, ["httpStatus": .count(402)], component: .monitoring),
        ]
        timeline += (0..<12).map { _ in record(.operationFailed, .error, ["errorType": .symbol("LocalHistoryApp.JSONLStore.JSONLStoreError"),
                                                                         "errorCase": .symbol("writeOutcomeRequiresRecovery")]) }
        let storage = SupportStorage(freeMB: 800, lowSpace: true, storesMB: [:], eventDayFiles: 1, enumerationTruncated: false)
        let findings = SupportFindings.detect(live: ["storageInterrupted": .flag(true), "storageFailure": .state(.diskFull)],
                                              timeline: timeline, storage: storage, crashes: [], diagnosticsEnabled: true)
        let codes = findings.map(\.code)
        XCTAssertEqual(codes.first, .recordingInterrupted)
        XCTAssertTrue(findings[0].detail.contains("disque est plein"))
        for expected: SupportFinding.Code in [.recordingWasInterrupted, .lowDiskSpace, .uncleanExit, .monitoringPaymentRequired, .repeatedError] {
            XCTAssertTrue(codes.contains(expected), "\(expected)")
        }
        XCTAssertTrue(findings.first { $0.code == .recordingWasInterrupted }!.detail.contains("12"))
        XCTAssertTrue(findings.first { $0.code == .repeatedError }!.detail.contains("JSONLStoreError.writeOutcomeRequiresRecovery"))

        let calm = SupportFindings.detect(live: [:], timeline: [], storage: nil, crashes: [], diagnosticsEnabled: true)
        XCTAssertEqual(calm.map(\.code), [.noProblemDetected])
    }

    func testReportStoreKeepsOnlyRecentPrivateCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-reports-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var last: URL?
        for n in 0..<8 {
            last = try SupportReportStore.save(Data("{}".utf8), createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)), in: directory)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, SupportReportStore.retainedReports)
        XCTAssertTrue(names.contains(try XCTUnwrap(last).lastPathComponent))
        var status = stat()
        XCTAssertEqual(lstat(directory.path, &status), 0); XCTAssertEqual(status.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(try XCTUnwrap(last).path, &status), 0); XCTAssertEqual(status.st_mode & 0o777, 0o600)
    }

    @MainActor func testEmailBodyInvitesADescriptionAndStatesWhatIsNotIncluded() {
        let body = SupportRequestController.messageBody(findings: [
            SupportFinding(severity: .error, code: .recordingInterrupted, title: "L’enregistrement est interrompu", detail: "Disque plein."),
        ], fileName: "Goalong-diagnostic-x.json")
        XCTAssertTrue(body.contains("Décrivez"))
        XCTAssertTrue(body.contains("L’enregistrement est interrompu"))
        XCTAssertTrue(body.contains("aucun contenu d’activité"))
    }

    @inline(never) static func stallTestBlockingWork() { usleep(300_000) }

    func testStallMonitorNamesTheAppFrameThatBlockedMain() throws {
        let monitor = SupportStallMonitor()
        monitor.start()
        defer { monitor.stop() }
        let done = expectation(description: "stall")
        DispatchQueue.main.async {
            Self.stallTestBlockingWork()
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let stall = try XCTUnwrap(monitor.lastStall)
        XCTAssertGreaterThanOrEqual(stall.durationMS, 250)
        XCTAssertFalse(stall.frames.isEmpty)
        XCTAssertTrue(stall.frames.allSatisfy { $0.range(of: "^off_[0-9a-f]+$", options: .regularExpression) != nil })
    }
}
#endif
