#if os(macOS)
import AppKit
import BraiseCore
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-057 mockups M2 for the owner: idea 2 « Séance de travail / Blocage ponctuel » and idea 8 « Recherche des réglages ».
/// Fixtures only (a temporary folder, a fixed clock): never the owner's data.
@MainActor final class SettingsSearchAndSessionChoiceTests: XCTestCase {
    private var paris: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private let wednesday10h = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!

    // MARK: Idea 8

    func testTheOldSearchMissesTheWordsOfAScreenAndTheCommands() {
        for query in ["conservation", "agenda", "suspendre", "signaler"] {
            XCTAssertTrue(SettingsPane.matches(query).isEmpty, "\(query) found a section before: the premise of the mockup changed")
        }
    }

    func testTheNewSearchFindsAWordOfAScreenAndACommand() {
        XCTAssertEqual(SettingsSearchIndex.search("conservation").first?.id, "storage-retention")
        XCTAssertEqual(SettingsSearchIndex.search("agenda").first?.id, "perm-calendar")
        XCTAssertEqual(SettingsSearchIndex.search("suspendre").first?.id, "cmd-pause")
        XCTAssertEqual(SettingsSearchIndex.search("signaler un problème").first?.id, "cmd-report")
        XCTAssertEqual(SettingsSearchIndex.search("ECRAN allumé").first?.id, "rec-idle", "case and accents do not matter, every word must match")
        XCTAssertTrue(SettingsSearchIndex.search("zzzz").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.search("   ").isEmpty)
    }

    func testEveryEntryAnswersToItsOwnTitle() {
        for entry in SettingsSearchIndex.entries {
            XCTAssertTrue(SettingsSearchIndex.search(entry.title).contains(entry), entry.id)
        }
        XCTAssertEqual(Set(SettingsSearchIndex.entries.map(\.id)).count, SettingsSearchIndex.entries.count)
    }

    // MARK: Idea 2

    private func focus() throws -> ConcentrationController {
        let root = URL(fileURLWithPath: "/private/tmp/goalong-m2-focus-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = FocusStore(directory: root)
        var settings = FocusSettings(); settings.morningPrompt = false; settings.eveningPrompt = false; try store.saveSettings(settings)
        let now = wednesday10h
        return try ConcentrationController(store: store, clock: { now })
    }
    private func lists() -> [BlockList] {
        [BlockList(name: "Réseaux sociaux", sites: [BlockSiteRule(pattern: "x.com"), BlockSiteRule(pattern: "reddit.com")]),
         BlockList(name: "Jeux", sites: [BlockSiteRule(pattern: "twitch.tv")]),
         BlockList(name: "Vidéos", sites: [BlockSiteRule(pattern: "youtube.com")])]
    }
    private func blocking(_ lists: [BlockList]) -> BlockingController {
        let now = wednesday10h
        let c = BlockingController(document: BlockingDocument(lists: lists), clock: { now }, store: nil, calendar: paris,
                                   continuous: { now.timeIntervalSince1970 }, runningApps: { [] })
        addTeardownBlock { @MainActor in c.shutdown() }
        return c
    }
    private func editor(_ blocking: BlockingController, _ focus: ConcentrationController, intent: String, explicit: Bool,
                        mode: SessionMode? = nil) -> BlockRuleEditor {
        var draft = FocusComposerDraft(); draft.intent = intent; draft.blockListIds = Set(blocking.lists.prefix(2).map(\.id))
        return BlockRuleEditor(subject: .session(draft), blocking: blocking, braise: nil, focus: focus, now: wednesday10h, maxHeight: 2_000,
                               sessionDraft: draft, explicitSessionChoice: explicit, sessionMode: mode, onClose: {})
    }

    func testTheIntentionNoLongerDecidesTheEngineOnceTheChoiceIsExplicit() throws {
        let c = blocking(lists()), f = try focus()
        XCTAssertFalse(editor(c, f, intent: "", explicit: false).usesFocus, "before: empty intention = a block")
        XCTAssertTrue(editor(c, f, intent: "relire le contrat", explicit: false).usesFocus, "before: a filled intention = Concentration")
        XCTAssertTrue(editor(c, f, intent: "", explicit: true).usesFocus, "after: Séance de travail by default, even without an intention")
        XCTAssertFalse(editor(c, f, intent: "relire le contrat", explicit: true, mode: .block).usesFocus, "after: Blocage ponctuel wins over a typed intention")
        XCTAssertFalse(BlockRuleEditor(subject: .new, blocking: c, braise: nil, focus: nil, now: wednesday10h, explicitSessionChoice: true, onClose: {}).usesFocus, "no Concentration module: only the block exists")
    }

    // MARK: Renders

    @MainActor func testRenderMockups() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_M2_MOCKUP_SNAPSHOTS"] else { throw XCTSkip("Opt-in T-057 M2 mockup render") }
        let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let c = blocking(lists()), f = try focus()
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        func render(_ name: String, _ view: some View, width: CGFloat, height: CGFloat, background: Color) throws {
            let host = NSHostingController(rootView: view.frame(width: width, height: height, alignment: .top)
                .background(background).goalongControls().environment(\.goalongReduceMotion, true))
            window.contentViewController = host; window.setContentSize(NSSize(width: width, height: height))
            window.makeKeyAndOrderFront(nil); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            host.view.layoutSubtreeIfNeeded(); host.view.displayIfNeeded()
            let image = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.appearance = app.appearance
            let s = dark ? "dark" : "light"
            // Idea 2: the same window, a new session. Before: an « Intention » field decides. After: the choice is the first row.
            try render("idee2-avant-seance-" + s, editor(c, f, intent: "", explicit: false), width: 700, height: 900, background: LHTheme.pageBackground)
            try render("idee2-apres-seance-de-travail-" + s, editor(c, f, intent: "relire le contrat", explicit: true, mode: .work),
                       width: 700, height: 900, background: LHTheme.pageBackground)
            try render("idee2-apres-blocage-ponctuel-" + s, editor(c, f, intent: "", explicit: true, mode: .block),
                       width: 700, height: 900, background: LHTheme.pageBackground)
            // Idea 8: the Settings home with a query typed. Before = the section list of today; after = controls and commands.
            for query in ["conservation", "agenda", "suspendre"] {
                try render("idee8-avant-\(query)-" + s, legacyHome(query), width: 640, height: 330, background: LHTheme.pageBackground)
                try render("idee8-apres-\(query)-" + s, newHome(query), width: 640, height: 330, background: LHTheme.pageBackground)
            }
        }
    }

    /// The home of today, with its real search and its real section list (`SettingsPane.matches`).
    private func legacyHome(_ query: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Réglages").goalongPageTitle()
            GoalongSearchField("Rechercher un réglage…", text: .constant(query), accessibilityLabel: "Rechercher un réglage")
            LHCard(padding: 0) {
                let panes = SettingsPane.matches(query)
                if panes.isEmpty {
                    Text("Aucun réglage ne correspond à cette recherche.").font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(LHTheme.cardInset)
                }
                ForEach(panes, id: \.self) { GoalongSettingsLink(title: $0.title, value: "", symbol: $0.symbol) {} }
            }
            Spacer(minLength: 0)
        }.padding(24)
    }

    private func newHome(_ query: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Réglages").goalongPageTitle()
            GoalongSearchField("Rechercher un réglage ou une action…", text: .constant(query), accessibilityLabel: "Rechercher un réglage")
            SettingsSearchResults(query: query)
            Spacer(minLength: 0)
        }.padding(24)
    }
}
#endif
