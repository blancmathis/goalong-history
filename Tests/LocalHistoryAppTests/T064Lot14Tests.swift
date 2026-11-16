#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

/// T-064 lot14 : engagements (suppression des données, règlement sans mesure, horloge reculée) et Jev (pause future,
/// marques de session protégées, budget, « Verrouillé » hors ligne).
final class T064Lot14Tests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; c.locale = Locale(identifier: "en_US"); c.firstWeekday = 1; return c
    }
    private func date(_ key: String, _ hour: Int = 8) -> Date { FocusCalendar.dayInterval(key, calendar: calendar)!.start.addingTimeInterval(Double(hour * 3600)) }
    private func store() throws -> FocusStore {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/t064-lot14-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings); return s
    }
    private func defaults() -> UserDefaults {
        let key = "t064-lot14-" + UUID().uuidString, d = UserDefaults(suiteName: key)!
        addTeardownBlock { d.removePersistentDomain(forName: key) }
        return d
    }

    // MARK: R P1 — deleting the data

    /// An unsettled commitment past its free window, then a missed result with its exit open: deleting is refused
    /// (static rule, controller, runtime with and without a controller). Once the exit closed, deleting goes ahead.
    @MainActor func testDeleteDataRefusedWhileCommitmentLocked() throws {
        let s = try store(); var now = date("2026-10-04")
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: day, kind: .sessions, target: 3)
        XCTAssertNil(c.dataDeleteRefusal, "inside the free window")

        now = date("2026-10-04", 12)
        XCTAssertEqual(c.dataDeleteRefusal, ConcentrationController.unsettledDeleteRefusal)
        XCTAssertEqual(ConcentrationController.dataDeleteRefusal(c.commitments, now: now, clock: nil, calendar: calendar),
                       ConcentrationController.unsettledDeleteRefusal)
        let withController = ConcentrationRuntime(storeFactory: { s }, factory: { _ in c }, blockingProvider: { nil },
                                                  presentsPanels: false, clock: { now }, calendar: calendar)
        let modules = GoalongModuleStore(defaults: defaults()); modules.setEnabled(.concentration, true)
        withController.start(modules: modules)
        XCTAssertThrowsError(try withController.deleteData()) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        XCTAssertEqual(withController.error, ConcentrationController.unsettledDeleteRefusal)
        XCTAssertEqual(withController.deleteRefusal, ConcentrationController.unsettledDeleteRefusal)
        let bare = ConcentrationRuntime(storeFactory: { s }, blockingProvider: { nil }, presentsPanels: false, clock: { now }, calendar: calendar)
        XCTAssertThrowsError(try bare.deleteData()) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        XCTAssertFalse(try s.commitments().isEmpty, "nothing deleted")

        now = date("2026-10-05", 9); c.applyMeasurements([], hasDefinition: true)
        XCTAssertEqual(c.commitments.first?.result?.outcome, .missed)
        XCTAssertEqual(c.dataDeleteRefusal, ConcentrationController.resultDeleteRefusal, "exit still open")
        XCTAssertThrowsError(try bare.deleteData())

        now = date("2026-10-08")
        XCTAssertNil(c.dataDeleteRefusal)
        XCTAssertNil(ConcentrationController.dataDeleteRefusal(c.commitments, now: now, clock: nil, calendar: calendar))
    }

    /// An unreadable commitments file refuses deleting (fail-closed): nothing proves no commitment is locked.
    @MainActor func testDeleteDataRefusedWhenCommitmentsUnreadable() throws {
        let s = try store()
        try Data("not json".utf8).write(to: s.directory.appendingPathComponent("commitments.json"))
        guard (try? s.commitments()) == nil else { throw XCTSkip("store tolerates this file") }
        let runtime = ConcentrationRuntime(storeFactory: { s }, blockingProvider: { nil }, presentsPanels: false, clock: { Date() }, calendar: calendar)
        XCTAssertNotNil(runtime.dataDeleteRefusal())
    }

    // MARK: R P2 — settling without measurement

    /// No reading (consent off or global pause): a work commitment is not settled at 0; a sessions one still settles.
    @MainActor func testNoSettlementAtZeroWithoutMeasurement() throws {
        let s = try store(); var now = date("2026-10-04")
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: day, kind: .work, target: 60)
        _ = try c.setCommitment(period: FocusCommitmentPeriod(kind: .week, key: "2026-W40"), kind: .plan, target: 1)
        now = date("2026-10-12")
        c.applyMeasurements([], hasDefinition: true, measurable: false)
        XCTAssertNil(c.commitments.first { $0.kind == .work }?.result, "work not settled without a measure")
        XCTAssertNotNil(c.commitments.first { $0.kind == .plan }?.result, "plan settles from Goalong's own files")
        c.applyMeasurements([], hasDefinition: true, measurable: true)
        XCTAssertNotNil(c.commitments.first { $0.kind == .work }?.result)
    }

    /// A clock set back during a session: stop and skip events never go before the last event.
    @MainActor func testStopAfterClockSetBackKeepsEventsOrdered() throws {
        let s = try store(); var now = date("2026-10-04", 10)
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        try c.startSession(intent: "Lire", mode: FocusMode(kind: .pomodoro))
        now = now.addingTimeInterval(300); try c.skipPhase()
        now = date("2026-10-04", 9)
        try c.skipPhase()
        try c.stopSession()
        let session = try XCTUnwrap(try s.sessions("2026-10-04").last)
        let times = session.events.map(\.at)
        XCTAssertEqual(times, times.sorted(), "events stay in order")
        XCTAssertGreaterThanOrEqual(times.first ?? .distantPast, session.startedAt)
    }

    // MARK: S P2 — Jev

    func testFutureBreakIsNotCurrent() throws {
        let now = Date()
        let future = try XCTUnwrap(JevTimedBreak(minutes: 30, now: now.addingTimeInterval(3600)))
        XCTAssertTrue(future.isValid); XCTAssertFalse(future.isCurrent(at: now))
        XCTAssertTrue(try XCTUnwrap(JevTimedBreak(minutes: 30, now: now)).isCurrent(at: now))
    }

    /// A break.json starting in the future does not suspend Jev: it is dropped and its file removed.
    @MainActor func testFutureBreakFileDoesNotSuspendJev() throws {
        let root = URL(fileURLWithPath: "/private/tmp/t064-jev-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let consents = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consents.json"))
        try JevLocalFiles.write(Data("valid-key-123".utf8), name: "api-key", root: root)
        let future = try XCTUnwrap(JevTimedBreak(minutes: 120, now: Date().addingTimeInterval(86_400)))
        try JevLocalFiles.write(try JSONEncoder().encode(future), name: "break.json", root: root)
        let monitor = JevMonitor(scopePreferences: JevMonitoringPreferences(defaults: defaults()), consents: consents,
                                 sessionProvider: { nil }, inbox: JevIngress(notificationCenter: NotificationCenter()),
                                 localRoot: root)
        XCTAssertNil(monitor.timedBreak); XCTAssertFalse(monitor.breakStorageInvalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("jev/break.json").path))
    }

    /// A protected session mark removed or weakened in the defaults comes back from the keychain copy at launch.
    @MainActor func testProtectedSessionMarkRestoredFromCopy() throws {
        let d = defaults(), floor = ProtectedFloor.memory(), now = Date()
        let store = JevSurveillanceStore(defaults: d, floor: floor)
        var settings = JevInterventionSettings(); settings.effectsEnabled = true
        let mark = JevSessionMark(id: UUID(), kind: .own, on: true, start: now, end: now.addingTimeInterval(3600), lock: .password, settings: settings)
        let free = JevSessionMark(id: UUID(), kind: .own, on: true, start: now, end: now.addingTimeInterval(3600), lock: .free, settings: settings)
        store.mark(mark, now: now, alive: JevRunningSessions()); store.mark(free, now: now, alive: JevRunningSessions())
        XCTAssertEqual(floor.load([JevSessionMark].self, key: ProtectedFloor.jevMarksKey), [mark], "only the protected mark is copied")
        XCTAssertNil(floor.load([JevSurveillanceRange].self, key: ProtectedFloor.jevKey), "the old key keeps its format")

        // Removed outside Goalong.
        d.set(try JSONEncoder().encode(JevSurveillanceDocument()), forKey: JevSurveillanceStore.storageKey)
        let removed = JevSurveillanceStore(defaults: d, floor: floor)
        XCTAssertEqual(removed.document.marks, [mark]); XCTAssertEqual(removed.restoredNotice, ProtectedFloor.restoredText)

        // Weakened outside Goalong: shorter, then off.
        var shorter = mark; shorter.end = now.addingTimeInterval(60)
        var off = mark; off.on = false
        var weaker = mark; weaker.lock = .typing
        for weak in [shorter, off, weaker] {
            var doc = JevSurveillanceDocument(); doc.marks = [weak]
            d.set(try JSONEncoder().encode(doc), forKey: JevSurveillanceStore.storageKey)
            XCTAssertEqual(JevSurveillanceStore(defaults: d, floor: floor).document.marks, [mark])
        }
        // Hardening is kept.
        var longer = mark; longer.end = now.addingTimeInterval(7200)
        var doc = JevSurveillanceDocument(); doc.marks = [longer]
        d.set(try JSONEncoder().encode(doc), forKey: JevSurveillanceStore.storageKey)
        let hardened = JevSurveillanceStore(defaults: d, floor: floor)
        XCTAssertEqual(hardened.document.marks, [longer]); XCTAssertNil(hardened.restoredNotice)

        // An own session already over is not put back.
        XCTAssertEqual(JevSurveillanceStore.restoreMarks(JevSurveillanceDocument(), floor: [mark], now: now.addingTimeInterval(7200)).count, 0)
    }

    @MainActor func testBudgetRetryIsBoundedAndProtectedSurveillanceKeepsReminder() {
        XCTAssertEqual(JevMonitor.budgetRetryDelay(0), 300)
        XCTAssertEqual(JevMonitor.budgetRetryDelay(900), 900)
        XCTAssertLessThan(JevMonitor.budgetRetryDelay(0), .infinity)
        XCTAssertFalse(JevMonitor.keepsInterventionsOnFailure([]))
        XCTAssertFalse(JevMonitor.keepsInterventionsOnFailure([.free]))
        XCTAssertTrue(JevMonitor.keepsInterventionsOnFailure([.free, .locked]))
        XCTAssertTrue(JevMonitor.keepsInterventionsOnFailure([.typing]))
    }
}
#endif
