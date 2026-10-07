#if os(macOS)
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class ConcentrationDistractionTests: XCTestCase {
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    private let start = Date(timeIntervalSince1970: 1_791_201_600)
    private func store() -> FocusStore {
        let root = URL(fileURLWithPath: "/private/tmp/focus-distractions-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return FocusStore(directory: root)
    }
    private func window(_ target: JevDistractionTarget?, at start: Date) -> JevWindow {
        .init(start: start, end: start.addingTimeInterval(15), samples: [
            .init(date: start, resource: target?.name ?? "Unknown", title: "", action: "scroll",
                  surface: "other", isActivity: true, distractionTarget: target)
        ])
    }
    @MainActor private func count(_ target: JevDistractionTarget, windows: Int, controller c: ConcentrationController,
                                 time: Clock) throws {
        for _ in 0..<windows {
            let w = window(target, at: time.now); time.now = w.end
            try c.recordJevDistraction(window: w, verdict: .procrastination, sessionID: c.currentSession!.id)
        }
    }
    func testOnlyFreshUnambiguousConfirmedWindowsCountOnce() {
        let target = JevDistractionTarget.site(host: "youtube.com")!, other = JevDistractionTarget.site(host: "x.com")!
        let w = window(target, at: start); var record = FocusDistractionRecord()
        XCTAssertFalse(record.record(w, verdict: .productive, sessionStart: start, now: w.end))
        XCTAssertFalse(record.record(w, verdict: .unknown, sessionStart: start, now: w.end))
        XCTAssertFalse(record.record(w, verdict: .procrastination, sessionStart: start.addingTimeInterval(1), now: w.end))
        XCTAssertFalse(record.record(w, verdict: .procrastination, sessionStart: start, now: w.end.addingTimeInterval(15)))
        XCTAssertFalse(record.record(w, verdict: .procrastination, sessionStart: start, now: start))
        XCTAssertTrue(record.record(w, verdict: .procrastination, sessionStart: start, now: w.end))
        XCTAssertFalse(record.record(w, verdict: .procrastination, sessionStart: start, now: w.end))
        let next = window(other, at: w.end)
        let mixed = JevWindow(start: next.start, end: next.end, samples: next.samples + [
            .init(date: next.start, resource: "youtube.com", title: "", action: "scroll", surface: "other",
                  isActivity: true, distractionTarget: target)
        ])
        XCTAssertFalse(record.record(mixed, verdict: .procrastination, sessionStart: start, now: mixed.end))
        XCTAssertFalse(record.record(window(nil, at: w.end), verdict: .procrastination, sessionStart: start, now: next.end))
        XCTAssertEqual(record.counts.first?.confirmedSeconds, 15)
        let invalid = JevWindow(start: w.end, end: w.end.addingTimeInterval(30), samples: next.samples)
        XCTAssertFalse(record.record(invalid, verdict: .procrastination, sessionStart: start, now: invalid.end))
    }
    @MainActor func testThresholdOrderingFrozenThreeAndPerSessionPersistence() throws {
        let s = store(); let time = Clock(start)
        let c = try ConcentrationController(store: s, clock: { time.now })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil))
        let id = c.currentSession!.id
        for (host, windows) in [("youtube.com", 8), ("x.com", 10), ("reddit.com", 9), ("twitch.tv", 8), ("netflix.com", 7)] {
            try count(.site(host: host)!, windows: windows, controller: c, time: time)
        }
        XCTAssertThrowsError(try c.distractionSuggestions(sessionID: id))
        try c.stopSession()
        let cards = try c.distractionSuggestions(sessionID: id)
        XCTAssertEqual(cards.map(\.target.value), ["x.com", "reddit.com", "twitch.tv"])
        XCTAssertEqual(cards.map(\.confirmedSeconds), [150, 135, 120])
        try c.ignoreDistractionSuggestion(sessionID: id, targetID: cards[0].id)
        XCTAssertEqual(try c.distractionSuggestions(sessionID: id).count, 2, "Do not replace it with a fourth candidate")
        let restored = try ConcentrationController(store: s, clock: { time.now })
        XCTAssertEqual(try restored.distractionSuggestions(sessionID: id), try c.distractionSuggestions(sessionID: id))
        let file = s.directory.appendingPathComponent("sessions/" + BlockingController.dayKey(start) + ".json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    @MainActor func testExistingListsAreExcludedRegardlessOfModePathOrAction() throws {
        let time = Clock(start)
        let app = JevDistractionTarget.app(bundleIdentifier: "com.example.Game", name: "Game")!
        let lists = [BlockList(name: "Allowed", mode: .allowOnly, sites: [.init(pattern: "m.youtube.com/shorts")]),
                     BlockList(name: "Slow", apps: [.init(bundleIdentifier: app.value, name: app.name)], action: .slowDown)]
        let b = BlockingController(document: .init(lists: lists), clock: { time.now })
        let c = try ConcentrationController(store: store(), clock: { time.now }, blocking: { b })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil)); let id = c.currentSession!.id
        for target in [JevDistractionTarget.site(host: "youtube.com")!, app] { try count(target, windows: 8, controller: c, time: time) }
        try c.stopSession()
        XCTAssertTrue(try c.distractionSuggestions(sessionID: id).isEmpty)
        XCTAssertEqual(b.lists, lists, "Recording never writes a list")
    }
    @MainActor func testAcceptAddsThroughLockedBlockingControllerAndPersistsAcceptance() throws {
        let time = Clock(start)
        let list = BlockList(name: "Distractions", program: .init(lockedUntil: start.addingTimeInterval(3600)), action: .slowDown)
        let b = BlockingController(document: .init(lists: [list]), clock: { time.now }, continuous: { time.now.timeIntervalSince1970 })
        let s = store(), c = try ConcentrationController(store: s, clock: { time.now }, blocking: { b })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil)); let id = c.currentSession!.id
        let target = JevDistractionTarget.site(host: "m.youtube.com")!
        try count(target, windows: 8, controller: c, time: time); try c.stopSession()
        XCTAssertTrue(b.lists[0].sites.isEmpty)
        try c.acceptDistractionSuggestion(sessionID: id, targetID: target.id, listID: list.id)
        XCTAssertEqual(b.lists[0].sites.map(\.pattern), ["youtube.com"])
        XCTAssertEqual(b.lists[0].effectiveAction, .slowDown)
        XCTAssertEqual(b.lists[0].program, list.program)
        let count = try XCTUnwrap(s.sessions(BlockingController.dayKey(start)).first?.distractions?.counts.first)
        XCTAssertEqual(count.state, .accepted); XCTAssertEqual(count.acceptedListID, list.id)
        XCTAssertTrue(try c.distractionSuggestions(sessionID: id).isEmpty)
        XCTAssertThrowsError(try c.acceptDistractionSuggestion(sessionID: id, targetID: target.id, listID: list.id))
    }
    @MainActor func testAcceptanceRefusesAllowOnlyMissingListsDisabledAndBrokenStorage() throws {
        let time = Clock(start); let allowed = BlockList(name: "Allowed", mode: .allowOnly)
        let b = BlockingController(document: .init(lists: [allowed]), clock: { time.now })
        var provider: BlockingController? = b
        let c = try ConcentrationController(store: store(), clock: { time.now }, blocking: { provider })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil)); let id = c.currentSession!.id
        let target = JevDistractionTarget.app(bundleIdentifier: "com.example.Game", name: "Game")!
        try count(target, windows: 8, controller: c, time: time); try c.stopSession()
        XCTAssertThrowsError(try c.acceptDistractionSuggestion(sessionID: id, targetID: target.id, listID: allowed.id)) {
            XCTAssertEqual($0 as? BlockingListAdditionFailure, .notBlockList)
        }
        XCTAssertThrowsError(try c.acceptDistractionSuggestion(sessionID: id, targetID: target.id, listID: UUID())) {
            XCTAssertEqual($0 as? BlockingListAdditionFailure, .notFound)
        }
        provider = nil
        XCTAssertThrowsError(try c.acceptDistractionSuggestion(sessionID: id, targetID: target.id, listID: allowed.id)) {
            XCTAssertEqual($0 as? FocusFailure, .moduleDisabled)
        }
        let root = store().directory
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
        provider = BlockingController(store: BlockingStore(directory: root))
        XCTAssertThrowsError(try c.acceptDistractionSuggestion(sessionID: id, targetID: target.id, listID: allowed.id)) {
            XCTAssertEqual($0 as? BlockingListAdditionFailure, .storageFailed)
        }
        XCTAssertEqual(try c.distractionSuggestions(sessionID: id).count, 1)
        XCTAssertEqual(b.lists, [allowed])
    }
    @MainActor func testIgnoreAlwaysSurvivesRelaunchAndAppliesToFutureSessions() throws {
        let time = Clock(start); let s = store(), target = JevDistractionTarget.site(host: "m.youtube.com")!
        let c = try ConcentrationController(store: s, clock: { time.now })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil)); let first = c.currentSession!.id
        try count(target, windows: 8, controller: c, time: time); try c.stopSession()
        try c.ignoreDistractionSuggestion(sessionID: first, targetID: target.id, always: true)
        let restored = try ConcentrationController(store: s, clock: { time.now })
        XCTAssertTrue(try restored.distractionSuggestions(sessionID: first).isEmpty)
        try restored.startSession(intent: "Lire", mode: FocusMode(minutes: nil)); let second = restored.currentSession!.id
        try count(target, windows: 8, controller: restored, time: time); try restored.stopSession()
        XCTAssertTrue(try restored.distractionSuggestions(sessionID: second).isEmpty)
        XCTAssertEqual(restored.settings.ignoredDistractionTargets, [target])
    }
    @MainActor func testSessionIdentityRejectsLateResultsAndRestoresRunningCounts() throws {
        let time = Clock(start); let s = store(), target = JevDistractionTarget.site(host: "youtube.com")!
        let c = try ConcentrationController(store: s, clock: { time.now })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil)); let first = c.currentSession!.id
        try count(target, windows: 4, controller: c, time: time)
        let restored = try ConcentrationController(store: s, clock: { time.now })
        XCTAssertEqual(restored.currentSession?.distractions?.counts.first?.confirmedSeconds, 60)
        try restored.stopSession(); try restored.startSession(intent: "Lire", mode: FocusMode(minutes: nil))
        let late = window(target, at: time.now); time.now = late.end
        try restored.recordJevDistraction(window: late, verdict: .procrastination, sessionID: first)
        XCTAssertNil(restored.currentSession?.distractions)
        try count(target, windows: 8, controller: restored, time: time)
        let second = restored.currentSession!.id; try restored.stopSession()
        XCTAssertEqual(try restored.distractionSuggestions(sessionID: second).first?.confirmedSeconds, 120)
        XCTAssertTrue(try restored.distractionSuggestions(sessionID: first).isEmpty)
    }
    @MainActor func testAutomaticEndModuleDisableAndPomodoroBreakSessionGate() throws {
        let time = Clock(start); let target = JevDistractionTarget.site(host: "youtube.com")!
        let c = try ConcentrationController(store: store(), clock: { time.now })
        var mode = FocusMode(); mode.kind = .pomodoro; mode.workMinutes = 5
        try c.startSession(intent: "Écrire", mode: mode); let id = c.currentSession!.id
        try count(target, windows: 8, controller: c, time: time)
        time.now = start.addingTimeInterval(300); c.refresh()
        XCTAssertEqual(c.phase?.kind, .shortBreak); XCTAssertEqual(c.jevSessionID, id)
        c.shutdown(); XCTAssertNil(c.jevSessionID)
        XCTAssertEqual(try c.distractionSuggestions(sessionID: id).count, 1)
        try c.startSession(intent: "Lire", mode: FocusMode(minutes: 5)); let second = c.currentSession!.id
        time.now = time.now.addingTimeInterval(300)
        XCTAssertNil(c.jevSessionID, "The gate closes even before the phase timer runs")
        c.refresh(); XCTAssertNil(c.currentSession)
        XCTAssertTrue(try c.distractionSuggestions(sessionID: second).isEmpty)
    }
    @MainActor func testLegacySessionsSettingsAndUnknownDistractionSchema() throws {
        let s = store(); let c = try ConcentrationController(store: s, clock: { self.start })
        try c.startSession(intent: "Écrire", mode: FocusMode(minutes: nil))
        var value = c.currentSession!; XCTAssertNil(value.distractions)
        let encoded = try FocusJSON.encode(value)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("distractions"))
        XCTAssertEqual(try FocusJSON.decode(FocusSession.self, from: encoded), value)
        XCTAssertNil(try s.settings().ignoredDistractionTargets)
        value.distractions = FocusDistractionRecord(schema: 2)
        XCTAssertThrowsError(try s.saveSessions([value], day: BlockingController.dayKey(start)))
    }
    func testPrivateAndExcludedIngressCannotProduceCountingTargets() {
        let ctx = ContextSnapshot(app: .init(name: "Browser", bundleIdentifier: "test.browser", processIdentifier: 42),
            window: nil, focusedElement: nil,
            url: .init(value: "https://m.youtube.com/watch?secret=value", host: "m.youtube.com", redactionApplied: true),
            suppressionReason: nil)
        let privateIngress = JevIngress(notificationCenter: NotificationCenter(), contextIsPermitted: { _ in true })
        privateIngress.configure(enabled: true, now: start); privateIngress.setPrivateWindow(true)
        privateIngress.observeContext(ctx, foregroundEvidence: .mediaPlayback, now: start)
        XCTAssertNil(privateIngress.take(start: start, end: start.addingTimeInterval(15)))
        let excluded = JevIngress(notificationCenter: NotificationCenter(), contextIsPermitted: { _ in false })
        excluded.configure(enabled: true, now: start); excluded.observeContext(ctx, foregroundEvidence: .mediaPlayback, now: start)
        XCTAssertNil(excluded.take(start: start, end: start.addingTimeInterval(15)))
        XCTAssertEqual(JevIngress.foregroundSample(ctx, evidence: .mediaPlayback, at: start).distractionTarget?.value, "youtube.com")
    }
    func testNoLocalSuggestionProjectionOutsideAnActiveSession() throws {
        let ctx = ContextSnapshot(app: .init(name: "Browser", bundleIdentifier: "test.browser", processIdentifier: 42),
            window: nil, focusedElement: nil, url: .init(value: "https://youtube.com/", host: "youtube.com", redactionApplied: true),
            suppressionReason: nil)
        let ingress = JevIngress(notificationCenter: NotificationCenter(), contextIsPermitted: { _ in true })
        ingress.configure(enabled: true, now: start)
        ingress.observeContext(ctx, foregroundEvidence: .mediaPlayback, now: start)
        XCTAssertNil(try XCTUnwrap(ingress.take(start: start, end: start.addingTimeInterval(15))).samples.first?.distractionTarget)
        ingress.configure(enabled: true, collectDistractions: true, now: start)
        ingress.observeContext(ctx, foregroundEvidence: .mediaPlayback, now: start)
        XCTAssertEqual(try XCTUnwrap(ingress.take(start: start, end: start.addingTimeInterval(15))).samples.first?.distractionTarget?.value, "youtube.com")
    }
}
#endif
