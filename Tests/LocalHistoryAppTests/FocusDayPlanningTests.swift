#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class FocusDayPlanningTests: XCTestCase {
    private let day = "2026-11-25"
    private let zone = "Europe/Paris"
    private func date(_ minute: Int, day: String = "2026-11-25", zone: String = "Europe/Paris") -> Date {
        FocusDayPlanner.date(day: day, minute: minute, timeZoneID: zone)!
    }
    private func plan() -> FocusPlan {
        let work = FocusPlanItem(title: "Écrire la documentation", nextAction: "Ouvrir la décision à préciser", actionKind: .work)
        let review = FocusPlanItem(title: "Relire la démo", actionKind: .review)
        return FocusPlan(day: day, items: [work, review], agenda: FocusAgenda(timeZoneID: zone,
            slots: [
                .init(itemID: work.id, title: work.title, startMinute: 600, endMinute: 660),
                .init(itemID: review.id, title: review.title, startMinute: 675, endMinute: 705),
                .init(title: "Déjeuner", startMinute: 720, endMinute: 780, fixed: true),
                .init(title: "Dîner", startMinute: 1080, endMinute: 1140, fixed: true),
                .init(title: "Routine du soir", startMinute: 1380, endMinute: 1410, fixed: true)
            ]))
    }

    func testOldPlanAndSettingsDecodeWithoutNewFields() throws {
        let legacy = """
        {"schema":1,"day":"2026-11-25","items":[{"id":"00000000-0000-0000-0000-000000000001","title":"Lire","status":"open"}]}
        """
        let p = try FocusJSON.decode(FocusPlan.self, from: Data(legacy.utf8))
        XCTAssertTrue(p.valid)
        XCTAssertEqual(p.effectiveRevision, 0)
        XCTAssertNil(p.agenda); XCTAssertNil(p.processes); XCTAssertNil(p.items[0].nextAction)
        var settings = try XCTUnwrap(JSONSerialization.jsonObject(with: FocusJSON.encode(FocusSettings())) as? [String: Any])
        settings.removeValue(forKey: "agendaTemplate")
        let decoded = try FocusJSON.decode(FocusSettings.self, from: JSONSerialization.data(withJSONObject: settings))
        XCTAssertTrue(decoded.valid); XCTAssertNil(decoded.agendaTemplate)
    }

    func testPartialNewPayloadUsesDefaultsAndRoundTrips() throws {
        let a = try FocusJSON.decode(FocusAgenda.self, from: Data("{\"timeZoneID\":\"Europe/Paris\"}".utf8))
        XCTAssertTrue(a.valid); XCTAssertFalse(a.guided); XCTAssertEqual(a.bufferMinutes, 10)
        let process = try FocusJSON.decode(FocusAgentProcess.self, from: Data("{\"title\":\"Préparer les tests\"}".utf8))
        XCTAssertTrue(process.valid); XCTAssertEqual(process.status, .queued)
        var p = plan(); p.processes = [process]
        let stored = try FocusJSON.decode(FocusPlan.self, from: FocusJSON.encode(p))
        XCTAssertEqual(stored, p)
    }

    func testParallelProcessesDoNotConsumeHumanTime() throws {
        let baseline = plan()
        var parallel = baseline
        parallel.processes = (1...32).map { FocusAgentProcess(title: "Agent \($0)", status: .running) }
        XCTAssertTrue(parallel.valid)
        XCTAssertEqual(FocusDayPlanner.reflow(plan: baseline, now: date(590)),
                       FocusDayPlanner.reflow(plan: parallel, now: date(590)))
        XCTAssertEqual(parallel.items.count, 2)
    }

    func testDelayPreservesMealsAndMovesWholeTaskAfterLunch() throws {
        let p = plan()
        let result = FocusDayPlanner.reflow(plan: p, now: date(620))
        let a = try XCTUnwrap(result.agenda)
        XCTAssertEqual(a.slots[0].startMinute, 620)
        XCTAssertEqual(a.slots[0].endMinute, 680)
        XCTAssertEqual(a.slots[1].startMinute, 790)
        XCTAssertEqual(a.slots[1].durationMinutes, 30)
        XCTAssertEqual(a.slots.filter(\.fixed), p.agenda!.slots.filter(\.fixed))
        XCTAssertTrue(result.unplaced.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        var adjusted = p; adjusted.agenda = a
        XCTAssertTrue(FocusDayPlanner.reflow(plan: adjusted, now: date(620)).changes.isEmpty)
    }

    func testNoImplicitCompressionOrExtensionPastDayEnd() throws {
        var p = plan(); p.agenda!.endMinute = 690
        let result = FocusDayPlanner.reflow(plan: p, now: date(620))
        let a = try XCTUnwrap(result.agenda)
        XCTAssertEqual(a.slots[0].durationMinutes, 60)
        XCTAssertEqual(a.slots[1].state, .unscheduled)
        XCTAssertEqual(a.slots[1].durationMinutes, 30)
        XCTAssertEqual(result.unplaced, [p.agenda!.slots[1].id])
        XCTAssertEqual(a.endMinute, 690)
        XCTAssertEqual(a.slots.last?.startMinute, 1380, "Fixed evening routine remains after the work cutoff.")
    }

    func testFixedAndActiveOverlapsAreExplicitConflicts() throws {
        var p = plan()
        p.agenda!.slots[0].state = .active
        p.agenda!.slots[0].endMinute = 740
        let result = FocusDayPlanner.reflow(plan: p, now: date(690))
        XCTAssertFalse(result.conflicts.isEmpty)
        XCTAssertEqual(result.agenda!.slots[0], p.agenda!.slots[0])
        XCTAssertEqual(result.agenda!.slots[2], p.agenda!.slots[2])
        XCTAssertEqual(FocusDayPlanner.currentSlot(plan: p, at: date(750))?.id, p.agenda!.slots[0].id)
        let overrun = FocusDayPlanner.reflow(plan: p, now: date(750))
        XCTAssertTrue(overrun.conflicts.contains { $0.contains("prolongation") })
    }

    func testFinishedTaskDoesNotStayTheCurrentAction() throws {
        var p = plan(); p.items[0].status = .done
        XCTAssertNil(FocusDayPlanner.currentSlot(plan: p, at: date(620)))
        XCTAssertEqual(FocusDayPlanner.nextSlot(plan: p, at: date(620))?.itemID, p.items[1].id)
        let result = FocusDayPlanner.reflow(plan: p, now: date(620))
        XCTAssertEqual(result.agenda?.slots[0].state, .done)
        XCTAssertEqual(result.agenda?.slots[1].durationMinutes, 30)
    }

    func testAnswerDoesNotPretendAnAgentHasResumed() {
        var waiting = FocusAgentProcess(title: "Démo", status: .waitingForYou, question: "Quel format ?")
        var p = FocusPlan(day: day, items: [], processes: [waiting])
        XCTAssertEqual(FocusDayPlanner.waitingProcesses(plan: p).count, 1)
        waiting.answer = "Un format court."
        p.processes = [waiting]
        XCTAssertTrue(FocusDayPlanner.waitingProcesses(plan: p).isEmpty)
        XCTAssertEqual(p.processes?.first?.status, .waitingForYou)
        XCTAssertFalse(waiting.status.isFinished)
    }

    func testTemplateContainsNoTasksOrCompletedInstances() {
        var a = FocusAgenda(timeZoneID: zone, guided: true,
            slots: [.init(title: "Sport", startMinute: 500, endMinute: 560, fixed: true)])
        XCTAssertTrue(a.validTemplate)
        a.slots[0].itemID = UUID(); XCTAssertFalse(a.validTemplate)
        a.slots[0].itemID = nil; a.slots[0].state = .done; XCTAssertFalse(a.validTemplate)
        var settings = FocusSettings(); settings.agendaTemplate = a; XCTAssertFalse(settings.valid)
    }

    func testTimezoneAndDSTUseThePlanCivilDay() throws {
        let midnightParis = date(30)
        XCTAssertEqual(FocusDayPlanner.dayKey(at: midnightParis, timeZoneID: "UTC"), "2026-11-24")
        XCTAssertEqual(FocusDayPlanner.localMinute(at: midnightParis, timeZoneID: zone), 30)
        XCTAssertNil(FocusDayPlanner.date(day: "2026-03-29", minute: 150, timeZoneID: zone))
        XCTAssertNotNil(FocusDayPlanner.date(day: "2026-10-25", minute: 150, timeZoneID: zone))
        XCTAssertEqual(FocusDayPlanner.dayKey(at: date(1440), timeZoneID: zone), "2026-11-26")
        let p = plan()
        XCTAssertNil(FocusDayPlanner.currentSlot(plan: p, at: date(620, day: "2026-11-26")))
        let past = FocusDayPlanner.reflow(plan: p, now: date(620, day: "2026-11-26"))
        XCTAssertEqual(past.unplaced.count, 2)
        XCTAssertEqual(past.agenda?.slots.filter(\.fixed), p.agenda?.slots.filter(\.fixed))
    }

    func testMalformedReferencesBoundsAndURLsAreRejected() {
        var p = plan(); p.agenda!.slots[0].itemID = UUID(); XCTAssertFalse(p.valid)
        p = plan(); p.agenda!.timeZoneID = "Invented/Zone"; XCTAssertFalse(p.valid)
        p = plan(); p.agenda!.slots[0].endMinute = 599; XCTAssertFalse(p.valid)
        p = plan(); p.agenda!.slots.append(p.agenda!.slots[0]); XCTAssertFalse(p.valid)
        p = plan(); p.processes = Array(repeating: FocusAgentProcess(title: "A"), count: 65); XCTAssertFalse(p.valid)
        p = plan(); p.revision = -1; XCTAssertFalse(p.valid)
        XCTAssertFalse(FocusDayValidation.contextURL("javascript:alert(1)"))
        XCTAssertFalse(FocusDayValidation.contextURL("file:///private/tmp/file"))
        XCTAssertFalse(FocusDayValidation.contextURL("https://user:secret@example.org"))
        XCTAssertTrue(FocusDayValidation.contextURL("http://127.0.0.1:4319/?view=review"))
        XCTAssertTrue(FocusDayValidation.contextURL("https://example.org/project"))
    }

    func testExplicitEarliestAndLatestConstraintsAreRespected() throws {
        var p = plan()
        p.agenda!.slots[0].earliestMinute = 600
        p.agenda!.slots[0].latestEndMinute = 700
        let result = FocusDayPlanner.reflow(plan: p, now: date(650))
        XCTAssertEqual(result.agenda?.slots[0].state, .unscheduled)
        XCTAssertEqual(result.agenda?.slots[0].durationMinutes, 60)
        XCTAssertTrue(result.unplaced.contains(p.agenda!.slots[0].id))
    }

    func testReflowNeverPlacesBeforeAnAbsoluteNowOrReplaysTheRepeatedHour() throws {
        let day = "2026-11-25", zone = "Europe/Paris"
        let preciseNow = try XCTUnwrap(FocusDayPlanner.date(day: day, minute: 600, timeZoneID: zone)).addingTimeInterval(30)
        var plan = FocusPlan(day: day, agenda: FocusAgenda(timeZoneID: zone, bufferMinutes: 0,
            slots: [.init(title: "Écrire", startMinute: 590, endMinute: 620)]))
        let adjusted = try XCTUnwrap(FocusDayPlanner.reflow(plan: plan, now: preciseNow).agenda)
        XCTAssertEqual(adjusted.slots[0].startMinute, 601)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(FocusDayPlanner.date(day: day, minute: adjusted.slots[0].startMinute, timeZoneID: zone)), preciseNow)

        // Europe/Paris repeats 02:00–03:00. Agenda dates deliberately use the first occurrence.
        plan = FocusPlan(day: "2026-10-25", agenda: FocusAgenda(timeZoneID: zone, startMinute: 0, endMinute: 1440, bufferMinutes: 0,
            slots: [.init(title: "Créneau de la première heure", startMinute: 130, endMinute: 170)]))
        let secondOccurrence = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T01:30:00Z"))
        XCTAssertNil(FocusDayPlanner.currentSlot(plan: plan, at: secondOccurrence))
        XCTAssertNil(FocusDayPlanner.nextSlot(plan: plan, at: secondOccurrence))
        let afterRepeatedHour = try XCTUnwrap(FocusDayPlanner.reflow(plan: plan, now: secondOccurrence).agenda)
        XCTAssertEqual(afterRepeatedHour.slots[0].startMinute, 180)
        plan.agenda?.slots[0].state = .active
        XCTAssertFalse(FocusDayPlanner.reflow(plan: plan, now: secondOccurrence).conflicts.isEmpty)
    }

}
#endif
