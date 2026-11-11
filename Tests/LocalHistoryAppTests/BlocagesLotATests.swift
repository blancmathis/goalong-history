#if os(macOS)
import AppKit
import BraiseCore
import Foundation
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// Fake gamma that keeps the last state asked: no test touches the real gamma table.
/// Screen driver that notes whether the crash file already existed when the first screen moved (point 8, :196).
final class CrashOrderDriver: DisplayBrightnessDriving, @unchecked Sendable {
    private let inner = FakeBrightness(level: 0.8)
    private let crashFileExists: () -> Bool
    private(set) var crashFileExistedAtFirstSet: Bool?
    init(crashFileExists: @escaping () -> Bool) { self.crashFileExists = crashFileExists }
    var isAvailable: Bool { inner.isAvailable }
    func displays() -> [BrightnessDisplay] { inner.displays() }
    func brightness(of display: UInt32) -> Double? { inner.brightness(of: display) }
    func setBrightness(_ value: Double, of display: UInt32) -> Bool {
        if crashFileExistedAtFirstSet == nil { crashFileExistedAtFirstSet = crashFileExists() }
        return inner.setBrightness(value, of: display)
    }
}

final class LotAGamma: BraiseGammaDriving {
    var onError: ((String) -> Void)?
    var onDisplays: ((Int) -> Void)?
    private(set) var active = false
    private(set) var intensity = 0.0
    private(set) var brightness = 1.0
    func set(active: Bool, intensity: Double, brightness: Double, animated: Bool) {
        self.active = active; self.intensity = intensity; self.brightness = brightness
    }
    func restore() { active = false }
    func checkAfterSystemChange() {}
}

/// T-050 lot A (spec points 1 to 16): one window « Quand / Quoi / Arrêt », the live preview of the sliders, the
/// sections removed and the page cleaned. Rendered off screen; fake gamma, fake brightness, no real guard or signal.
@MainActor final class BlocagesLotATests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 10:00 in Paris.
    private let wednesday10h = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!
    private final class Clocks {
        var now: Date; var up: TimeInterval = 1_000
        init(_ now: Date) { self.now = now }
        func pass(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds); up += seconds }
    }

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-lot-a-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func store(_ root: URL) -> BraiseStore {
        BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
    }
    private func blocking(_ document: BlockingDocument = BlockingDocument()) -> BlockingController {
        let now = wednesday10h
        let c = BlockingController(document: document, clock: { now }, store: nil, calendar: paris,
                                   continuous: { now.timeIntervalSince1970 }, runningApps: { [] })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func braise(_ clocks: Clocks, store: BraiseStore, gamma: BraiseGammaDriving = LotAGamma(),
                        screens: FakeBrightness = FakeBrightness(), clearing: Bool = true) throws -> BraiseController {
        let c = try BraiseController(store: store, gamma: gamma, runsTimers: false, clock: { clocks.now }, calendar: paris,
                                     continuous: { clocks.up }, boot: { "boot-1" }, brightness: screens, hasPassword: { false },
                                     verifyPassword: { _ in .wrong(remaining: 3) })
        if clearing { for range in c.ranges.program.ranges { try c.deleteRange(range.id) } }
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func focus() throws -> ConcentrationController {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-lot-a-focus-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let s = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try s.saveSettings(settings)
        let now = wednesday10h
        return try ConcentrationController(store: s, clock: { now })
    }
    private func list(_ name: String, _ ranges: [BlockProgramRange] = []) -> BlockList {
        BlockList(name: name, sites: [BlockSiteRule(pattern: "\(name.lowercased()).example")], program: BlockProgram(ranges: ranges))
    }
    private func editor(_ subject: BlockRuleEditor.Subject, blocking: BlockingController? = nil, braise: BraiseController? = nil,
                        focus: ConcentrationController? = nil, trigger: BlockRuleEditor.Trigger? = nil,
                        session: FocusComposerDraft? = nil, draft: BlockRuleDraft? = nil) -> BlockRuleEditor {
        BlockRuleEditor(subject: subject, blocking: blocking, braise: braise, focus: focus, now: wednesday10h, trigger: trigger, draft: draft,
                        maxHeight: 2_000, sessionDraft: session ?? FocusComposerDraft(), onClose: {})
    }
    private func pomodoro() -> FocusComposerDraft { var d = FocusComposerDraft(); d.kind = .pomodoro; return d }

    // MARK: A1 — the window

    /// Point 1: one skeleton for a new rule, a rule, Jev and a session: three titled boxes and one footer.
    func testPoint1EveryKindHasTheSameThreeBoxesAndOneFooter() throws {
        let games = list("Jeux", [BlockProgramRange(weekdays: Set(1...5), startMinute: 21 * 60, endMinute: 23 * 60)])
        let lists = blocking(BlockingDocument(lists: [games]))
        let rule = try XCTUnwrap(BlockRules.current(blocking: lists, braise: nil, now: wednesday10h, calendar: paris).first)
        for subject in [BlockRuleEditor.Subject.new, .rule(rule), .jev, .session(FocusComposerDraft())] {
            let text = visibleText(editor(subject, blocking: lists))
            for id in ["block-rule-box-when", "block-rule-box-what", "block-rule-box-stop", "block-rule-when", "block-rule-stop"] {
                XCTAssertTrue(text.contains(id), "\(subject.id): missing \(id)")
            }
            XCTAssertTrue(text.contains("Quand") && text.contains("Quoi") && text.contains("Arrêt"), subject.id)
        }
    }

    /// Point 2: four choices; on an existing rule the selector stays, fixed on its choice.
    func testPoint2FourTriggersAndTheTriggerIsFixedOnceTheRuleExists() throws {
        XCTAssertEqual(BlockRuleEditor.Trigger.allCases.map(\.title), ["Toujours", "Horaires", "Jev", "Séance"])
        let games = list("Jeux", [BlockProgramRange(weekdays: Set(1...5), startMinute: 21 * 60, endMinute: 23 * 60)])
        let lists = blocking(BlockingDocument(lists: [games]))
        let rule = try XCTUnwrap(BlockRules.current(blocking: lists, braise: nil, now: wednesday10h, calendar: paris).first)
        XCTAssertTrue(editor(.rule(rule), blocking: lists).triggerIsFixed)
        XCTAssertTrue(editor(.jev).triggerIsFixed)
        XCTAssertFalse(editor(.new).triggerIsFixed); XCTAssertFalse(editor(.session(FocusComposerDraft())).triggerIsFixed)
        XCTAssertTrue(visibleText(editor(.rule(rule), blocking: lists)).contains("block-rule-when"), "the selector stays shown")
    }

    /// Point 2, « Toujours »: every day, 0–24 h, written to the current engines and read back as « Toujours ».
    func testPoint2AlwaysWritesEveryDayAllDayAndComesBackAsAlways() throws {
        let games = list("Jeux"), lists = blocking(BlockingDocument(lists: [games]))
        var draft = editor(.new, blocking: lists, trigger: .always).ruleDraft
        XCTAssertEqual(draft.weekdays, Set(1...7)); XCTAssertEqual(draft.startMinute, 0); XCTAssertEqual(draft.endMinute, 1_440)
        draft.listIDs = [games.id]
        XCTAssertNil(draft.problem)
        let writes = BlockRulePlan.writes(draft, replacing: nil, lists: lists.lists, red: nil)
        XCTAssertNil(BlockRulePlan.apply(writes, blocking: lists, braise: nil))
        let rule = try XCTUnwrap(BlockRules.current(blocking: lists, braise: nil, now: wednesday10h, calendar: paris).first)
        XCTAssertTrue(rule.key.isAlways)
        let text = visibleText(editor(.rule(rule), blocking: lists))
        XCTAssertTrue(text.contains("block-rule-always")); XCTAssertTrue(text.contains(BlockRuleEditor.alwaysSentence))
    }

    /// Point 3: the three blocks stay in place; one the engine lacks for this « Quand » is greyed with its reason.
    func testPoint3BlocksTheEngineLacksAreGreyedWithTheirReason() throws {
        let clocks = Clocks(wednesday10h), red = try braise(clocks, store: store(root())), lists = blocking(), concentration = try focus()
        let jev = editor(.jev, blocking: lists, braise: red)
        XCTAssertEqual(jev.blockUnavailable, BlockRuleEditor.jevBlockReason)
        XCTAssertEqual(jev.screenUnavailable, BlockRuleEditor.jevBlockReason)
        let jevText = visibleText(jev)
        for id in ["block-rule-red", "block-rule-brightness", BlockRuleEditor.jevBlockReason] { XCTAssertTrue(jevText.contains(id), id) }
        let session = editor(.session(pomodoro()), blocking: lists, braise: red, focus: concentration, session: pomodoro())
        XCTAssertEqual(session.screenUnavailable, BlockRuleEditor.focusScreenReason)
        XCTAssertNil(session.blockUnavailable)
        XCTAssertTrue(visibleText(session).contains(BlockRuleEditor.focusScreenReason))
        XCTAssertNil(editor(.new, blocking: lists, braise: red).screenUnavailable, "a schedule rule has the red screen")
    }

    /// Point 4: the same four stop levels everywhere; a level the engine lacks is greyed with its reason.
    func testPoint4StopLevelsTheEngineLacksAreGreyed() throws {
        let lists = blocking(), concentration = try focus()
        let session = editor(.session(pomodoro()), blocking: lists, focus: concentration, session: pomodoro())
        XCTAssertTrue(session.usesFocus)
        XCTAssertEqual(session.lockUnavailable(.typing), BlockRuleEditor.focusLockReason)
        XCTAssertEqual(session.lockUnavailable(.password), BlockRuleEditor.focusLockReason)
        XCTAssertNil(session.lockUnavailable(.free))
        XCTAssertTrue(visibleText(session).contains(BlockRuleEditor.focusLockReason))
        let always = editor(.new, blocking: lists, trigger: .always)
        XCTAssertEqual(always.lockUnavailable(.locked), BlockRuleEditor.alwaysLockedReason)
        XCTAssertNil(always.lockUnavailable(.typing))
        let schedule = editor(.new, blocking: lists)
        for lock in BlockLock.ordered { XCTAssertNil(schedule.lockUnavailable(lock), "\(lock)") }
        XCTAssertEqual(editor(.jev).lockUnavailable(.locked), BlockRuleEditor.jevLockReason)
        XCTAssertEqual(BlockLock.ordered.count, 4)
    }

    /// Point 5: one footer — « Supprimer » only for a rule that exists, « Annuler », one main button.
    func testPoint5OneFooter() throws {
        let games = list("Jeux", [BlockProgramRange(weekdays: Set(1...5), startMinute: 21 * 60, endMinute: 23 * 60)])
        let lists = blocking(BlockingDocument(lists: [games]))
        let rule = try XCTUnwrap(BlockRules.current(blocking: lists, braise: nil, now: wednesday10h, calendar: paris).first)
        let new = visibleText(editor(.new, blocking: lists)), old = visibleText(editor(.rule(rule), blocking: lists))
        let session = visibleText(editor(.session(FocusComposerDraft()), blocking: lists))
        XCTAssertTrue(new.isSuperset(of: ["block-rule-cancel", "block-rule-save", "Enregistrer"])); XCTAssertFalse(new.contains("block-rule-delete"))
        XCTAssertTrue(old.isSuperset(of: ["block-rule-delete", "block-rule-cancel", "block-rule-save"]))
        XCTAssertTrue(session.isSuperset(of: ["block-rule-cancel", "block-rule-start-session", "Démarrer"]))
        XCTAssertFalse(session.contains("block-rule-save"))
    }

    /// Point 6: the titles.
    func testPoint6Titles() throws {
        let games = list("Jeux", [BlockProgramRange(weekdays: Set(1...5), startMinute: 21 * 60, endMinute: 23 * 60)])
        let lists = blocking(BlockingDocument(lists: [games]))
        let rule = try XCTUnwrap(BlockRules.current(blocking: lists, braise: nil, now: wednesday10h, calendar: paris).first)
        XCTAssertEqual(editor(.new).title, "Nouvelle règle")
        XCTAssertEqual(editor(.new, trigger: .session).title, "Nouvelle séance")
        XCTAssertEqual(editor(.session(FocusComposerDraft())).title, "Nouvelle séance")
        XCTAssertEqual(editor(.rule(rule), blocking: lists).title, "Modifier la règle")
        XCTAssertEqual(editor(.jev).title, "Modifier la règle")
        XCTAssertEqual(BlockRuleEditor.defaultIntent, "Séance")
    }

    // MARK: A2 — live preview

    /// Point 7: the screen shows the slider while it moves, and the real state comes back about 2 s after it is let go.
    func testPoint7PreviewHoldsTwoSecondsAfterRelease() throws {
        let clocks = Clocks(wednesday10h), gamma = LotAGamma(), c = try braise(clocks, store: store(root()), gamma: gamma)
        XCTAssertFalse(gamma.active)
        c.showPreview(red: 0.9, holding: true)
        XCTAssertTrue(gamma.active); XCTAssertEqual(gamma.intensity, 0.9, accuracy: 0.0001)
        c.showPreview(red: 0.7, holding: false)
        XCTAssertEqual(gamma.intensity, 0.7, accuracy: 0.0001)
        clocks.pass(1); c.evaluate(); XCTAssertTrue(gamma.active, "still shown 1 s after release")
        clocks.pass(BraiseController.previewHold); c.evaluate()
        XCTAssertFalse(gamma.active, "the real state is back")
        XCTAssertEqual(BraiseController.previewHold, 2)
    }

    /// Point 8: closing, « Annuler », another « Quand », a stop of the app and a crash all bring the real state back.
    func testPoint8RealStateComesBackOnCloseShutdownAndCrash() throws {
        let root = try root(), clocks = Clocks(wednesday10h), gamma = LotAGamma(), screens = FakeBrightness(level: 0.8)
        let c = try braise(clocks, store: store(root), gamma: gamma, screens: screens)
        c.showPreview(red: 0.6, brightness: 0.3, holding: true); c.enforceBrightnessNow()
        XCTAssertTrue(gamma.active); XCTAssertEqual(try XCTUnwrap(screens.brightness(of: 1)), 0.3, accuracy: 0.0001)
        c.endPreview()
        XCTAssertFalse(gamma.active); XCTAssertEqual(try XCTUnwrap(screens.brightness(of: 1)), 0.8, accuracy: 0.0001)
        XCTAssertTrue(store(root).loadPreviewBrightness().isEmpty)
        c.showPreview(red: 0.6, holding: true); c.shutdown()
        XCTAssertFalse(gamma.active, "the app's stop restores the screen")
        // A crash in the middle of a brightness preview: the next start puts the screens back.
        store(root).savePreviewBrightness([1: 0.8]); screens.userSets(0.3)
        _ = try braise(clocks, store: store(root), screens: screens, clearing: false)
        XCTAssertEqual(try XCTUnwrap(screens.brightness(of: 1)), 0.8, accuracy: 0.0001)
        XCTAssertTrue(store(root).loadPreviewBrightness().isEmpty)
    }

    /// Point 9: the preview never weakens what runs, and says so.
    func testPoint9PreviewNeverWeakensTheRealEffect() throws {
        let clocks = Clocks(wednesday10h), gamma = LotAGamma(), screens = FakeBrightness(level: 0.8)
        let c = try braise(clocks, store: store(root()), gamma: gamma, screens: screens)
        c.setManual(true); c.setIntensity(0.8)
        c.showPreview(red: 0.3, holding: true)
        XCTAssertEqual(gamma.intensity, 0.8, accuracy: 0.0001, "never less red than what runs")
        XCTAssertNotNil(c.previewNotice)
        c.endPreview(); XCTAssertNil(c.previewNotice)
        XCTAssertEqual(try c.setBrightnessLock(BrightnessLockState(level: 0.3)), .applied)
        c.enforceBrightnessNow()
        c.showPreview(brightness: 0.9, holding: true); c.enforceBrightnessNow()
        XCTAssertEqual(try XCTUnwrap(screens.brightness(of: 1)), 0.3, accuracy: 0.0001, "never brighter than a held level")
        XCTAssertNotNil(c.previewNotice)
    }

    // MARK: A3 — sections removed

    /// Point 10: no manual fold on the page; the filter's brightness sits in the menu bar next to the intensity.
    func testPoint10ManualRedLeavesThePageAndItsBrightnessIsInTheMenuBar() throws {
        let clocks = Clocks(wednesday10h), c = try braise(clocks, store: store(root()))
        let text = visibleText(BlocagesPageContent(blocking: blocking(), braise: c, focus: nil, now: wednesday10h), width: 900, height: 1_600)
        XCTAssertFalse(text.contains { $0.contains("réglage manuel") })
        let name = "lot-a-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let runtime = BraiseRuntime(registersShortcut: false, defaults: defaults, factory: { try self.braise(clocks, store: self.store(self.root())) })
        defer { runtime.shutdown() }
        runtime.ensureController()
        runtime.setRedScreenFilterBrightness(0.05)
        XCTAssertEqual(try XCTUnwrap(runtime.controller).preferences.brightness, RedScreenState.filterBrightnessRange.lowerBound, accuracy: 0.0001)
        XCTAssertEqual(runtime.redScreen.filterBrightness, RedScreenState.filterBrightnessRange.lowerBound, accuracy: 0.0001)
    }

    /// Point 11: « Suivre mes horaires » is gone; ranges that were not followed come back paused, once.
    func testPoint11UnfollowedRangesComeBackPausedAndTheSwitchIsGone() throws {
        let root = try root(), clocks = Clocks(wednesday10h)
        let first = try braise(clocks, store: store(root))
        let now = BlockProgramRange(weekdays: Set(1...7), startMinute: 9 * 60, endMinute: 12 * 60)
        try first.saveRange(now, intensity: 0.8)
        var old = first.ranges; old.follows = false
        first.shutdown(); try store(root).saveRanges(old)
        let gamma = LotAGamma(), next = try braise(clocks, store: store(root), gamma: gamma, clearing: false)
        XCTAssertTrue(next.ranges.follows); XCTAssertTrue(next.ranges.disabled.contains(now.id))
        XCTAssertFalse(gamma.active, "no red starts by surprise")
        XCTAssertFalse(RedScreenMenu(control: GalleryRedScreen(RedScreenState(on: false, intensity: 0.5)), onOpenSettings: {})
            .items.contains { $0.title.contains("Suivre") })
    }

    /// Point 12: a free brightness lock becomes a rule « Toujours » at its level; a protected one stays, never cut.
    func testPoint12BrightnessLockBecomesAnAlwaysRuleUnlessProtected() throws {
        for protected in [false, true] {
            let root = try root(), clocks = Clocks(wednesday10h)
            let first = try braise(clocks, store: store(root))
            first.shutdown()
            var old = first.ranges
            old.brightnessLock = protected
                ? BrightnessLockState(level: 0.4, lock: .locked, end: wednesday10h.addingTimeInterval(3_600))
                : BrightnessLockState(level: 0.4)
            try store(root).saveRanges(old)
            let next = try braise(clocks, store: store(root), clearing: false)
            if protected {
                XCTAssertEqual(next.ranges.brightnessLock?.level, 0.4, "a protected lock stays, with its stop in « En cours »")
                XCTAssertFalse(next.ranges.program.ranges.contains { BlockRule.Key($0).isAlways })
            } else {
                XCTAssertNil(next.ranges.brightnessLock)
                let always = try XCTUnwrap(next.ranges.program.ranges.first { BlockRule.Key($0).isAlways })
                XCTAssertEqual(try XCTUnwrap(next.ranges.brightness(of: always.id)), 0.4, accuracy: 0.0001)
                XCTAssertEqual(next.ranges.intensity(of: always.id), 0)
            }
        }
    }

    /// Point 13: the orphan links land on the list of rules.
    func testPoint13RedScreenLinksLandOnTheRules() {
        XCTAssertEqual(BlocagesPageContent.anchor(.redScreen), .top)
        let menu = RedScreenMenu(control: GalleryRedScreen(RedScreenState(on: false, intensity: 0.5)), onOpenSettings: {})
        XCTAssertEqual(menu.settingsItem.title, "Règles de l’écran rouge…")
        XCTAssertFalse(BlocagesRedOff.text.contains("ici"))
        XCTAssertTrue(BlocagesRedOff.text.contains("Nouvelle règle"))
    }

    // MARK: A4 — page cleaning

    /// Points 14 and 15: « Protection » keeps what stops a bypass; the empty list and the Jev row agree.
    func testPoints14And15ProtectionAndRuleTexts() throws {
        let clocks = Clocks(wednesday10h), c = try braise(clocks, store: store(root()))
        let text = visibleText(BlocagesPageContent(blocking: blocking(), braise: c, focus: nil, now: wednesday10h), width: 900, height: 1_600)
        XCTAssertTrue(text.contains(BlocagesPageContent.protectionSubtitle))
        XCTAssertTrue(text.contains { $0.contains(BlocagesPageContent.redSafetyTitle) })
        XCTAssertFalse(BlocagesPageContent.protectionSubtitle.contains("à la main"))
        XCTAssertTrue(BlocagesPageContent.noRuleText.hasPrefix("Aucune autre règle"))
        XCTAssertNotEqual(BlocagesJevRow.kind, BlockLock.free.title)
        XCTAssertFalse(BlocagesJevRow.kind.contains("Arrêt"))
    }

    /// Point 16: the section of the session settings no longer reads as the app's « Réglages ».
    func testPoint16FocusSettingsTitle() {
        XCTAssertEqual(FocusSettingsSection.title, "Réglages des séances")
    }

    // MARK: Corrections after the review (lot A, round 2)

    private func allDay(_ lock: BlockLock) -> BlockRuleDraft {
        var d = BlockRuleDraft(); d.weekdays = Set(1...7); d.startMinute = 0; d.endMinute = 1_440; d.lock = lock; return d
    }

    /// « Horaires », 7 days, 00:00 → 24:00, « Verrouillé »: refused with its reason; the other levels are not.
    func testHoursEveryDayAllDayLockedIsRefusedWithItsReason() throws {
        let locked = editor(.new, trigger: .schedule, draft: allDay(.locked))
        XCTAssertTrue(locked.hoursAlwaysLocked)
        XCTAssertEqual(locked.ruleProblem, BlockRuleEditor.hoursAlwaysLockedReason)
        XCTAssertTrue(visibleText(locked).contains { $0.contains("règle « Toujours »") }, "the reason is on screen")
        for level in [BlockLock.free, .typing, .password] {
            let other = editor(.new, trigger: .schedule, draft: allDay(level))
            XCTAssertFalse(other.hoursAlwaysLocked, "\(level)")
            XCTAssertNotEqual(other.ruleProblem, BlockRuleEditor.hoursAlwaysLockedReason)
        }
        var weekdays = allDay(.locked); weekdays.weekdays = Set(1...5)
        XCTAssertFalse(editor(.new, trigger: .schedule, draft: weekdays).hoursAlwaysLocked)
    }

    /// An existing rule never falls back to « Libre » in silence: the real level shows and saving keeps it.
    func testExistingRuleKeepsItsRealStopLevel() throws {
        for level in [BlockLock.typing, .locked] {
            let root = try root(), clocks = Clocks(wednesday10h)
            let first = try braise(clocks, store: store(root))
            first.shutdown()
            var file = first.ranges
            let range = BlockProgramRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440, lock: level)
            file.program.ranges = [range]; file.disabled = []; file.fullDayPaused = true; file.follows = true
            file.intensities[range.id] = 0.5
            try store(root).saveRanges(file)
            let next = try braise(clocks, store: store(root), clearing: false)
            let rule = try XCTUnwrap(BlockRules.current(blocking: blocking(), braise: next, now: wednesday10h, calendar: paris)
                .first { $0.key.lock == level })
            for trigger in [BlockRuleEditor.Trigger.always, .schedule] {
                let open = editor(.rule(rule), blocking: blocking(), braise: next, trigger: trigger)
                XCTAssertEqual(open.stopLevel, level, "\(level) via \(trigger)")
                XCTAssertFalse(open.hoursAlwaysLocked, "an existing rule is not refused")
            }
            if level == .locked { XCTAssertNil(editor(.rule(rule), blocking: blocking(), braise: next).lockUnavailable(.locked)) }
        }
    }

    /// Minor 1: a red range 00:00 → 24:00 already saved comes back paused, once; re-enabled it stays on.
    func testSavedFullDayRedRangeIsPausedOnceAndStaysOnAfterReEnabling() throws {
        let root = try root(), clocks = Clocks(wednesday10h)
        let first = try braise(clocks, store: store(root))
        first.shutdown()
        var old = first.ranges
        let full = BlockProgramRange(weekdays: Set(1...7), startMinute: 0, endMinute: 1_440)
        old.program.ranges = [full]; old.intensities[full.id] = 0.7; old.disabled = []; old.follows = true; old.fullDayPaused = nil
        try store(root).saveRanges(old)
        let gamma = LotAGamma(), second = try braise(clocks, store: store(root), gamma: gamma, clearing: false)
        XCTAssertTrue(second.ranges.disabled.contains(full.id), "paused at the first start")
        XCTAssertFalse(gamma.active)
        try second.saveRange(full, intensity: 0.7, enabled: true)
        XCTAssertTrue(gamma.active, "re-enabled by the user")
        second.shutdown()
        let gamma3 = LotAGamma(), third = try braise(clocks, store: store(root), gamma: gamma3, clearing: false)
        XCTAssertFalse(third.ranges.disabled.contains(full.id), "once: the second start leaves it active")
        XCTAssertTrue(gamma3.active)
        third.shutdown()
    }

    /// :262 — a protected lock stays at the first launch and becomes a rule « Toujours » at a later launch, once free.
    func testProtectedBrightnessLockBecomesARuleAtALaterLaunchOnceFree() throws {
        let root = try root(), clocks = Clocks(wednesday10h)
        let first = try braise(clocks, store: store(root)); first.shutdown()
        var file = first.ranges
        file.brightnessLock = BrightnessLockState(level: 0.4, lock: .locked, end: wednesday10h.addingTimeInterval(3_600))
        try store(root).saveRanges(file)
        let second = try braise(clocks, store: store(root), clearing: false)
        XCTAssertEqual(second.ranges.brightnessLock?.level, 0.4)
        XCTAssertFalse(second.ranges.program.ranges.contains { BlockRule.Key($0).isAlways })
        second.shutdown()
        // The protection has ended: what is left on file is the level alone.
        var freed = second.ranges
        freed.brightnessLock?.lock = nil; freed.brightnessLock?.end = nil; freed.brightnessLock?.deadline = nil; freed.brightnessLock?.boot = nil
        try store(root).saveRanges(freed)
        clocks.pass(7_200)
        let third = try braise(clocks, store: store(root), clearing: false)
        XCTAssertNil(third.ranges.brightnessLock)
        let always = try XCTUnwrap(third.ranges.program.ranges.first { BlockRule.Key($0).isAlways })
        XCTAssertEqual(try XCTUnwrap(third.ranges.brightness(of: always.id)), 0.4, accuracy: 0.0001)
        third.shutdown()
    }

    /// :196 — the crash file is written before the first screen moves.
    func testPreviewWritesTheCrashFileBeforeTheScreenMoves() throws {
        let root = try root(), clocks = Clocks(wednesday10h), st = store(root)
        let driver = CrashOrderDriver(crashFileExists: { !st.loadPreviewBrightness().isEmpty })
        let c = try BraiseController(store: st, gamma: LotAGamma(), runsTimers: false, clock: { clocks.now }, calendar: paris,
                                     continuous: { clocks.up }, boot: { "boot-1" }, brightness: driver, hasPassword: { false },
                                     verifyPassword: { _ in .wrong(remaining: 3) })
        addTeardownBlock { @MainActor in c.shutdown() }
        c.showPreview(brightness: 0.3, holding: true); c.enforceBrightnessNow()
        XCTAssertEqual(driver.crashFileExistedAtFirstSet, true)
    }

    /// Point 6 of the brief: a rule with the screen level only (red at 0) never dims through the colour filter.
    func testBrightnessOnlyRuleDoesNotDimThroughTheFilter() throws {
        let clocks = Clocks(wednesday10h), gamma = LotAGamma(), dir = try root(), st = store(dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Braise"), withIntermediateDirectories: true)
        var prefs = Preferences(); prefs.brightness = 0.4; try st.save(prefs)
        let c = try braise(clocks, store: st, gamma: gamma)
        XCTAssertEqual(c.preferences.brightness, 0.4, accuracy: 0.0001)
        let range = BlockProgramRange(weekdays: Set(1...7), startMinute: 9 * 60, endMinute: 12 * 60)
        try c.saveRange(range, intensity: 0, brightness: .some(0.5))
        c.evaluate()
        XCTAssertFalse(gamma.active, "no filter for a level-only rule")
    }

    // MARK: Rendering

    private func visibleText(_ editor: BlockRuleEditor) -> Set<String> {
        visibleText(editor, width: BlockRuleEditor.width, height: 2_000)
    }

    /// Renders off screen (no window, no focus) and returns every label, title, value, help and identifier of the AX tree.
    private func visibleText(_ root: some View, width: CGFloat, height: CGFloat) -> Set<String> {
        let view = NSHostingView(rootView: root.frame(width: width).environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        var found = Set<String>(), pending: [Any] = [view], seen = Set<ObjectIdentifier>()
        while let value = pending.popLast(), seen.count < 20_000 {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"] {
                if let text = read(object, name) as? String, !text.isEmpty { found.insert(text) }
            }
            pending.append(contentsOf: read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return found
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
}
#endif
