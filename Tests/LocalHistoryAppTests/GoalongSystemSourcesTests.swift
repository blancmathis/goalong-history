#if os(macOS)
import XCTest
import EventKit
import AppleScreenTime
import Foundation
import LocalHistoryCore
@testable import LocalHistoryApp

final class GoalongSystemSourcesTests: XCTestCase {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-system-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testNoteRoundTripBoundAndDayDeletion() throws {
        let root = try root(), day = Date()
        XCTAssertNil(try GoalongDayNoteStore.get(root: root, day: day))
        try GoalongDayNoteStore.set(" Travail hors du Mac ", root: root, day: day)
        XCTAssertEqual(try GoalongDayNoteStore.get(root: root, day: day), "Travail hors du Mac")
        XCTAssertThrowsError(try GoalongDayNoteStore.set(String(repeating: "x", count: 281), root: root, day: day))
        let file = root.appendingPathComponent("notes/\(GoalongSystemSourceFiles.dayKey(day)).json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        _ = try DerivedHistoryCleaner(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("mirror")).prepareDeletion(days: [day]).execute()
        XCTAssertNil(try GoalongDayNoteStore.get(root: root, day: day))
    }
    func testSourceStoresRejectLinksWithoutReadingOrWritingTheirTargets() throws {
        let root = try root(), other = try self.root(), day = Date()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("notes"), withDestinationURL: other)
        XCTAssertThrowsError(try GoalongDayNoteStore.set("secret", root: root, day: day))
        XCTAssertThrowsError(try GoalongDayNoteStore.get(root: root, day: day))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
    }
    func testCallUnionCrossesMidnightWithoutDoubleCountingAndHonorsExclusions() throws {
        let root = try root(), day = Calendar.current.startOfDay(for: Date())
        for (app, shift) in [("a", 0.0), ("b", 30.0)] {
            try GoalongCallStore.save(.init(start: day.addingTimeInterval(-60 + shift), end: day.addingTimeInterval(60 + shift),
                                           bundleIdentifier: app, application: app, microphone: true, camera: false), root: root)
        }
        let lane = GoalongCallStore.load(root: root, day: day, enabled: true)
        XCTAssertEqual(lane.unionSeconds, 90)
        XCTAssertEqual(lane.secondsPerApplication["a"], 60)
        var privacy = GoalongPrivacyPolicy(); privacy.applications = ["b": "b"]
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: true, privacy: privacy).unionSeconds, 60)
        XCTAssertNil(GoalongCallPresenceMonitor.application(pid: -1, reportedBundle: " ").0)
        XCTAssertEqual(GoalongCallPresenceMonitor.application(pid: -1, reportedBundle: "com.example.Browser.helper.renderer").0, "com.example.Browser")
        for identifier in [nil, " "] as [String?] {
            let row = GoalongCallInterval(start: day.addingTimeInterval(200), end: day.addingTimeInterval(240),
                bundleIdentifier: identifier, application: "", microphone: true, camera: false)
            XCTAssertNil(row.bundleIdentifier)
            try GoalongCallStore.save(row, root: root)
        }
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: true, privacy: privacy).unionSeconds, 60)
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: false).status, .disabled)
        let key = GoalongSystemSourceFiles.dayKey(day)
        try GoalongSystemSourceFiles.write(Data("incomplete".utf8), root: root, folder: "calls", name: key + ".jsonl", maximumBytes: 100)
        if case .failed = GoalongCallStore.load(root: root, day: day, enabled: true).status {} else { XCTFail("Truncated data must fail") }
    }
    func testDeviceOverlapProratesAndNeverChangesForegroundTime() {
        let day = Calendar.current.startOfDay(for: Date())
        let events = [0.0, 60.0, 120.0].map { HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval($0), kind: .heartbeat,
            app: .init(name: "Editor", bundleIdentifier: "test.editor", processIdentifier: 1)) }
        let mac = GoalongLocalAnalytics.build(events: events, day: day, now: day.addingTimeInterval(600))
        let device = AppleScreenTimeDevice(id: "phone", name: nil, kind: .iPhone)
        let report = AppleScreenTimeDeviceReport(device: device, lastUpdatedAt: day.addingTimeInterval(600),
            segments: [.init(start: day, end: day.addingTimeInterval(600), totalScreenOnDuration: 300)])
        let lane = GoalongOtherDevicesSource.build(reports: [report], macDay: mac, scope: .allDevices, enabled: true)
        XCTAssertEqual(lane.devices.first?.screenOnSeconds, 300)
        XCTAssertEqual(lane.devices.first?.duringMacActivitySeconds, mac.activeSeconds / 2)
        XCTAssertEqual(lane.devices.first?.duringMacGapsSeconds, (600 - mac.activeSeconds) / 2)
        XCTAssertTrue(lane.devices.first?.estimated == true)
        XCTAssertTrue(GoalongOtherDevicesSource.build(reports: [report], macDay: mac, scope: .macOnly, enabled: true).devices.isEmpty)
    }
    func testAgendaUnionExcludesFreeAndAllDayAndDoesNotAddReminderDuration() {
        let day = Date()
        var lane = GoalongCalendarLane(status: .ready, calendarStatus: .ready, remindersStatus: .ready)
        let fixtures: [(EKEventAvailability, Bool, Double)] = [(.busy, false, 0.0), (.busy, false, 60.0), (.free, false, 180.0), (.busy, true, 300.0)]
        lane.events = fixtures.enumerated().map { i, row in
            GoalongCalendarEvent(id: "\(i)", start: day.addingTimeInterval(row.2), end: day.addingTimeInterval(row.2 + 120),
                allDay: row.1, availability: (row.0 as EKEventAvailability).rawValue, title: "Fixture", calendarName: "Fixture", attendeeCount: 1)
        }
        lane.completedReminders = [.init(completedAt: day, title: "Done")]
        XCTAssertEqual(lane.plannedBusySeconds, 180)
    }
    func testHealthUsesImportedCalendarDayAndIncludesOnlyNumbers() throws {
        let value: [String: Any] = ["version": 2, "source": "apple-health", "days": [["telemetry": ["timezone": "Europe/Paris"],
            "health": ["version": 1, "metrics": [["key": "sleepCoreSeconds", "value": 1200], ["key": "steps", "value": 500]],
                       "workouts": [["durationSeconds": 600]]]]]]
        let lane = try GoalongHealthSource.decode(JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(lane.sleepSeconds, 1200); XCTAssertEqual(lane.steps, 500)
        XCTAssertEqual(lane.workoutCount, 1); XCTAssertEqual(lane.workoutSeconds, 600)
        XCTAssertEqual(lane.status, .partial); XCTAssertTrue(lane.sleepLabel.contains("minuit"))
    }
    func testOldConfigGainsAsideRecognitionWithoutEnablingPrivateCapture() throws {
        var config = RecorderConfig.default
        config.browserBundleIdentifiers = ["custom.browser"]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "captureCallPresence")
        let restored = try JSONDecoder().decode(RecorderConfig.self, from: JSONSerialization.data(withJSONObject: object)).validated()
        XCTAssertTrue(restored.effectiveCaptureCallPresence)
        XCTAssertTrue(restored.browserBundleIdentifiers.contains("at.studio.AsideBrowser"))
        XCTAssertTrue(restored.browserBundleIdentifiers.contains("custom.browser"))
        XCTAssertTrue(restored.suppressesPrivateWindow(detected: true))
    }
    func testNewRecapSourcesDefaultOffAndNotesAreMaskedAndExcluded() throws {
        XCTAssertFalse(GoalongSystemRecapSelection().hasSources)
        var flags = GoalongSystemRecapSelection(); flags.dayNote = true
        let sources = GoalongSystemSourcesDay(calls: .init(status: .disabled), calendar: .disabled,
            otherDevices: .init(status: .disabled), health: .init(status: .disabled), note: "Private Project", noteStatus: .ready)
        var document: [String: Any] = [:]
        let count = try GoalongSystemRecapSections.append(sources, selection: flags, scope: .init(), privacy: .init(),
            text: { value, _ in value.replacingOccurrences(of: "Private", with: "Client") }, to: &document)
        XCTAssertEqual(count, 1)
        XCTAssertEqual((document["note_du_jour"] as? [String: Any])?["texte"] as? String, "Client Project")
        var policy = GoalongPrivacyPolicy(); policy.applications = ["excluded": "Excluded"]
        document = [:]
        XCTAssertEqual(try GoalongSystemRecapSections.append(sources, selection: flags, scope: .init(), privacy: policy,
            text: { value, _ in value }, to: &document), 0)
        XCTAssertNil((document["note_du_jour"] as? [String: Any])?["texte"])
    }
    func testHealthFutureArchiveIsUnsupportedAndSupplementalSelectionRequiresReview() throws {
        let root = try root(), day = Date(), key = GoalongSystemSourceFiles.dayKey(day)
        try GoalongSystemSourceFiles.write(Data("{\"version\":3}".utf8), root: root, folder: "health", name: key + ".json", maximumBytes: 1024)
        XCTAssertEqual(GoalongHealthSource.load(root: root, day: day).status, .unsupported)
        var selection = GoalongAnalysisSelection(); selection.version = 1
        var flags = GoalongSystemRecapSelection(); flags.dayNote = true; selection.systemSources = flags
        XCTAssertThrowsError(try selection.validate())
        selection.version = 2; selection.scope = .init()
        XCTAssertNoThrow(try selection.validate())
    }
    func testCalendarConsentStartsOffAndDisablingCallMonitorCreatesNoSourceData() throws {
        let root = try root()
        let store = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json"))
        XCTAssertFalse(store.isEnabled(.calendar))
        let monitor = GoalongCallPresenceMonitor(root: root)
        monitor.configure(enabled: false, config: .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
    }
}
#endif
