#if os(macOS)
import Combine
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryQueryCLI

/// Native state and CLI contracts only: no presenter, inference client or real application data.
@MainActor final class FocusDayGuideTests: XCTestCase {
    private let day = "2026-11-25"
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    private struct Fixture {
        let store: FocusStore
        let controller: ConcentrationController
        let clock: Clock
    }
    private func date(_ minute: Int, day: String = "2026-11-25") -> Date {
        FocusDayPlanner.date(day: day, minute: minute, timeZoneID: "UTC")!
    }
    private func fixture(settings: FocusSettings = FocusSettings(), minute: Int = 600) throws -> Fixture {
        let directory = URL(fileURLWithPath: "/private/tmp/goalong-guide-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory)
        try store.saveSettings(settings)
        let clock = Clock(date(minute))
        let controller = try ConcentrationController(store: store, clock: { clock.now }, calendar: calendar,
            blocking: { nil }, runsTimers: false, continuous: { clock.now.timeIntervalSince1970 }, boot: { "guide-test" })
        addTeardownBlock { @MainActor in controller.shutdown() }
        return Fixture(store: store, controller: controller, clock: clock)
    }
    private func install(_ agenda: FocusAgenda, in fixture: Fixture) throws {
        var plan = fixture.controller.plan
        plan.agenda = agenda
        try fixture.controller.applyDayPlan(plan, expectedRevision: plan.effectiveRevision)
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func withRuntime(_ fixture: Fixture, _ body: (ConcentrationRuntime) throws -> Void) throws {
        let suite = "goalong-guide-cli-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: GoalongModule.concentration.defaultsKey)
        let runtime = ConcentrationRuntime(storeFactory: { fixture.store }, factory: { _ in fixture.controller },
            blockingProvider: { nil }, presentsPanels: false, clock: { fixture.clock.now }, calendar: calendar)
        runtime.start(modules: GoalongModuleStore(defaults: defaults))
        defer { runtime.apply(enabled: false) }
        try body(runtime)
    }
    private func setGuide(_ json: String, revision: Int) -> GoalongFocusRequest {
        GoalongFocusRequest(command: "guide set", options: ["--if-revision": String(revision)], body: Data(json.utf8))
    }

    func testGlobalGuideAndPresenterMustBothPermitAReminder() throws {
        let f = try fixture()
        let slot = FocusAgendaSlot(title: "Commencer le livrable", startMinute: 600, endMinute: 630, fixed: true)
        try install(FocusAgenda(timeZoneID: "UTC", guided: true, slots: [slot]), in: f)
        f.controller.refresh()
        XCTAssertNil(f.controller.panel, "An imported guided agenda cannot enable the global feature.")
        XCTAssertEqual(try f.store.prompts()?.agendaPromptCount ?? 0, 0)

        var presenterAllowed = false
        f.controller.guidanceMayPresent = { presenterAllowed }
        try f.controller.updateDayGuideSettings(.init(enabled: true))
        XCTAssertNil(f.controller.panel)
        XCTAssertEqual(try f.store.prompts()?.agendaPromptCount ?? 0, 0, "A blocked presenter must not consume the reminder.")

        presenterAllowed = true
        f.controller.refresh()
        XCTAssertEqual(f.controller.panel?.kind, .agenda)
        XCTAssertEqual(f.controller.panel?.slotID, slot.id)
        XCTAssertEqual(try f.store.prompts()?.agendaPromptCount, 1)
        f.controller.dismissPanel()
        f.controller.refresh()
        XCTAssertNil(f.controller.panel, "Closing a reminder does not replay it.")
        XCTAssertEqual(f.controller.plan.agenda?.slots.first?.state, .planned, "Closing is not completion.")
    }

    func testSilentSlotNeverConsumesAReminderEvenWhenTheAgendaIsGuided() throws {
        var settings = FocusSettings()
        settings.dayGuide = .init(enabled: true)
        let f = try fixture(settings: settings)
        var slot = FocusAgendaSlot(title: "Consigne hors du Mac", startMinute: 600, endMinute: 630, fixed: true)
        slot.reminder = .silent
        slot.instructions = "Préparer ce qui est nécessaire.\nContinuer sans rouvrir le Mac."
        try install(FocusAgenda(timeZoneID: "UTC", guided: true, slots: [slot]), in: f)
        f.controller.refresh()
        XCTAssertNil(f.controller.panel)
        XCTAssertEqual(try f.store.prompts()?.agendaPromptCount ?? 0, 0)
        XCTAssertEqual(f.controller.plan.agenda?.slots.first?.instructions, slot.instructions)
    }

    func testExplicitReminderOverridesOnlyTheAgendaDefault() throws {
        let f = try fixture()
        var slot = FocusAgendaSlot(title: "Transition choisie", startMinute: 600, endMinute: 630, fixed: true)
        slot.reminder = .notify
        slot.instructions = "Enregistrer le résultat.\nLire la prochaine étape."
        try install(FocusAgenda(timeZoneID: "UTC", guided: false, slots: [slot]), in: f)
        f.controller.refresh()
        XCTAssertNil(f.controller.panel, "notify cannot enable the global guide.")
        try f.controller.updateDayGuideSettings(.init(enabled: true, remindersEnabled: false))
        XCTAssertNil(f.controller.panel, "notify cannot bypass the master reminder switch.")
        try f.controller.updateDayGuideSettings(.init(enabled: true, quietStartMinute: 600, quietEndMinute: 660))
        XCTAssertNil(f.controller.panel, "notify cannot bypass quiet hours.")
        XCTAssertEqual(try f.store.prompts()?.agendaPromptCount ?? 0, 0)

        try f.controller.updateDayGuideSettings(.init(enabled: true))
        XCTAssertEqual(f.controller.panel?.slotID, slot.id)
        XCTAssertEqual(f.controller.panel?.text, slot.instructions, "The actual instructions take precedence over the short title.")
        XCTAssertEqual(try f.store.prompts()?.agendaPromptCount, 1)
        try f.controller.updateDayGuideSettings(.init(enabled: true, remindersEnabled: false))
        XCTAssertNil(f.controller.panel, "Pausing reminders dismisses an already visible guidance panel.")
    }

    func testQuietNightCrossesMidnightAndReleasesAtTheBoundaryWithoutACoach() throws {
        var settings = FocusSettings()
        settings.dayGuide = .init(enabled: true, quietStartMinute: 1320, quietEndMinute: 480)
        var overnight = FocusAgendaSlot(title: "Temps calme", startMinute: 0, endMinute: 480, fixed: true)
        overnight.reminder = .notify
        var wake = FocusAgendaSlot(title: "Commencer la journée", startMinute: 480, endMinute: 510, fixed: true)
        wake.reminder = .notify
        var evening = FocusAgendaSlot(title: "Après la fermeture", startMinute: 1320, endMinute: 1440, fixed: true)
        evening.reminder = .notify
        settings.agendaTemplate = FocusAgenda(timeZoneID: "UTC", guided: false, slots: [overnight, wake, evening])
        let f = try fixture(settings: settings, minute: 1380)
        f.controller.refresh()
        XCTAssertNil(f.controller.panel)
        for minute in [0, 1, 479] {
            f.clock.now = date(minute, day: "2026-11-26")
            f.controller.refresh()
            XCTAssertNil(f.controller.panel)
            XCTAssertEqual(try f.store.prompts()?.agendaPromptCount ?? 0, 0)
        }
        f.clock.now = date(480, day: "2026-11-26")
        f.controller.refresh()
        XCTAssertEqual(f.controller.panel?.slotID, wake.id)
        XCTAssertEqual(try f.store.prompts()?.agendaPromptCount, 1, "Nighttime slots are not replayed.")
        XCTAssertNil(f.controller.settings.coach)
        XCTAssertFalse(f.controller.settings.coachSettings.enabled)
        XCTAssertNil(f.controller.settings.coachSettings.model)
    }

    func testQuietHoursValidateBothEndsAndUseAnExclusiveEnd() {
        for settings in [
            FocusDayGuideSettings(quietStartMinute: 0),
            FocusDayGuideSettings(quietEndMinute: 480),
            FocusDayGuideSettings(quietStartMinute: -1, quietEndMinute: 480),
            FocusDayGuideSettings(quietStartMinute: 0, quietEndMinute: 1440),
            FocusDayGuideSettings(quietStartMinute: 480, quietEndMinute: 480)
        ] { XCTAssertFalse(settings.valid) }
        let night = FocusDayGuideSettings(quietStartMinute: 0, quietEndMinute: 480)
        XCTAssertTrue(night.valid)
        XCTAssertTrue(night.isQuiet(minute: 0))
        XCTAssertTrue(night.isQuiet(minute: 479))
        XCTAssertFalse(night.isQuiet(minute: 480))
        XCTAssertFalse(FocusDayGuideSettings().isQuiet(minute: 0))
    }

    func testRoutineSetPublishesTheCurrentPlanWithoutAnExistingDailyFile() throws {
        let f = try fixture()
        XCTAssertNil(try f.store.plan(day))
        XCTAssertNil(f.controller.plan.agenda)
        var published: [FocusPlan] = []
        let subscription = f.controller.$plan.sink { published.append($0) }
        defer { subscription.cancel() }
        try withRuntime(f) { runtime in
            let payload = try data(["agenda": [
                "timeZoneID": "UTC", "guided": false,
                "slots": [["title": "Repère choisi", "startMinute": 720, "endMinute": 750,
                           "fixed": true, "instructions": "Suivre la consigne enregistrée.", "reminder": "silent"]]
            ]])
            let request = try GoalongFocusCLI.parse(command: "routine",
                arguments: ["set", "--if-revision", "0", "--file", "-"], readFile: { _ in payload })
            _ = try runtime.handle(request)
            XCTAssertEqual(f.controller.plan.agenda?.slots.first?.title, "Repère choisi")
            XCTAssertEqual(published.last?.agenda, f.controller.plan.agenda)
            XCTAssertEqual(f.controller.plan.agenda, f.controller.settings.agendaTemplate)
            XCTAssertFalse(f.controller.settings.dayGuideSettings.enabled)
            XCTAssertNil(f.controller.settings.coach)
            let shown = try FocusJSON.decode(FocusPlan.self, from: runtime.handle(
                GoalongFocusCLI.parse(command: "plan", arguments: ["show", day])))
            XCTAssertEqual(shown.agenda, f.controller.plan.agenda)
            XCTAssertThrowsError(try runtime.handle(request)) {
                XCTAssertEqual($0 as? GoalongFocusError, .conflict, "The routine write participates in configuration CAS.")
            }
        }
    }

    func testGuideConfigurationRejectsStaleAndUnknownWritesWithoutLosingPreferences() throws {
        let f = try fixture()
        try withRuntime(f) { runtime in
            let shown = try object(runtime.handle(GoalongFocusCLI.parse(command: "guide", arguments: ["show"])))
            XCTAssertEqual(shown["revision"] as? Int, 0)
            let first = try runtime.handle(setGuide(
                #"{"dayGuide":{"enabled":true,"introVersion":1,"quietStartMinute":1320,"quietEndMinute":480}}"#, revision: 0))
            XCTAssertEqual(try object(first)["revision"] as? Int, 1)
            let saved = f.controller.settings
            XCTAssertThrowsError(try runtime.handle(setGuide(#"{"dayGuide":{"enabled":false}}"#, revision: 0))) {
                XCTAssertEqual($0 as? GoalongFocusError, .conflict)
            }
            for json in [
                #"{"unexpected":true}"#,
                #"{"dayGuide":{"enabled":false,"unexpected":true}}"#,
                #"{"coach":{"enabled":true,"apiKey":"not-a-credential"}}"#,
                #"{"dayGuide":{"quietStartMinute":1440}}"#
            ] {
                XCTAssertThrowsError(try runtime.handle(setGuide(json, revision: 1))) {
                    XCTAssertEqual($0 as? GoalongFocusError, .invalidArgument)
                }
                XCTAssertEqual(f.controller.settings, saved)
            }
            XCTAssertNil(f.controller.settings.coach)
            XCTAssertNil(f.controller.settings.agendaTemplate)
        }
    }

    func testPartialGuideConfigurationPreservesQuietHoursAndMasterReminderChoice() throws {
        let f = try fixture()
        try withRuntime(f) { runtime in
            _ = try runtime.handle(setGuide(
                #"{"dayGuide":{"enabled":false,"introVersion":1,"remindersEnabled":false,"quietStartMinute":1320,"quietEndMinute":480}}"#,
                revision: 0))
            _ = try runtime.handle(setGuide(#"{"dayGuide":{"enabled":true}}"#, revision: 1))
            let guide = f.controller.settings.dayGuideSettings
            XCTAssertTrue(guide.enabled)
            XCTAssertFalse(guide.remindersEnabled)
            XCTAssertEqual(guide.quietStartMinute, 1320)
            XCTAssertEqual(guide.quietEndMinute, 480)
            XCTAssertEqual(guide.introVersion, 1)
            XCTAssertEqual(f.controller.settings.effectiveGuideRevision, 2)

            _ = try runtime.handle(setGuide(#"{"dayGuide":null}"#, revision: 2))
            XCTAssertNil(f.controller.settings.dayGuide)
            XCTAssertFalse(f.controller.settings.dayGuideSettings.enabled)
            XCTAssertTrue(f.controller.settings.dayGuideSettings.remindersEnabled)
            XCTAssertNil(f.controller.settings.dayGuideSettings.quietStartMinute)
            XCTAssertNil(f.controller.settings.dayGuideSettings.quietEndMinute)
            XCTAssertEqual(f.controller.settings.dayGuideSettings.introVersion, 0)
        }
    }

    func testOlderSavedSettingsPreserveTheirExplicitPromptsAndGainNoPersonalDefaults() throws {
        var old = FocusSettings()
        old.morningPrompt = true; old.morningMinute = 420
        old.eveningPrompt = true; old.eveningMinute = 1140
        var legacy = try object(FocusJSON.encode(old))
        for key in ["dayGuide", "coach", "guideRevision", "agendaTemplate", "usePlanContext"] { legacy.removeValue(forKey: key) }
        let restored = try FocusJSON.decode(FocusSettings.self, from: data(legacy))
        XCTAssertTrue(restored.valid)
        XCTAssertTrue(restored.morningPrompt)
        XCTAssertTrue(restored.eveningPrompt)
        XCTAssertEqual(restored.morningMinute, 420)
        XCTAssertEqual(restored.eveningMinute, 1140)
        XCTAssertEqual(restored.effectiveGuideRevision, 0)
        XCTAssertFalse(restored.dayGuideSettings.enabled)
        XCTAssertNil(restored.dayGuideSettings.quietStartMinute)
        XCTAssertNil(restored.dayGuideSettings.quietEndMinute)
        XCTAssertNil(restored.coach)
        XCTAssertNil(restored.agendaTemplate)
        XCTAssertFalse(FocusSettings().morningPrompt)
        XCTAssertFalse(FocusSettings().eveningPrompt)
    }
}
#endif
