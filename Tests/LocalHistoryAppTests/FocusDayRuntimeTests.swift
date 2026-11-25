#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryQueryCLI

final class FocusDayRuntimeTests: XCTestCase {
    @MainActor private func withRuntime(_ body: (ConcentrationRuntime) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/goalong-day-runtime-" + UUID().uuidString)
        let suite = "goalong-day-runtime-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        defaults.set(true, forKey: GoalongModule.concentration.defaultsKey)
        let store = FocusStore(directory: directory)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false
        try store.saveSettings(settings)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-25T10:00:00Z"))
        let controller = try ConcentrationController(store: store, clock: { now }, calendar: calendar, runsTimers: false)
        let runtime = ConcentrationRuntime(storeFactory: { store }, factory: { _ in controller },
            blockingProvider: { nil }, presentsPanels: false, clock: { now }, calendar: calendar)
        runtime.start(modules: GoalongModuleStore(defaults: defaults))
        defer { runtime.apply(enabled: false) }
        try body(runtime)
    }

    private func request(_ action: String, revision: Int, id: String, body: Data? = nil) throws -> GoalongFocusRequest {
        var arguments = [action, "--day", "2026-11-25", "--if-revision", String(revision), "--request-id", id]
        if body != nil { arguments += ["--file", "-"] }
        return try GoalongFocusCLI.parse(command: "plan", arguments: arguments, readFile: { _ in body ?? Data() })
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor func testLegacyReadExposesRevisionZeroAndTomorrowUsesTheRuntimeCalendar() throws {
        try withRuntime { runtime in
            let today = try object(runtime.handle(GoalongFocusCLI.parse(command: "plan", arguments: ["show"])))
            XCTAssertEqual(today["revision"] as? Int, 0)
            XCTAssertEqual(today["day"] as? String, "2026-11-25")
            let tomorrow = try object(runtime.handle(GoalongFocusCLI.parse(command: "plan", arguments: ["show", "tomorrow"])))
            XCTAssertEqual(tomorrow["day"] as? String, "2026-11-26")
            XCTAssertEqual(tomorrow["revision"] as? Int, 0)
            XCTAssertTrue(try object(runtime.handle(GoalongFocusCLI.parse(command: "routine", arguments: ["show"])))["agenda"] is NSNull)
        }
    }

    @MainActor func testPatchCanonicalizesInputAndSurfacesIdempotenceAndRevisionConflicts() throws {
        try withRuntime { runtime in
            let itemID = UUID(), processID = UUID()
            let payload: [String: Any] = [
                "actor": "Test agent", "reason": "Préparer une action et un processus",
                "items": [["id": itemID.uuidString, "title": "Documenter", "status": "open", "actionKind": "work", "processIDs": [processID.uuidString]]],
                "processes": [["id": processID.uuidString, "title": "Implémenter", "status": "running"]],
            ]
            let compact = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let first = try FocusJSON.decode(FocusPlan.self, from: runtime.handle(request("patch", revision: 0, id: "launch-1", body: compact)))
            XCTAssertEqual(first.effectiveRevision, 1)
            XCTAssertEqual(first.items.first?.processIDs, [processID])
            XCTAssertEqual(first.processes?.first?.status, .running)
            XCTAssertEqual(first.receipts?.filter { $0.id == "launch-1" }.count, 1)

            // A transport retry with different JSON whitespace is the same mutation.
            let pretty = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            let retried = try FocusJSON.decode(FocusPlan.self, from: runtime.handle(request("patch", revision: 0, id: "launch-1", body: pretty)))
            XCTAssertEqual(retried.effectiveRevision, first.effectiveRevision)
            XCTAssertEqual(retried.items, first.items)
            XCTAssertEqual(retried.processes, first.processes)

            let changed = Data(#"{"reason":"Autre intention","intention":"Préparer une vidéo"}"#.utf8)
            XCTAssertThrowsError(try runtime.handle(request("patch", revision: 0, id: "stale-2", body: changed))) {
                XCTAssertEqual($0 as? GoalongFocusError, .conflict)
            }
            XCTAssertThrowsError(try runtime.handle(request("patch", revision: 1, id: "launch-1", body: changed))) {
                XCTAssertEqual($0 as? GoalongFocusError, .requestConflict)
            }
            let final = try FocusJSON.decode(FocusPlan.self, from: runtime.handle(GoalongFocusCLI.parse(command: "plan", arguments: ["show"])))
            XCTAssertEqual(final.effectiveRevision, 1)
            XCTAssertNil(final.intention)
        }
    }

    @MainActor func testRoutineSetClearAndInvalidTemplatesCannotEnableCoachContext() throws {
        try withRuntime { runtime in
            func set(_ source: String) throws -> Data {
                try runtime.handle(GoalongFocusCLI.parse(command: "routine", arguments: ["set", "--file", "-"], readFile: { _ in Data(source.utf8) }))
            }
            let original = #"{"agenda":{"timeZoneID":"Europe/Paris","slots":[{"title":"Déjeuner","startMinute":720,"endMinute":780,"fixed":true}]}}"#
            let saved = try object(set(original))
            XCTAssertNotNil(saved["agenda"] as? [String: Any])
            XCTAssertEqual(runtime.controller?.settings.agendaTemplate?.slots.first?.title, "Déjeuner")
            XCTAssertNotEqual(runtime.controller?.settings.usePlanContext, true)
            for source in [
                #"{"agenda":{"timeZoneID":"Unknown/Zone"}}"#,
                #"{"agenda":{"timeZoneID":"Europe/Paris","slots":[{"title":"A","startMinute":780,"endMinute":720}]}}"#,
                #"{"agenda":{"timeZoneID":"Europe/Paris","slots":[{"title":"A","startMinute":720,"endMinute":780,"state":"done"}]}}"#,
                #"{"agenda":null,"usePlanContext":true}"#,
            ] {
                XCTAssertThrowsError(try set(source)) { XCTAssertEqual($0 as? GoalongFocusError, .invalidArgument) }
                XCTAssertEqual(runtime.controller?.settings.agendaTemplate?.slots.first?.title, "Déjeuner")
            }
            XCTAssertTrue(try object(set(#"{"agenda":null}"#))["agenda"] is NSNull)
            XCTAssertNil(runtime.controller?.settings.agendaTemplate)
            XCTAssertNotEqual(runtime.controller?.settings.usePlanContext, true)
        }
    }

    @MainActor func testPlanDiagnosticsExposeConflictsAndUnplacedWithoutSavingPreview() throws {
        try withRuntime { runtime in
            let unplacedID = UUID()
            let payload: [String: Any] = ["reason": "Vérifier un conflit", "agenda": [
                "timeZoneID": "Europe/Paris", "startMinute": 480, "endMinute": 660,
                "slots": [
                    ["id": unplacedID.uuidString, "title": "À replacer", "startMinute": 600, "endMinute": 630, "state": "unscheduled"],
                    ["id": UUID().uuidString, "title": "Repas", "startMinute": 720, "endMinute": 780, "fixed": true],
                    ["id": UUID().uuidString, "title": "Rendez-vous", "startMinute": 750, "endMinute": 810, "fixed": true],
                ],
            ]]
            let input = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let saved = try FocusJSON.decode(FocusPlan.self, from: runtime.handle(request("patch", revision: 0, id: "diagnostic", body: input)))
            let shown = try runtime.handle(GoalongFocusCLI.parse(command: "plan", arguments: ["show"]))
            let diagnostics = try XCTUnwrap(try object(shown)["agendaDiagnostics"] as? [String: Any])
            XCTAssertFalse((diagnostics["conflicts"] as? [String] ?? []).isEmpty)
            XCTAssertEqual(diagnostics["unplaced"] as? [String], [unplacedID.uuidString])
            let afterRead = try FocusJSON.decode(FocusPlan.self, from: shown)
            XCTAssertEqual(afterRead.effectiveRevision, saved.effectiveRevision)
            XCTAssertEqual(afterRead.agenda, saved.agenda)
            XCTAssertEqual(runtime.controller?.plan.effectiveRevision, saved.effectiveRevision)
        }
    }

    @MainActor func testReflowAndUndoReturnTheSameAnnotatedPlanContract() throws {
        try withRuntime { runtime in
            let slotID = UUID(), lunchID = UUID()
            let payload: [String: Any] = ["reason": "Prévoir une journée", "reflow": false, "agenda": [
                "timeZoneID": "Europe/Paris", "startMinute": 480, "endMinute": 1320, "bufferMinutes": 10,
                "slots": [
                    ["id": slotID.uuidString, "title": "Documenter", "startMinute": 540, "endMinute": 570],
                    ["id": lunchID.uuidString, "title": "Déjeuner", "startMinute": 720, "endMinute": 780, "fixed": true],
                ],
            ]]
            let input = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let created = try FocusJSON.decode(FocusPlan.self, from: runtime.handle(request("patch", revision: 0, id: "seed", body: input)))
            let adjustedData = try runtime.handle(request("reflow", revision: created.effectiveRevision, id: "delay"))
            let adjusted = try FocusJSON.decode(FocusPlan.self, from: adjustedData)
            let slot = try XCTUnwrap(adjusted.agenda?.slots.first { $0.id == slotID })
            XCTAssertGreaterThanOrEqual(slot.startMinute, 660)
            XCTAssertEqual(slot.durationMinutes, 30)
            XCTAssertEqual(adjusted.agenda?.slots.first { $0.id == lunchID }?.startMinute, 720)
            XCTAssertNotNil(try object(adjustedData)["measures"])
            let restored = try FocusJSON.decode(FocusPlan.self, from: runtime.handle(request("undo", revision: adjusted.effectiveRevision, id: "undo-delay")))
            XCTAssertGreaterThan(restored.effectiveRevision, adjusted.effectiveRevision)
            XCTAssertEqual(restored.agenda?.slots.first { $0.id == slotID }?.startMinute, 540)
            XCTAssertEqual(restored.agenda?.slots.first { $0.id == lunchID }?.startMinute, 720)
            XCTAssertEqual(restored.receipts?.filter { $0.id == "undo-delay" }.count, 1)
        }
    }
}
#endif
