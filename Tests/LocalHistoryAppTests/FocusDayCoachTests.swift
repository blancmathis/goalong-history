#if os(macOS)
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class FocusDayCoachTests: XCTestCase {
    private let day = "2026-11-25"
    private var now: Date { FocusDayPlanner.date(day: day, minute: 1200, timeZoneID: "UTC")! }
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "UTC")!; return value }
    private func directory() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp/focus-day-coach-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func settings() -> FocusDayCoachSettings {
        var value = FocusDayCoachSettings()
        value.enabled = true; value.model = "fixture-model"; value.reasoningEffort = "low"; return value
    }
    private func selection(_ policy: GoalongPrivacyPolicy) -> GoalongAnalysisSelection {
        var value = GoalongAnalysisSelection()
        value.reviewed = true; value.privacyRevision = policy.revision; value.scope = GoalongAnalysisScope()
        return value
    }
    @MainActor private func controller(_ root: URL) throws -> ConcentrationController {
        let store = FocusStore(directory: root.appendingPathComponent("Focus"))
        var value = FocusSettings(); value.morningPrompt = false; value.eveningPrompt = false; value.coach = settings()
        try store.saveSettings(value)
        let instant = now
        return try ConcentrationController(store: store, clock: { instant }, calendar: calendar)
    }

    func testDefaultsAreOffAndDoNotInventAProviderModel() throws {
        let value = FocusDayCoachSettings()
        XCTAssertTrue(value.valid); XCTAssertFalse(value.enabled)
        XCTAssertNil(value.model); XCTAssertNil(value.reasoningEffort)
        XCTAssertEqual(try JSONDecoder().decode(FocusDayCoachSettings.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(try JSONDecoder().decode(FocusDayCoachSettings.self, from: Data("{}".utf8)), value)
        var enabled = value; enabled.enabled = true
        XCTAssertFalse(enabled.valid)
        enabled.provider = .externalAgent
        XCTAssertTrue(enabled.valid)
        enabled.dailyCallLimit = 100
        XCTAssertFalse(enabled.valid)
    }
    func testModelCatalogUsesReturnedIdentifiersAndEffortsAndHidesInternalModels() {
        let raw: [String: Any] = ["model": "future-model-v2", "displayName": "Future model",
                                 "defaultReasoningEffort": "low",
                                 "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"]]]
        let value = FocusDayCoachModel.decodeCatalogEntry(raw)
        XCTAssertEqual(value?.id, "future-model-v2")
        XCTAssertEqual(value?.reasoningEfforts, ["low", "medium"])
        var hidden = raw; hidden["hidden"] = true
        XCTAssertNil(FocusDayCoachModel.decodeCatalogEntry(hidden))
        var noEffort = raw; noEffort["supportedReasoningEfforts"] = []
        XCTAssertNil(FocusDayCoachModel.decodeCatalogEntry(noEffort))
    }
    func testPreviewIsBoundedMaskedAndExcludesUrlsAndAgentMessages() throws {
        let policy = GoalongPrivacyPolicy()
        var selection = selection(policy)
        selection.replacements = [.init(search: "SENSIBLE", replacement: "[masqué]")]
        var plan = FocusPlan(day: day)
        plan.items = (0..<10).map { FocusPlanItem(title: "SENSIBLE \($0)", nextAction: String(repeating: "x", count: 200),
                                                 doneWhen: String(repeating: "y", count: 200), contextURL: "https://example.com/private-task") }
        plan.processes = (0..<64).map { FocusAgentProcess(title: "SENSIBLE processus \($0)", externalID: "external-secret",
                                                        contextURL: "https://example.com/private-process", status: .running,
                                                        question: "RAW-QUESTION-SECRET", answer: "RAW-ANSWER-SECRET") }
        plan.processes?[63].status = .waitingForYou; plan.processes?[63].answer = nil
        plan.agenda = FocusAgenda(timeZoneID: "UTC", slots: (0..<64).map {
            FocusAgendaSlot(title: String(repeating: "z", count: 140), startMinute: $0 * 20, endMinute: $0 * 20 + 10)
        })
        let value = try FocusDayCoachContext.make(plan: plan, review: nil, settings: settings(),
                                                  note: "SENSIBLE obstacle", policy: policy, selection: selection)
        XCTAssertLessThanOrEqual(value.characterCount, 12_000)
        XCTAssertFalse(value.outboundText.contains("SENSIBLE"))
        XCTAssertTrue(value.prompt.contains("[masqué]"))
        for excluded in ["private-task", "private-process", "RAW-QUESTION-SECRET", "RAW-ANSWER-SECRET", "external-secret"] {
            XCTAssertFalse(value.outboundText.contains(excluded), excluded)
        }
        XCTAssertTrue(value.prompt.contains("processus 63"))
        XCTAssertTrue(value.prompt.contains("omitted_processes"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.prompt.utf8)) as? [String: Any])
        XCTAssertLessThanOrEqual((object["processes"] as? [Any])?.count ?? 100, 12)
        XCTAssertEqual(object["flexible_work_end_minute"] as? Int, plan.agenda?.endMinute)
        XCTAssertEqual(object["buffer_minutes"] as? Int, plan.agenda?.bufferMinutes)
    }
    func testUnselectedDataAndUnreviewedPrivacyNeverLeakIntoPreview() throws {
        let policy = GoalongPrivacyPolicy()
        var options = settings(); options.includeTasks = false; options.includeAgenda = false; options.includeProcesses = false
        let plan = FocusPlan(day: day, items: [.init(title: "HIDDEN-TASK")])
        let value = try FocusDayCoachContext.make(plan: plan, review: FocusReview(day: day, note: "HIDDEN-REVIEW"),
                                                  settings: options, note: "", policy: policy, selection: selection(policy))
        XCTAssertFalse(value.prompt.contains("HIDDEN"))
        var stale = selection(policy); stale.privacyRevision = "old"
        XCTAssertThrowsError(try FocusDayCoachContext.make(plan: plan, review: nil, settings: options,
                                                           note: "", policy: policy, selection: stale))
        var blocked = policy; blocked.blocked = true
        XCTAssertThrowsError(try FocusDayCoachContext.make(plan: plan, review: nil, settings: options,
                                                           note: "", policy: blocked, selection: selection(blocked)))
    }
    func testResponseIsShortAndRejectsExtraActionsRatherThanApplyingThem() throws {
        let good = Data(#"{"summary":"Une étape utile.","nextAction":"Rédiger le premier paragraphe.","adjustment":"","question":""}"#.utf8)
        XCTAssertEqual(try FocusDayCoachAnswer.parse(good, maximumCharacters: 1400).nextAction, "Rédiger le premier paragraphe.")
        let extra = Data(#"{"summary":"OK","nextAction":"OK","adjustment":"","question":"","apply_agenda":true}"#.utf8)
        XCTAssertThrowsError(try FocusDayCoachAnswer.parse(extra, maximumCharacters: 1400))
        let questions = Data(#"{"summary":"OK","nextAction":"OK","adjustment":"","question":"Pourquoi ? Quand ?"}"#.utf8)
        XCTAssertThrowsError(try FocusDayCoachAnswer.parse(questions, maximumCharacters: 1400))
        let long = try JSONEncoder().encode(FocusDayCoachAnswer(summary: String(repeating: "x", count: 351), nextAction: "OK", adjustment: "", question: ""))
        XCTAssertThrowsError(try FocusDayCoachAnswer.parse(long, maximumCharacters: 1400))
    }
    func testAttemptsSurviveRelaunchFailuresAndChangingTheLimit() throws {
        let root = try directory()
        let store = FocusDayCoachUsageStore(directory: root.appendingPathComponent("coach"))
        let id = try store.reserve(day: day, now: now, limit: 2)
        _ = try store.reserve(day: day, now: now, limit: 2)
        let reopened = FocusDayCoachUsageStore(directory: store.directory)
        XCTAssertThrowsError(try reopened.reserve(day: day, now: now, limit: 2))
        try reopened.settle(id, tokens: 321)
        let value = try reopened.load().status(day: day, settings: settings(), busy: false)
        XCTAssertEqual(value.calls, 2); XCTAssertEqual(value.remaining, 0)
        XCTAssertEqual(value.knownTokens, 321); XCTAssertEqual(value.unreportedCalls, 1)
        _ = try reopened.reserve(day: day, now: now, limit: 3)
        XCTAssertThrowsError(try reopened.reserve(day: day, now: now, limit: 1))
    }
    func testCorruptOrSymlinkedLedgerFailsClosed() throws {
        let root = try directory()
        let store = FocusDayCoachUsageStore(directory: root.appendingPathComponent("coach"))
        _ = try store.reserve(day: day, now: now, limit: 2)
        let file = store.directory.appendingPathComponent("usage.json")
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try store.reserve(day: day, now: now, limit: 2))
        try FileManager.default.removeItem(at: file)
        let other = root.appendingPathComponent("other")
        try Data("{}".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try store.load())
    }

    @MainActor func testStartupStatusAndPreviewNeverCreateASessionAndCatalogueNeverGenerates() async throws {
        let root = try directory(), controller = try controller(root)
        let policy = GoalongPrivacyPolicy(), selected = selection(policy), session = CoachFixtureSession()
        var made = 0
        let runtime = FocusDayCoachRuntime(store: .init(directory: root.appendingPathComponent("coach")),
            clock: { self.now }, calendar: calendar, consent: { true }, privacy: { policy }, selection: { selected },
            makeSession: { made += 1; return session }, observeChanges: false)
        _ = try runtime.status(settings: settings())
        runtime.preparePreview(controller: controller)
        XCTAssertNotNil(runtime.preview); XCTAssertEqual(made, 0)
        let models = try await runtime.loadModels()
        XCTAssertEqual(models.first?.id, "fixture-model")
        XCTAssertEqual(made, 1); XCTAssertEqual(session.generations, 0)
        XCTAssertEqual(try runtime.status(settings: settings()).calls, 0)
    }
    @MainActor func testExplicitAdviceCountsFailuresAndDoesNotMutatePlan() async throws {
        let root = try directory(), controller = try controller(root)
        let policy = GoalongPrivacyPolicy(), selected = selection(policy), session = CoachFixtureSession()
        let runtime = FocusDayCoachRuntime(store: .init(directory: root.appendingPathComponent("coach")),
            clock: { self.now }, calendar: calendar, consent: { true }, privacy: { policy }, selection: { selected },
            makeSession: { session }, observeChanges: false)
        let original = controller.plan
        runtime.preparePreview(controller: controller)
        try await runtime.generate(controller: controller)
        XCTAssertNotNil(runtime.result); XCTAssertEqual(controller.plan, original)
        XCTAssertEqual(session.seenPrompt, runtime.preview?.prompt)
        XCTAssertEqual(try runtime.status(settings: settings()).calls, 1)
        session.failAfterSend = true
        do { try await runtime.generate(controller: controller); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(try runtime.status(settings: settings()).calls, 2)
        do { try await runtime.generate(controller: controller); XCTFail("Expected cap") } catch {}
        XCTAssertEqual(session.generations, 2)
    }
    @MainActor func testOnlyOneRequestCanRunAndCancellationKeepsItsAttempt() async throws {
        let root = try directory(), controller = try controller(root)
        let policy = GoalongPrivacyPolicy(), selected = selection(policy), session = CoachFixtureSession()
        let started = expectation(description: "request sent"), gate = DispatchSemaphore(value: 0)
        session.afterSend = { started.fulfill(); _ = gate.wait(timeout: .now() + 5) }
        let runtime = FocusDayCoachRuntime(store: .init(directory: root.appendingPathComponent("coach")),
            clock: { self.now }, calendar: calendar, consent: { true }, privacy: { policy }, selection: { selected },
            makeSession: { session }, observeChanges: false)
        runtime.preparePreview(controller: controller)
        let first = Task { try await runtime.generate(controller: controller) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(runtime.isBusy)
        do { try await runtime.generate(controller: controller); XCTFail("Expected busy") } catch {}
        runtime.cancel()
        XCTAssertTrue(runtime.isBusy)
        gate.signal()
        do { try await first.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertFalse(runtime.isBusy); XCTAssertNil(runtime.result)
        XCTAssertEqual(try runtime.status(settings: settings()).calls, 1)
        XCTAssertEqual(session.generations, 1)
    }

    @MainActor func testChangedSelectionStopsBeforeSendingAndNoConsentCannotLoadCatalogue() async throws {
        let root = try directory(), controller = try controller(root)
        let policy = GoalongPrivacyPolicy()
        var selected = selection(policy), consent = true
        let session = CoachFixtureSession()
        let runtime = FocusDayCoachRuntime(store: .init(directory: root.appendingPathComponent("coach")),
            clock: { self.now }, calendar: calendar, consent: { consent }, privacy: { policy }, selection: { selected },
            makeSession: { session }, observeChanges: false)
        runtime.preparePreview(controller: controller)
        selected.revision = "changed"
        do { try await runtime.generate(controller: controller); XCTFail("Expected stale preview") } catch {}
        XCTAssertEqual(session.generations, 0)
        XCTAssertEqual(try runtime.status(settings: settings()).calls, 0)
        consent = false
        do { _ = try await runtime.loadModels(); XCTFail("Expected consent gate") } catch {}
        XCTAssertEqual(session.catalogueReads, 0)
    }
}

private final class CoachFixtureSession: FocusDayCoachSession {
    var generations = 0
    var catalogueReads = 0
    var failAfterSend = false
    var afterSend: (() -> Void)?
    var seenPrompt: String?
    func focusDayCoachModels() throws -> [FocusDayCoachModel] {
        catalogueReads += 1
        return [.init(id: "fixture-model", displayName: "Fixture", reasoningEfforts: ["low"], defaultReasoningEffort: "low")]
    }
    func readAccountLimits() -> GoalongAccountLimits? { nil }
    func generateFocusDayCoach(preview: FocusDayCoachPreview, workingDirectory: URL,
                               beforeSend: @escaping () throws -> Void) throws -> (data: Data, tokens: Int?) {
        try beforeSend()
        generations += 1; seenPrompt = preview.prompt
        afterSend?()
        if failAfterSend { throw FocusDayCoachFailure.invalidResponse }
        return (Data(#"{"summary":"Une étape utile.","nextAction":"Rédiger le premier paragraphe.","adjustment":"","question":""}"#.utf8), 123)
    }
    func close() {}
}
#endif
