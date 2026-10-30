#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// T-046 L9 lot 3 : la logique que les boutons, champs et interrupteurs de la page Concentration
/// appellent (brouillon de séance, plan du jour, bilan, issue d'une séance).
final class T046UnitConcentrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1792065600)  // 2026-10-15 12:00 UTC

    @MainActor private func controller() throws -> ConcentrationController {
        let root = URL(fileURLWithPath: "/private/tmp/t046-concentration-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false
        try store.saveSettings(settings)
        return try ConcentrationController(store: store, clock: { [now] in now })
    }

    private func defaults() -> UserDefaults {
        let name = "t046-concentration-" + UUID().uuidString
        let value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    // « Je fais… », durée, rythme, « Verrouiller », « Aussi pendant les pauses » (J-0106, J-0111…J-0114)
    func testComposerDraftBuildsTheModeAndOnlyLocksWhenAllowed() {
        var draft = FocusComposerDraft()
        XCTAssertEqual(draft.mode.minutes, 50)
        draft.free = .open
        XCTAssertNil(draft.mode.minutes)
        XCTAssertFalse(draft.canLock)
        draft.lock = true
        XCTAssertFalse(draft.locks(hasLists: true), "une séance sans fin ne se verrouille pas")
        draft.free = .custom; draft.customMinutes = 45
        XCTAssertEqual(draft.mode.minutes, 45)
        XCTAssertTrue(draft.locks(hasLists: true))
        XCTAssertFalse(draft.locks(hasLists: false), "sans liste, rien à verrouiller")
        draft.kind = .pomodoro; draft.rhythm = .long; draft.cycles = 4
        XCTAssertEqual([draft.mode.workMinutes, draft.mode.shortBreakMinutes, draft.mode.longBreakMinutes, draft.mode.longBreakEvery], [50, 10, 20, 3])
        XCTAssertEqual(draft.mode.cycles, 4)
        draft.rhythm = .custom; draft.work = 30; draft.shortBreak = 6; draft.longBreak = 20; draft.every = 2
        XCTAssertEqual([draft.mode.workMinutes, draft.mode.shortBreakMinutes, draft.mode.longBreakMinutes, draft.mode.longBreakEvery], [30, 6, 20, 2])
        draft.kind = .free
        XCTAssertNil(draft.mode.cycles)
    }

    func testComposerDraftRemembersTheRhythmButNotTheIntentionAndClampsStoredValues() {
        let store = defaults()
        var draft = FocusComposerDraft()
        draft.intent = "Écrire"; draft.kind = .pomodoro; draft.rhythm = .custom; draft.work = 40; draft.cycles = 6; draft.free = .custom
        draft.remember(store)
        let restored = FocusComposerDraft.remembered(store)
        XCTAssertEqual(restored.intent, "")
        XCTAssertEqual(restored.kind, .pomodoro); XCTAssertEqual(restored.rhythm, .custom)
        XCTAssertEqual(restored.work, 40); XCTAssertEqual(restored.cycles, 6); XCTAssertEqual(restored.free, .custom)
        store.set(["customMinutes": 999, "work": 1, "short": 99, "long": 1, "every": 50, "cycles": 99, "free": 33], forKey: "goalong.concentration.composer.v1")
        let clamped = FocusComposerDraft.remembered(store)
        XCTAssertEqual([clamped.customMinutes, clamped.work, clamped.shortBreak, clamped.longBreak, clamped.every], [240, 5, 30, 5, 8])
        XCTAssertNil(clamped.cycles); XCTAssertEqual(clamped.free, .minutes(50))
    }

    // « Première tâche du jour », estimation, projet (J-0128, J-0130)
    @MainActor func testAddingPlanItemsKeepsProjectEstimateAndTheTenItemLimit() throws {
        let c = try controller(); let day = BlockingController.dayKey(now)
        let item = try c.addPlanItem(title: "Rédiger", day: day, project: "Livre", estimateMinutes: 90)
        XCTAssertEqual(try c.plan(on: day).items.first?.project, "Livre")
        XCTAssertEqual(try c.plan(on: day).items.first?.estimateMinutes, 90)
        XCTAssertEqual(item.title, "Rédiger")
        XCTAssertThrowsError(try c.addPlanItem(title: "Trop court", day: day, estimateMinutes: 4))
        XCTAssertThrowsError(try c.addPlanItem(title: "Trop long", day: day, estimateMinutes: 601))
        for index in 2...10 { try c.addPlanItem(title: "Tâche \(index)", day: day) }
        XCTAssertThrowsError(try c.addPlanItem(title: "Onzième", day: day)) { XCTAssertEqual($0 as? FocusFailure, .planFull) }
    }

    // Case à cocher, « Déplacer à demain », « Abandonner », « Rouvrir », « Retirer du plan » (J-0122…J-0127)
    @MainActor func testPlanItemMenuActions() throws {
        let c = try controller(); let day = BlockingController.dayKey(now), tomorrow = try c.dayAfter(day)
        let a = try c.addPlanItem(title: "A", day: day), b = try c.addPlanItem(title: "B", day: day), d = try c.addPlanItem(title: "D", day: day)
        try c.setItemStatus(a.id, day: day, status: .done)
        XCTAssertEqual(try c.plan(on: day).items.first { $0.id == a.id }?.status, .done)
        try c.reopenPlanItem(a.id, day: day)
        XCTAssertEqual(try c.plan(on: day).items.first { $0.id == a.id }?.status, .open)
        try c.setItemStatus(b.id, day: day, status: .dropped)
        XCTAssertEqual(try c.plan(on: day).items.first { $0.id == b.id }?.status, .dropped)
        XCTAssertThrowsError(try c.movePlanItem(b.id, day: day, to: tomorrow)) { XCTAssertEqual($0 as? FocusFailure, .itemFinished) }
        try c.movePlanItem(d.id, day: day, to: tomorrow)
        let moved = try c.plan(on: day).items.first { $0.id == d.id }
        XCTAssertEqual(moved?.status, .moved); XCTAssertEqual(moved?.toDay, tomorrow)
        XCTAssertEqual(try c.plan(on: tomorrow).items.map(\.title), ["D"])
        XCTAssertThrowsError(try c.setItemStatus(a.id, day: day, status: .moved))
        var next = try c.plan(on: day); next.items.removeAll { $0.id == b.id }
        try c.setPlan(next)
        XCTAssertEqual(try c.plan(on: day).items.count, 2)
        next.items.removeAll(); XCTAssertThrowsError(try c.setPlan(next), "un plan vide ne s'enregistre pas")
    }

    // « Enregistrer » / « Ajouter une intention du jour » (J-0119…J-0121)
    @MainActor func testDayIntentionIsSavedTrimmedToTheLimit() throws {
        let c = try controller(); let day = BlockingController.dayKey(now)
        try c.addPlanItem(title: "A", day: day)
        var plan = try c.plan(on: day); plan.intention = "Finir le chapitre"
        try c.setPlan(plan)
        XCTAssertEqual(try c.plan(on: day).intention, "Finir le chapitre")
        plan.intention = String(repeating: "x", count: 141)
        XCTAssertThrowsError(try c.setPlan(plan))
    }

    // Boutons « Non », « En partie », « Sans réponse », note (J-0132…J-0135, J-0143…J-0146)
    @MainActor func testSessionOutcomeButtonsRecordTheAnswerAndTheNote() throws {
        let c = try controller(); let day = BlockingController.dayKey(now)
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: 25))
        try c.stopSession(outcome: .partly, note: "Presque")
        let id = try XCTUnwrap(c.sessions(on: day).first?.id)
        XCTAssertEqual(try c.sessions(on: day).first?.outcome, .partly)
        try c.recordOutcome(sessionID: id, outcome: .notDone)
        XCTAssertEqual(try c.sessions(on: day).first?.outcome, .notDone)
        try c.recordOutcome(sessionID: id, outcome: nil)
        XCTAssertNil(try c.sessions(on: day).first?.outcome, "« Sans réponse »")
        XCTAssertThrowsError(try c.recordOutcome(sessionID: id, outcome: .done, note: String(repeating: "x", count: 501)))
        XCTAssertThrowsError(try c.recordOutcome(sessionID: UUID(), outcome: .done)) { XCTAssertEqual($0 as? FocusFailure, .notFound) }
    }

    // Puces du plan comme intention, « Commencer » (J-0115, J-0107)
    @MainActor func testStartingASessionLinksAnOpenPlanItemOnly() throws {
        let c = try controller(); let day = BlockingController.dayKey(now)
        let item = try c.addPlanItem(title: "Relire", day: day)
        XCTAssertEqual(c.openPlanItemID(item.id), item.id)
        XCTAssertNil(c.openPlanItemID(UUID()))
        try c.startSession(intent: "Relire", mode: FocusMode(minutes: 25), planItemId: item.id)
        XCTAssertEqual(c.currentSession?.planItemId, item.id)
        XCTAssertThrowsError(try c.startSession(intent: "Autre", mode: FocusMode(minutes: 25))) { XCTAssertEqual($0 as? FocusFailure, .invalidArgument) }
        try c.stopSession()
        try c.setItemStatus(item.id, day: day, status: .done)
        XCTAssertNil(c.openPlanItemID(item.id), "une tâche faite ne sert plus d'intention")
        XCTAssertThrowsError(try c.startSession(intent: "Relire", mode: FocusMode(minutes: 25), planItemId: item.id)) { XCTAssertEqual($0 as? FocusFailure, .notFound) }
        XCTAssertThrowsError(try c.startSession(intent: "Bloquer", mode: FocusMode(minutes: 25), blockListIds: [UUID()]))
    }

    // « Faire le bilan », « Une note, si vous voulez », « La première chose à faire demain » (J-0118, J-0143, J-0149)
    @MainActor func testReviewSavesOutcomesTomorrowFirstAndNote() throws {
        let c = try controller(); let day = BlockingController.dayKey(now), tomorrow = try c.dayAfter(day)
        let a = try c.addPlanItem(title: "A", day: day), b = try c.addPlanItem(title: "B", day: day)
        try c.setReview(.init(day: day, items: [.init(id: a.id, outcome: .done), .init(id: b.id, outcome: nil, toDay: tomorrow)],
                              tomorrowFirst: "Reprendre B", note: "Bonne journée"))
        let review = try c.review(on: day)
        XCTAssertEqual(review.tomorrowFirst, "Reprendre B"); XCTAssertEqual(review.note, "Bonne journée")
        XCTAssertEqual(try c.plan(on: day).items.first { $0.id == a.id }?.status, .done)
        XCTAssertEqual(try c.plan(on: tomorrow).items.map(\.title), ["Reprendre B", "B"], "la première chose de demain passe en tête")
        XCTAssertThrowsError(try c.setReview(.init(day: day, items: [.init(id: UUID(), outcome: .done)]))) { XCTAssertEqual($0 as? FocusFailure, .notFound) }
        XCTAssertThrowsError(try c.setReview(.init(day: day, note: String(repeating: "x", count: 501))))
    }

    // Interrupteurs, heures d'invite, limites, « hh:mm », jours de fin de journée (J-0136…J-0141)
    @MainActor func testSettingsSwitchesLimitsAndEndOfDayWeekdays() throws {
        let c = try controller()
        var next = c.settings
        next.morningPrompt = true; next.morningMinute = 7 * 60 + 30; next.phaseSound = false
        try c.updateSettings(next)
        XCTAssertEqual(c.settings.morningMinute, 450); XCTAssertFalse(c.settings.phaseSound)
        next.limits.dailyHours = 1
        XCTAssertThrowsError(try c.updateSettings(next), "de 2 à 16 h par jour")
        next.limits.dailyHours = 8; next.limits.weeklyHours = 40
        try c.updateSettings(next)
        XCTAssertEqual(c.settings.limits.weeklyHours, 40)
        XCTAssertEqual(FocusUIFormat.minute("18:30"), 18 * 60 + 30)
        XCTAssertNil(FocusUIFormat.minute("25:00"))
        XCTAssertNil(FocusUIFormat.minute("abc"))
        var limits = c.settings; limits.limits.endMinute = 18 * 60; limits.limits.weekdays = [1]
        let removed = FocusLimitsEditing.toggled(limits, day: 1)
        XCTAssertEqual(removed.error, "Gardez au moins un jour.")
        XCTAssertEqual(removed.settings, limits)
        let added = FocusLimitsEditing.toggled(limits, day: 3)
        XCTAssertNil(added.error); XCTAssertEqual(added.settings.limits.weekdays, [1, 3])
    }

    // « Son nom dans « Mon travail » », pas-à-pas de la cible, « M’engager », liste de l'enjeu (J-0082, J-0083, J-0085, J-0086)
    func testCommitmentDraftDefaultsBoundsStepsAndCompleteness() {
        let day = FocusCommitmentPeriod(kind: .day, key: "2026-10-15")
        var draft = FocusCommitmentDraft(period: day)
        XCTAssertEqual(draft.target, 360); XCTAssertTrue(draft.complete)
        XCTAssertNil(draft.trimmedTask); XCTAssertNil(draft.stake)
        draft.kind = .task
        XCTAssertFalse(draft.complete, "un engagement sur une tâche exige son nom")
        draft.task = "  Livre  "
        XCTAssertTrue(draft.complete); XCTAssertEqual(draft.trimmedTask, "Livre")
        draft.stakeLists = [UUID()]
        XCTAssertEqual(draft.stake?.until, "12:00")
        XCTAssertEqual(FocusCommitmentDraft.defaultTarget(.task, .week), 600)
        XCTAssertEqual(FocusCommitmentDraft.range(.work, .day), 30...960)
        XCTAssertEqual(FocusCommitmentDraft.step(.work, .day), 15)
        XCTAssertEqual(FocusCommitmentDraft.step(.work, .week), 60)
        XCTAssertEqual(FocusCommitmentDraft.step(.sessions, .day), 1)
        for kind in [FocusCommitment.Kind.work, .task, .sessions, .plan] {
            for period in [FocusCommitmentPeriod.Kind.day, .week] {
                XCTAssertTrue(FocusCommitmentDraft.range(kind, period).contains(FocusCommitmentDraft.defaultTarget(kind, period)))
            }
        }
    }
}
#endif
