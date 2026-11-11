#if os(macOS)
import Carbon
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-050 lot B2a: the prepared sessions, « Relancer la dernière séance » and its shortcut. Pure: suite defaults, fake
/// controllers, no window, no real guard or signal.
@MainActor final class PreparedSessionTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 10:00 in Paris.
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!
    private let social = BlockList(name: "Réseaux sociaux", sites: [BlockSiteRule(pattern: "social.example")])

    private func defaults() -> UserDefaults {
        let name = "prepared-sessions-" + UUID().uuidString, value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }; return value
    }
    private func blocking() -> BlockingController {
        var document = BlockingDocument(); document.lists = [social]
        let now = self.now
        let c = BlockingController(document: document, clock: { now }, store: nil, calendar: paris,
                                   continuous: { now.timeIntervalSince1970 }, runningApps: { [] })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func focus() throws -> ConcentrationController {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-prepared-focus-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let s = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        let now = self.now
        return try ConcentrationController(store: s, clock: { now })
    }
    private func session(_ name: String = "Matin", lock: BlockLock = .free) -> PreparedSession {
        var value = PreparedSession(id: UUID(), name: name)
        value.listIDs = [social.id]; value.span = .minutes(60); value.lock = lock
        return value
    }

    // MARK: Point 1 — « Enregistrer pour plus tard » keeps the window in a new storage

    func testPoint1StoreSavesReplacesDeletesAndReadsBack() {
        let d = defaults(), store = PreparedSessionStore(defaults: d)
        var first = session("Matin")
        store.save(first); store.save(session("Soir"))
        first.name = "Matin calme"; store.save(first)
        XCTAssertEqual(store.document.sessions.map(\.name), ["Matin calme", "Soir"], "same id = replaced in place")
        store.delete(first.id)
        store.recordLast(first); store.setShortcut(.controlOptionCommandS)
        let again = PreparedSessionStore(defaults: d)
        XCTAssertEqual(again.document, store.document, "written once, read back")
        XCTAssertEqual(again.document.sessions.map(\.name), ["Soir"])
        XCTAssertEqual(again.document.last?.id, first.id)
        XCTAssertEqual(again.document.shortcut, .controlOptionCommandS)
    }

    func testPoint1UnreadableStoreSaysSoAndStartsEmpty() {
        let d = defaults(); d.set(Data("pas du json".utf8), forKey: PreparedSessionStore.storageKey)
        let store = PreparedSessionStore(defaults: d)
        XCTAssertEqual(store.error, PreparedSessionStore.unreadableText)
        XCTAssertTrue(store.document.sessions.isEmpty)
    }

    /// The window becomes a session and back with the same « Quoi », « Pendant », « Rythme » and stop (point 3).
    func testPoint3WindowRoundTripsThroughAPreparedSession() {
        var value = session("Rédaction", lock: .password)
        value.span = .until(minute: 11 * 60 + 30)
        value.red = true; value.brightness = 0.4
        let editor = BlockRuleEditor(subject: .prepared(value), blocking: blocking(), braise: nil, focus: nil, now: now,
                                     maxHeight: 2_000, sessionDraft: FocusComposerDraft(), onClose: {})
        let back = editor.preparedSession(id: value.id, name: value.name)
        XCTAssertEqual(back.listIDs, [social.id])
        XCTAssertEqual(back.lock, .password)
        XCTAssertEqual(back.span, .until(minute: 11 * 60 + 30))
        XCTAssertFalse(back.red, "no red screen controller: the screen part is not kept")
        XCTAssertEqual(back.composer.blockListIds, [social.id])
    }

    // MARK: Point 2 — the row's summary

    func testPoint2SummarySaysLengthWhatAndStop() {
        var value = session()
        value.red = true
        XCTAssertEqual(value.summary(listNames: [social.id: "Réseaux sociaux"]),
                       BlockingFormat.duration(minutes: 60) + " · Réseaux sociaux, écran rouge · " + BlockLock.free.title)
        value.wholeMac = true; value.listIDs = []; value.red = false; value.span = .until(minute: 18 * 60)
        XCTAssertEqual(value.summary(listNames: [:]), "Jusqu’à 18:00 · tout le Mac · " + BlockLock.locked.title)
    }

    // MARK: Point 3 — the stop levels the engine allows

    func testPoint3FocusSessionHidesTheLevelsItsEngineRefuses() throws {
        var value = session(); value.pomodoro = true; value.cycles = 4
        let editor = BlockRuleEditor(subject: .prepared(value), blocking: blocking(), braise: nil, focus: try focus(), now: now,
                                     maxHeight: 2_000, sessionDraft: FocusComposerDraft(), onClose: {})
        XCTAssertEqual(editor.stopChoices, [.free, .locked])
        let rule = BlockRuleEditor(subject: .new, blocking: blocking(), braise: nil, focus: nil, now: now, trigger: .schedule,
                                   maxHeight: 2_000, sessionDraft: FocusComposerDraft(), onClose: {})
        XCTAssertEqual(rule.stopChoices, BlockLock.ordered, "a rule keeps every level, greyed with its reason")
    }

    // MARK: Point 4 / P2 — « Lancer » in one click, or the window when a stop asks a confirmation

    func testP2LaunchPathStartsAtOnceOrOpensTheWindow() {
        let lists: Set<UUID> = [social.id]
        func path(_ s: PreparedSession, focus: Bool = false, braise: Bool = false) -> PreparedSessionLauncher.Path {
            PreparedSessionLauncher.path(s, hasFocus: focus, hasBlocking: true, hasBraise: braise, lists: lists)
        }
        XCTAssertEqual(path(session()), .block)
        XCTAssertEqual(path(session(lock: .password)), .editor, "the password alert stays in the window")
        XCTAssertEqual(path(session(lock: .locked)), .editor)
        var pomodoro = session(); pomodoro.pomodoro = true
        XCTAssertEqual(path(pomodoro, focus: true), .focus)
        XCTAssertEqual(path(pomodoro), .editor, "Pomodoro without Concentration")
        var mac = session(); mac.wholeMac = true
        XCTAssertEqual(path(mac), .editor, "the whole Mac asks its consent")
        var screen = session(); screen.red = true
        XCTAssertEqual(path(screen), .editor, "no red screen controller")
        XCTAssertEqual(path(screen, braise: true), .block)
        var watch = session(); watch.listIDs = []; watch.surveillance = JevInterventionSettings()
        XCTAssertEqual(path(watch), .watch)
    }

    /// Point 1 of the brief: the last session started is remembered once, for « Relancer ».
    func testRelaunchRemembersTheLastSessionOnce() {
        let d = defaults(), store = PreparedSessionStore(defaults: d), value = session()
        store.recordLast(value)
        d.removeObject(forKey: PreparedSessionStore.storageKey)
        store.recordLast(value)
        XCTAssertNil(d.object(forKey: PreparedSessionStore.storageKey), "the same session is not written again")
        XCTAssertEqual(store.document.last, value)
    }

    func testRelaunchShortcutKeysAreControlOptionCommand() {
        XCTAssertNil(RelaunchShortcut.none.key)
        XCTAssertEqual(RelaunchShortcut.controlOptionCommandS.key?.code, 0x01)
        XCTAssertEqual(RelaunchShortcut.controlOptionCommandS.key?.modifiers, 0x0100 | 0x0800 | 0x1000)
        XCTAssertEqual(RelaunchShortcut.controlOptionCommandS.title, "⌃⌥⌘S")
        XCTAssertFalse(RelaunchShortcut.allCases.contains { $0.key?.code == 0x0F }, "⌃⌥⌘R stays Braise's escape")
    }

    /// F1: the Carbon handler answers only its own id; Braise's ⌃⌥⌘R goes on untouched. A stored ⌃⌥⌘R reads as « Aucun ».
    func testF1RelaunchHandlerIgnoresOtherHotKeysAndOldChoiceBecomesNone() async throws {
        func press(_ id: EventHotKeyID) throws -> OSStatus {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event), noErr)
            let value = try XCTUnwrap(event); defer { ReleaseEvent(value) }
            var hotKey = id
            XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                             MemoryLayout<EventHotKeyID>.size, &hotKey), noErr)
            return RelaunchHotKey.handle(nil, value, nil)
        }
        let saved = RelaunchHotKey.shared.action; defer { RelaunchHotKey.shared.action = saved }
        var calls = 0
        RelaunchHotKey.shared.action = { calls += 1 }
        XCTAssertEqual(try press(EventHotKeyID(signature: OSType(0x42525332), id: 1)), OSStatus(eventNotHandledErr), "Braise")
        XCTAssertEqual(try press(EventHotKeyID(signature: RelaunchHotKey.id.signature, id: 2)), OSStatus(eventNotHandledErr))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try press(RelaunchHotKey.id), noErr)
        for _ in 0..<10 where calls == 0 { await Task.yield() }
        XCTAssertEqual(calls, 1)

        let d = defaults(), kept = session()
        d.set(try JSONEncoder().encode(PreparedSessionStore.Document(sessions: [kept], shortcut: .controlOptionCommandS)),
              forKey: PreparedSessionStore.storageKey)
        let raw = try XCTUnwrap(String(data: try XCTUnwrap(d.data(forKey: PreparedSessionStore.storageKey)), encoding: .utf8))
        d.set(Data(raw.replacingOccurrences(of: "controlOptionCommandS", with: "controlOptionCommandR").utf8),
              forKey: PreparedSessionStore.storageKey)
        let store = PreparedSessionStore(defaults: d)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.document.shortcut, RelaunchShortcut.none)
        XCTAssertEqual(store.document.sessions, [kept], "the sessions survive the removed choice")
    }

    /// F2: « Surveillance » alone with a protected stop opens the window: nothing starts, nothing is remembered.
    func testF2ProtectedWatchOnlySessionNeverStartsInOneClick() throws {
        let d = defaults(), store = PreparedSessionStore(defaults: d)
        for lock in [BlockLock.password, .locked] {
            var watch = session(lock: lock); watch.listIDs = []; watch.surveillance = JevInterventionSettings()
            XCTAssertEqual(PreparedSessionLauncher.path(watch, hasFocus: false, hasBlocking: true, hasBraise: false, lists: [social.id]),
                           .editor, "\(lock)")
            var focused = session(lock: lock); focused.intent = "Écrire"
            XCTAssertEqual(PreparedSessionLauncher.path(focused, hasFocus: true, hasBlocking: true, hasBraise: false, lists: [social.id]),
                           .editor, "\(lock) with Concentration")
            XCTAssertEqual(PreparedSessionLauncher.launch(watch, blocking: nil, braise: nil, focus: nil, store: store), .needsEditor)
        }
        XCTAssertNil(store.document.last, "a session that did not start is not « la dernière séance »")
        XCTAssertNil(d.object(forKey: PreparedSessionStore.storageKey))
    }

    /// F3: unreadable data is copied before the next write replaces it; the copy is kept once.
    func testF3UnreadableStoreKeepsACopyBeforeTheNextWrite() {
        let d = defaults(), broken = Data("pas du json".utf8)
        d.set(broken, forKey: PreparedSessionStore.storageKey)
        let store = PreparedSessionStore(defaults: d)
        store.save(session())
        XCTAssertNil(store.error)
        XCTAssertEqual(d.data(forKey: PreparedSessionStore.unreadableCopyKey), broken)
        d.set(Data("autre".utf8), forKey: PreparedSessionStore.storageKey)
        _ = PreparedSessionStore(defaults: d)
        XCTAssertEqual(d.data(forKey: PreparedSessionStore.unreadableCopyKey), broken, "the first copy is not replaced")
    }

    // MARK: Point 5 — an existing rule shows only its « Quand »

    func testPoint5ExistingRuleHidesTheOtherWhenChoices() {
        XCTAssertEqual(BlockRuleEditor.whenOptions(fixed: true, current: .schedule), [.schedule])
        XCTAssertEqual(BlockRuleEditor.whenOptions(fixed: false, current: .schedule), BlockRuleEditor.Trigger.allCases)
    }

    // MARK: Extra point 2 — the rule window closes on an outside click, and asks first once changed

    func testRuleWindowAsksBeforeAnOutsideClickOnlyOnceChanged() {
        let start = BlockRuleEditor.Snapshot(trigger: .session, draft: BlockRuleDraft(), session: FocusComposerDraft(), later: false,
                                             span: .minutes(60), wholeMac: false, freezeMode: .shield, kept: [], name: "")
        var changed = start; changed.span = .minutes(90)
        XCTAssertFalse(BlockRuleEditor.isDirty(initial: nil, now: start), "not yet shown")
        XCTAssertFalse(BlockRuleEditor.isDirty(initial: start, now: start))
        XCTAssertTrue(BlockRuleEditor.isDirty(initial: start, now: changed))
    }

    func testUntilDateIsTheNextTimeThisMinuteComes() {
        let later = PreparedSession.untilDate(minute: 11 * 60, now: now, calendar: paris)
        XCTAssertEqual(later.timeIntervalSince(now), 3_600)
        let tomorrow = PreparedSession.untilDate(minute: 9 * 60, now: now, calendar: paris)
        XCTAssertEqual(tomorrow.timeIntervalSince(now), 23 * 3_600)
    }
}
#endif
