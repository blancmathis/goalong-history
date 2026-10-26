#if os(macOS)
import XCTest
@testable import LocalHistoryCore
@testable import LocalHistoryApp

/// T-044 tour 2, volet B : B2-01 (joker sans enjeu) et B2-02 (règlement sans observation).
final class C044R2CommitmentSettleTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; c.locale = Locale(identifier: "en_US"); c.firstWeekday = 1; return c
    }
    private func date(_ key: String, _ hour: Int = 8) -> Date { FocusCalendar.dayInterval(key, calendar: calendar)!.start.addingTimeInterval(Double(hour * 3600)) }
    private func store() throws -> FocusStore {
        let s = FocusStore(directory: URL(fileURLWithPath: "/private/tmp/c044r2-settle-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: s.directory) }
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings); return s
    }

    /// B2-01: without a stake, a joker or a declaration has no block to lift; the card must not say « Blocage levé ».
    @MainActor func testJokerAndDeclarationWithoutStakeDoNotLiftABlock() throws {
        let s = try store(); var now = date("2026-10-04")
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-04"), week = FocusCommitmentPeriod(kind: .week, key: "2026-W40")
        _ = try c.setCommitment(period: day, kind: .work, target: 120)
        _ = try c.setCommitment(period: week, kind: .plan, target: 1)
        now = date("2026-10-11"); c.applyMeasurements([], hasDefinition: true)
        XCTAssertEqual(c.commitments.map { $0.result?.outcome }, [.missed, .missed])
        try c.useCommitmentJoker(period: day); try c.declareCommitmentHeld(period: week)
        for period in [day, week] {
            let card = try XCTUnwrap(c.commitmentCards.first { $0.commitment.period == period })
            XCTAssertEqual(card.commitment.result?.stake.state, FocusCommitmentResult.Stake.State.none, "\(period)")
            XCTAssertFalse(FocusCommitmentFormat.outcome(card, lists: [], now: now).contains("Blocage levé"), "\(period)")
        }
        let card = try XCTUnwrap(c.commitmentCards.first { $0.commitment.period == day })
        XCTAssertEqual(FocusCommitmentFormat.outcome(card, lists: [], now: now), "Joker utilisé : la série continue.")
    }

    /// B2-02: a Mac that never observes (recording off, no Accessibility) still settles a past commitment while the app runs.
    @MainActor func testPastCommitmentSettlesWithoutObservation() async throws {
        let s = try store(); var now = date("2026-10-04", 23)
        let c = try ConcentrationController(store: s, clock: { now }, calendar: calendar)
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-04")
        _ = try c.setCommitment(period: day, kind: .sessions, target: 2)
        let key = UUID().uuidString, defaults = UserDefaults(suiteName: key)!
        addTeardownBlock { defaults.removePersistentDomain(forName: key) }
        let modules = GoalongModuleStore(defaults: defaults); modules.setEnabled(.concentration, true)
        let runtime = ConcentrationRuntime(storeFactory: { s }, factory: { _ in c }, blockingProvider: { nil }, presentsPanels: false, clock: { now }, calendar: calendar)
        runtime.start(modules: modules)
        // Launch after the period ended: the first sample without observation must not cancel the start measurement.
        now = date("2026-10-05", 0).addingTimeInterval(60)
        runtime.receive(FocusObservation(at: now, observing: false))
        for _ in 0..<200 where c.commitments[0].result == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            now = now.addingTimeInterval(61); runtime.receive(FocusObservation(at: now, observing: false))
        }
        XCTAssertEqual(c.commitments[0].result?.outcome, .missed)
    }
}
#endif
