#if os(macOS)
import AppKit
import BraiseCore
import Foundation
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// Page « Blocages » (docs/spec-blocages-20261110.md): one page draws what the block engine, the red screen and the
/// sessions hold, and the old destinations open it. It stores nothing new: a block that runs and a range that is
/// armed are read from the same files as before. Rendered off screen; fake gamma only.
@MainActor final class BlocagesPageTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!; return calendar
    }
    /// Wednesday 2026-11-04, 10:00 in Paris.
    private let wednesday10h = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/goalong-blocages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func blocking(_ document: BlockingDocument = BlockingDocument(), store: BlockingStore? = nil) -> BlockingController {
        let now = wednesday10h
        let c = BlockingController(document: document, clock: { now }, store: store, calendar: paris,
                                   continuous: { now.timeIntervalSince1970 }, runningApps: { [] })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func braise(_ root: URL) throws -> BraiseController {
        let now = wednesday10h
        let store = BraiseStore(directory: root.appendingPathComponent("Braise", isDirectory: true), legacySettings: root.appendingPathComponent("missing"))
        let c = try BraiseController(store: store, gamma: BraiseTestGamma(), runsTimers: false, clock: { now }, calendar: paris,
                                     continuous: { now.timeIntervalSince1970 }, boot: { "boot-1" }, hasPassword: { false },
                                     verifyPassword: { _ in .wrong(remaining: 3) })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func list(_ name: String, _ ranges: [BlockProgramRange]) -> BlockList {
        BlockList(name: name, sites: [BlockSiteRule(pattern: "\(name.lowercased()).example")], program: BlockProgram(ranges: ranges))
    }
    /// Monday to Friday, 9:00–12:00: running at the test's hour.
    private func morning(_ lock: BlockLock? = nil) -> BlockProgramRange {
        BlockProgramRange(weekdays: Set(1...5), startMinute: 9 * 60, endMinute: 12 * 60, lock: lock)
    }
    /// Every day, 21:00–23:00: armed at the test's hour.
    private func evening(_ lock: BlockLock? = nil) -> BlockProgramRange {
        BlockProgramRange(weekdays: Set(1...7), startMinute: 21 * 60, endMinute: 23 * 60, lock: lock)
    }
    private func session(_ list: BlockList, _ lock: BlockLock) -> BlockSession {
        BlockSession(listIDs: [list.id], start: wednesday10h.addingTimeInterval(-600), end: wednesday10h.addingTimeInterval(3_600), lock: lock)
    }
    private func page(_ blocking: BlockingController?, _ braise: BraiseController? = nil) -> Set<String> {
        visibleText(BlocagesPageContent(blocking: blocking, braise: braise, focus: nil, now: wednesday10h), width: 900, height: 1_600)
    }
    /// Every regular file under `root`, with its bytes.
    private func files(_ root: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            found[String(url.path.dropFirst(root.path.count))] = try? Data(contentsOf: url)
        }
        return found
    }

    // MARK: One page

    func testTheOldDestinationsOpenTheOnePage() {
        let parts: [(DashboardSection, BlocagesTarget)] = [
            (.blocking, .top), (.distractions, .lists), (.concentration, .sessions), (.braise, .redScreen),
        ]
        for (section, target) in parts {
            XCTAssertEqual(section.keptPage, "blocages", section.rawValue)
            XCTAssertEqual(section.sidebarParent, .blocking, section.rawValue)
            XCTAssertEqual(BlocagesTarget(section), target, section.rawValue)
            for modules in [Set<GoalongModule>(), Set(GoalongModule.allCases)] {
                let sidebar = DashboardSection.sidebarSections(modules: modules, showing: section)
                XCTAssertEqual(sidebar.filter { $0.keptPage == "blocages" }, [.blocking], "\(section.rawValue): one entry, whatever is on")
            }
        }
        // A destination saved by an older version (a link, the CLI, the last page shown) still names the page.
        for name in ["concentration", "distractions", "blocking", "braise"] {
            XCTAssertEqual(DashboardSection(rawValue: name)?.keptPage, "blocages", name)
        }
        XCTAssertEqual(BlocagesTarget(.overview), .top)
        XCTAssertEqual(DashboardSection.primarySections, [.overview, .work, .history, .blocking, .settings])
        XCTAssertEqual(DashboardSection.blocking.title, "Blocages"); XCTAssertEqual(DashboardSection.blocking.simpleTitle, "Blocages")
        XCTAssertTrue(DashboardSection.preheated.contains(.blocking), "built at rest: the first click draws nothing new")
    }

    func testANewMemberSeesEveryPartAndHowToStart() {
        let text = page(blocking())
        for expected in ["blocages-page", "Blocages", "Règles", "blocages-new-rule", "blocages-no-rule", "blocages-rule-jev",
                         "Listes", "Séances", "Protection", "blocking-state-idle"] {
            XCTAssertTrue(text.contains(expected), "missing: \(expected)")
        }
        XCTAssertTrue(text.contains { $0.hasPrefix("blocking-suggestion-") }, "no list yet: the page offers starting points")
        XCTAssertFalse(text.contains("blocages-idle"), "Blocage is on: its own state line says that nothing is blocked")
        // The two shared runtimes are not started here: each part says how to turn it on, or that it failed.
        XCTAssertTrue(text.contains("module-enable-concentration") || text.contains("blocages-sessions-failed"))
        XCTAssertTrue(text.contains("braise-enable") || text.contains("blocages-red-failed"))
    }

    func testEveryModuleOffStillSaysWhatThePageHolds() {
        let text = page(nil)
        for expected in ["blocages-page", "blocages-idle", "blocages-new-rule", "blocages-rule-jev", "module-enable-blocking",
                         "Règles", "Listes", "Séances", "Protection"] {
            XCTAssertTrue(text.contains(expected), "missing: \(expected)")
        }
        XCTAssertFalse(text.contains("blocking-state-active")); XCTAssertFalse(text.contains("blocking-state-idle"))
    }

    func testEachRuleIsOneRowThatSaysWhenWhatAndWhatStopsIt() throws {
        let controller = blocking(BlockingDocument(lists: [list("Jeux", [morning(.locked)]), list("Vidéo", [evening()])]))
        // The page reads the rules on the Mac's calendar: the expected rows do too.
        let rules = BlockRules.current(blocking: controller, braise: nil, now: wednesday10h)
        XCTAssertEqual(rules.count, 2)
        let text = page(controller)
        for (index, rule) in rules.enumerated() {
            XCTAssertTrue(text.contains("blocages-rule-\(index)"), "no row \(index)")
            XCTAssertTrue(text.contains(rule.spokenLabel(now: wednesday10h)), "row \(index): \(rule.spokenLabel(now: wednesday10h))")
        }
        XCTAssertFalse(text.contains("blocages-no-rule")); XCTAssertTrue(text.contains("blocages-rule-jev"))
        XCTAssertTrue(text.contains("blocking-state-active"), "the morning rule runs: the page shows its block first")
    }

    // MARK: Protection

    /// The stop rule of a block is drawn as on the old page: a free block has « Arrêter », a locked one has nothing.
    func testALockedBlockHasNoStopButtonOnThePage() {
        let games = list("Jeux", [])
        func shown(_ lock: BlockLock) -> Set<String> {
            var document = BlockingDocument(lists: [games]); document.sessions = [session(games, lock)]
            return page(blocking(document))
        }
        let free = shown(.free), locked = shown(.locked)
        XCTAssertTrue(free.contains("blocking-state-active")); XCTAssertTrue(free.contains("blocking-stop"))
        XCTAssertTrue(locked.contains("blocking-state-active")); XCTAssertFalse(locked.contains("blocking-stop"))
        XCTAssertFalse(locked.contains("blocages-idle")); XCTAssertFalse(locked.contains("blocking-state-idle"))
    }

    func testTheEditorSaysThatARunningLockedRuleIsProtected() throws {
        let games = list("Jeux", [morning(.locked)]), video = list("Vidéo", [evening(.locked)])
        let controller = blocking(BlockingDocument(lists: [games, video]))
        let rules = BlockRules.current(blocking: controller, braise: nil, now: wednesday10h, calendar: paris)
        let running = try XCTUnwrap(rules.first { $0.lists.map(\.id) == [games.id] })
        let armed = try XCTUnwrap(rules.first { $0.lists.map(\.id) == [video.id] })
        guard case .running = running.state else { return XCTFail("the morning rule runs at 10:00: \(running.state)") }
        func editor(_ rule: BlockRule) -> Set<String> {
            visibleText(BlockRuleEditor(subject: .rule(rule), blocking: controller, braise: nil, focus: nil, now: wednesday10h, onClose: {}),
                        width: BlockRuleEditor.width, height: 900)
        }
        let first = editor(running), second = editor(armed)
        for id in ["block-rule-editor", "block-rule-protected", "block-rule-save", "block-rule-delete"] {
            XCTAssertTrue(first.contains(id), "missing: \(id)")
        }
        XCTAssertFalse(second.contains("block-rule-protected"), "a rule that waits is not protected yet")
        XCTAssertTrue(second.contains("block-rule-save"))
        // The note is true: the engine refuses to remove the running rule, and the lists stay as they were.
        let before = controller.lists
        let writes = BlockRulePlan.writes(nil, replacing: running, lists: controller.lists, red: nil)
        XCTAssertNotNil(BlockRulePlan.apply(writes, blocking: controller, braise: nil))
        XCTAssertEqual(controller.lists, before)
    }

    /// A rule of two engines is written whole or not at all: a red screen that refuses leaves the lists as they were.
    func testARefusedRedScreenWritesNoList() throws {
        let games = list("Jeux", [])
        let controller = blocking(BlockingDocument(lists: [games])), red = try braise(root())
        red.shutdown()
        var draft = BlockRuleDraft(); draft.listIDs = [games.id]; draft.red = true
        let before = controller.lists, ranges = red.ranges
        let writes = BlockRulePlan.writes(draft, replacing: nil, lists: controller.lists, red: red.ranges)
        XCTAssertFalse(writes.lists.isEmpty); XCTAssertTrue(writes.touchesRed)
        XCTAssertNotNil(BlockRulePlan.apply(writes, blocking: controller, braise: red))
        XCTAssertEqual(controller.lists, before); XCTAssertEqual(red.ranges, ranges)
    }

    // MARK: Migration: nothing moves

    /// The files of the release before the page are read as they are. A locked block that runs, a locked rule that
    /// runs and a locked range armed for tonight are still there after a restart; the page shows them without a way
    /// to stop them, and drawing it writes no file.
    func testWhatRanAndWhatWasArmedSurviveARestartAndThePageWritesNothing() throws {
        let root = try root(), now = wednesday10h
        let games = list("Jeux", [morning(.locked)]), video = list("Vidéo", [evening(.locked)])
        var document = BlockingDocument(lists: [games, video]); document.sessions = [session(video, .locked)]
        let store = BlockingStore(directory: root.appendingPathComponent("Blocking", isDirectory: true))
        try store.save(document)
        // The red screen follows a locked range for tonight, written by its engine as the old page did.
        let old = try braise(root)
        for range in old.ranges.program.ranges { try old.deleteRange(range.id) }
        let night = evening(.locked)
        try old.saveRange(night, intensity: 0.8); old.setFollows(true)

        // Restart: new controllers on the same files.
        let lists = blocking(store: store), screen = try braise(root)
        XCTAssertNil(lists.error)
        XCTAssertEqual(lists.lists.map(\.id), [games.id, video.id])
        XCTAssertEqual(lists.activeBlocks.filter { $0.lock == .locked && $0.end > now }.count, 2, "the block and the morning rule still run")
        XCTAssertEqual(try XCTUnwrap(lists.severeUntil).timeIntervalSince(now), 7_200, accuracy: 1)
        // Still protected: a stop is refused.
        for block in lists.activeBlocks { lists.stop(block.id) }
        XCTAssertEqual(lists.activeBlocks.filter { $0.lock == .locked && $0.end > now }.count, 2)
        XCTAssertTrue(screen.ranges.follows)
        XCTAssertEqual(screen.ranges.program.ranges.map(\.id), [night.id]); XCTAssertEqual(screen.ranges.program.ranges.first?.lock, .locked)

        let saved = files(root)
        XCTAssertFalse(saved.isEmpty)
        let rules = BlockRules.current(blocking: lists, braise: screen, now: now, calendar: paris)
        XCTAssertEqual(rules.count, 2)
        let first = try XCTUnwrap(rules.first { $0.key.start == 9 * 60 }), second = try XCTUnwrap(rules.first { $0.key.start == 21 * 60 })
        guard case .running = first.state else { return XCTFail("the morning rule runs: \(first.state)") }
        guard case .next = second.state else { return XCTFail("the evening rule waits for 21:00: \(second.state)") }
        XCTAssertEqual(first.lock, .locked); XCTAssertEqual(second.lock, .locked)
        XCTAssertEqual(second.lists.map(\.id), [video.id]); XCTAssertNotNil(second.red, "the range of the red screen is part of the evening rule")

        let text = page(lists, screen)
        XCTAssertTrue(text.contains("blocking-state-active")); XCTAssertFalse(text.contains("blocking-stop"))
        XCTAssertTrue(text.contains("blocages-rule-0")); XCTAssertTrue(text.contains("blocages-rule-1"))
        _ = visibleText(BlockRuleEditor(subject: .rule(first), blocking: lists, braise: screen, focus: nil, now: now, onClose: {}),
                        width: BlockRuleEditor.width, height: 900)
        XCTAssertEqual(files(root), saved, "drawing the page or the editor wrote a file")
    }

    // MARK: Rendering

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
