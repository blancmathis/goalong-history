#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class FocusDayControllerTests: XCTestCase {
    private let day = "2026-11-25"
    private var now: Date { FocusDayPlanner.date(day: day, minute: 600, timeZoneID: "UTC")! }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func store(guided: Bool = false) throws -> FocusStore {
        let url = URL(fileURLWithPath: "/private/tmp/focus-day-controller-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = FocusStore(directory: url)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false
        if guided { settings.dayGuide = .init(enabled: true) }
        try store.saveSettings(settings); return store
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: FocusJSON.encode(value)) }

    @MainActor func testTwoAgentsMustRebaseWithoutLosingTheirProcesses() throws {
        let s = try store(), instant = now
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let first = FocusAgentProcess(title: "Documentation", status: .running)
        let second = FocusAgentProcess(title: "Vidéo", status: .running)
        let p1 = try json(["processes": [object(first)]])
        let p2 = try json(["processes": [object(second)]])
        let one = try c.patchPlan(day: day, expectedRevision: 0, requestID: "agent-1", body: p1)
        XCTAssertEqual(one.effectiveRevision, 1)
        XCTAssertThrowsError(try c.patchPlan(day: day, expectedRevision: 0, requestID: "agent-2", body: p2)) {
            XCTAssertEqual($0 as? FocusFailure, .conflict)
        }
        let two = try c.patchPlan(day: day, expectedRevision: 1, requestID: "agent-2", body: p2)
        XCTAssertEqual(Set((two.processes ?? []).map(\.id)), [first.id, second.id])
        XCTAssertTrue(two.items.isEmpty)
        // A retry after another writer committed is still the same operation.
        XCTAssertEqual(try c.patchPlan(day: day, expectedRevision: 0, requestID: "agent-1", body: p1).effectiveRevision, 2)
        let restored = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        XCTAssertEqual(try restored.patchPlan(day: day, expectedRevision: 0, requestID: "agent-1", body: p1).processes?.count, 2)
        XCTAssertThrowsError(try c.patchPlan(day: day, expectedRevision: 2, requestID: "agent-1", body: p2)) {
            XCTAssertEqual($0 as? FocusFailure, .requestConflict)
        }
    }
    @MainActor func testAnswerIsRecordedWithoutInventingAResumedProcess() throws {
        let s = try store(), instant = now
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let process = FocusAgentProcess(title: "Relire", status: .waitingForYou, question: "Quel format ?")
        _ = try c.patchPlan(day: day, expectedRevision: 0, requestID: "question", body: json(["processes": [object(process)]]))
        try c.answerProcess(process.id, answer: "Une vidéo courte")
        XCTAssertEqual(c.plan.processes?.first?.status, .waitingForYou)
        XCTAssertEqual(c.plan.processes?.first?.answer, "Une vidéo courte")
        XCTAssertTrue(FocusDayPlanner.waitingProcesses(plan: c.plan).isEmpty)
        XCTAssertEqual(c.status.planRevision, c.plan.effectiveRevision)
        var nextQuestion = try XCTUnwrap(c.plan.processes?.first)
        nextQuestion.question = "Quelle durée ?"
        _ = try c.patchPlan(day: day, expectedRevision: c.plan.effectiveRevision, requestID: "new-question", body: json(["processes": [object(nextQuestion)]]))
        XCTAssertNil(c.plan.processes?.first?.answer)
        XCTAssertEqual(FocusDayPlanner.waitingProcesses(plan: c.plan).count, 1)
    }
    @MainActor func testMovingATaskKeepsBothDaysValidAndVersionsBoth() throws {
        let s = try store(), instant = now
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let item = FocusPlanItem(title: "Rédiger")
        var plan = FocusPlan(day: day, items: [item])
        plan.agenda = FocusAgenda(timeZoneID: "UTC", slots: [.init(itemID: item.id, title: "Rédiger", startMinute: 600, endMinute: 630)])
        try c.applyDayPlan(plan, expectedRevision: 0)
        try c.movePlanItem(item.id, day: day, to: "2026-11-26")
        XCTAssertEqual(c.plan.agenda?.slots.first?.state, .skipped)
        XCTAssertTrue(c.plan.valid)
        XCTAssertEqual(try c.plan(on: "2026-11-26").items.first?.id, item.id)
        try c.movePlanItem(item.id, day: day, to: "2026-11-27")
        XCTAssertTrue(try c.plan(on: "2026-11-26").items.isEmpty)
        XCTAssertTrue(try c.plan(on: "2026-11-26").valid)
        XCTAssertEqual(try c.plan(on: "2026-11-26").effectiveRevision, 2)
    }
    @MainActor func testFinishingAgendaCannotStopALockedSession() throws {
        let s = try store(), instant = now
        let list = BlockList(name: "Vidéos", sites: [.init(pattern: "example.org")])
        let blocking = BlockingController(document: BlockingDocument(lists: [list]), clock: { instant }, continuous: { instant.timeIntervalSince1970 })
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar, blocking: { blocking })
        let item = FocusPlanItem(title: "Documenter")
        let slot = FocusAgendaSlot(itemID: item.id, title: "Documenter", startMinute: 600, endMinute: 630)
        var plan = FocusPlan(day: day, items: [item]); plan.agenda = FocusAgenda(timeZoneID: "UTC", slots: [slot])
        try c.applyDayPlan(plan, expectedRevision: 0)
        try c.startSession(intent: item.title, mode: FocusMode(minutes: 25), planItemId: item.id, blockListIds: [list.id], lock: true)
        XCTAssertThrowsError(try c.finishAgendaSlot(slot.id)) { XCTAssertEqual($0 as? FocusFailure, .locked) }
        XCTAssertNotNil(c.currentSession)
        XCTAssertEqual(c.plan.items.first?.status, .open)
        XCTAssertEqual(c.plan.agenda?.slots.first?.state, .active)
        XCTAssertEqual(blocking.activeBlocks.first?.lock, .locked)
    }
    @MainActor func testDeclaredOutcomeCompletesLinkedTaskButTimerAloneDoesNot() throws {
        let s = try store(); var instant = now
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let item = FocusPlanItem(title: "Faire la vidéo")
        var plan = FocusPlan(day: day, items: [item]); plan.agenda = FocusAgenda(timeZoneID: "UTC", slots: [.init(itemID: item.id, title: item.title, startMinute: 600, endMinute: 630)])
        try c.applyDayPlan(plan, expectedRevision: 0)
        try c.startPlannedItem(item.id, mode: FocusMode(minutes: 5))
        let id = try XCTUnwrap(c.currentSession?.id)
        instant = instant.addingTimeInterval(300); c.refresh()
        XCTAssertNil(c.currentSession); XCTAssertEqual(c.plan.items.first?.status, .open)
        try c.recordOutcome(sessionID: id, outcome: .done)
        XCTAssertEqual(c.plan.items.first?.status, .done)
        XCTAssertEqual(c.plan.agenda?.slots.first?.state, .done)
    }
    @MainActor func testDailyTemplateHasNoFakeTasksAndCarriesUnfinishedProcesses() throws {
        let s = try store(); var instant = now
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let anchor = FocusAgendaSlot(title: "Repas", startMinute: 720, endMinute: 780, fixed: true)
        try c.updateAgendaTemplate(FocusAgenda(timeZoneID: "UTC", slots: [anchor]))
        let process = FocusAgentProcess(title: "Préparer le montage", status: .running)
        _ = try c.patchPlan(day: day, expectedRevision: c.plan.effectiveRevision, requestID: "start", body: json(["processes": [object(process)]]))
        instant = instant.addingTimeInterval(86_400); c.refresh()
        XCTAssertTrue(c.plan.items.isEmpty)
        XCTAssertEqual(c.plan.agenda?.slots.first?.title, "Repas")
        XCTAssertEqual(c.plan.agenda?.slots.first?.state, .planned)
        XCTAssertEqual(c.plan.processes?.first?.id, process.id)
        XCTAssertEqual(c.plan.processes?.first?.status, .running)
    }
    @MainActor func testRemovedCarriedProcessDoesNotReappearAfterRelaunch() throws {
        let s = try store(), instant = now
        let process = FocusAgentProcess(title: "Ancien processus", status: .running)
        var yesterday = FocusPlan(day: "2026-11-24"); yesterday.processes = [process]
        try s.savePlans([yesterday])
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        XCTAssertEqual(c.plan.processes?.count, 1)
        _ = try c.patchPlan(day: day, expectedRevision: c.plan.effectiveRevision, requestID: "remove", body: json(["removeProcessIDs": [process.id.uuidString]]))
        let restored = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        XCTAssertEqual(restored.plan.processes, [])
    }
    @MainActor func testOldOutcomeDoesNotResettleANewerSessionOnTheSameAction() throws {
        let s = try store(), instant = now
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let item = FocusPlanItem(title: "Documentation")
        var value = FocusPlan(day: day, items: [item])
        value.agenda = FocusAgenda(timeZoneID: "UTC", slots: [.init(itemID: item.id, title: item.title, startMinute: 600, endMinute: 630)])
        try c.applyDayPlan(value, expectedRevision: 0)
        try c.startPlannedItem(item.id)
        let first = try XCTUnwrap(c.currentSession?.id)
        try c.stopSession()
        try c.startPlannedItem(item.id)
        let second = try XCTUnwrap(c.currentSession?.id)
        try c.recordOutcome(sessionID: first, outcome: .done)
        XCTAssertEqual(c.currentSession?.id, second)
        XCTAssertEqual(c.plan.items.first?.status, .open)
        XCTAssertEqual(c.plan.agenda?.slots.first?.state, .active)
    }
    @MainActor func testStartingTheSecondSlotOfAnActionDoesNotResumeTheFirst() throws {
        let s = try store()
        let instant = FocusDayPlanner.date(day: day, minute: 665, timeZoneID: "UTC")!
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let item = FocusPlanItem(title: "Montage")
        var value = FocusPlan(day: day, items: [item])
        let first = FocusAgendaSlot(itemID: item.id, title: item.title, startMinute: 540, endMinute: 600, fixed: true)
        let second = FocusAgendaSlot(itemID: item.id, title: item.title, startMinute: 660, endMinute: 720, fixed: true)
        value.agenda = FocusAgenda(timeZoneID: "UTC", slots: [first, second])
        try c.applyDayPlan(value, expectedRevision: 0)
        try c.startAgendaSlot(second.id)
        XCTAssertNotNil(c.currentSession)
        let slots = try XCTUnwrap(c.plan.agenda?.slots)
        XCTAssertEqual(slots.first { $0.id == second.id }?.state, .active)
        XCTAssertNotEqual(slots.first { $0.id == first.id }?.state, .active)
    }
    @MainActor func testAgendaDraftAppliesContextChoiceAndAnchorsOnlyOnSave() throws {
        let s = try store(), instant = now
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let item = FocusPlanItem(title: "Montage")
        var value = FocusPlan(day: day, items: [item])
        value.agenda = FocusAgenda(timeZoneID: "UTC", slots: [
            .init(itemID: item.id, title: item.title, startMinute: 600, endMinute: 660),
            .init(title: "Repas", startMinute: 720, endMinute: 780, fixed: true, state: .done)])
        XCTAssertNotEqual(c.settings.usePlanContext, true)
        // A refused template writes nothing: neither the day nor the settings.
        XCTAssertThrowsError(try c.saveAgendaDraft(value, expectedRevision: 0, repeatTemplate: value.agenda, usePlanContext: true))
        XCTAssertNotEqual(c.settings.usePlanContext, true)
        XCTAssertNil(c.plan.agenda)
        try c.saveAgendaDraft(value, expectedRevision: 0, repeatTemplate: value.agenda?.repeatableTemplate, usePlanContext: true)
        XCTAssertEqual(c.settings.usePlanContext, true)
        XCTAssertEqual(c.settings.agendaTemplate?.slots.map(\.title), ["Repas"])
        XCTAssertEqual(c.plan.agenda?.slots.count, 2)
    }
    @MainActor func testGuidanceBudgetPersistsAndDoesNotReplayMissedSlots() throws {
        let s = try store(guided: true); var instant = now
        let c = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        let slots = (0..<12).map { FocusAgendaSlot(title: "Repère \($0)", startMinute: 600 + $0 * 10, endMinute: 610 + $0 * 10, fixed: true) }
        var plan = FocusPlan(day: day); plan.agenda = FocusAgenda(timeZoneID: "UTC", guided: true, slots: slots)
        try c.applyDayPlan(plan, expectedRevision: 0)
        for i in 0..<12 {
            instant = now.addingTimeInterval(Double(i * 600)); c.refresh()
            if i < 8 { XCTAssertEqual(c.panel?.slotID, slots[i].id) } else { XCTAssertNil(c.panel) }
            c.dismissPanel()
        }
        XCTAssertEqual(try s.prompts()?.agendaPromptCount, 8)
        let restored = try ConcentrationController(store: s, clock: { instant }, calendar: calendar)
        XCTAssertNil(restored.panel)
    }
}
#endif
