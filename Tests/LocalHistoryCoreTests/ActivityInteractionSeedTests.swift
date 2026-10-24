import Foundation
import XCTest

@testable import LocalHistoryCore

final class ActivityInteractionSeedTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let host = "seed.example"
    private let pageURL = "https://seed.example/editor"

    // MARK: Seeds

    func testTypingSeedNamesTheTargetAndNeverClaimsToDecodeContent() throws {
        let element = ElementSnapshot(
            role: "AXTextArea", subrole: nil, title: "Message", label: nil,
            identifier: nil, isSecure: false)
        let seed = try XCTUnwrap(
            ActivityAnalysisEngine.webInteractionSeed(
                for: event(
                    kind: .typingBurst, element: element,
                    metadata: ["keystroke_count": "12", "duration_ms": "3400"])))
        XCTAssertEqual(seed.kind, .typing)
        XCTAssertEqual(seed.label, "Typed in Message")
        XCTAssertEqual(seed.role, "AXTextArea")
        XCTAssertEqual(seed.detail, "12 key events · 3400 ms · content not decoded")
    }

    func testTypingSeedWithoutTargetOrMetadataStillSaysContentIsNotDecoded() throws {
        let seed = try XCTUnwrap(
            ActivityAnalysisEngine.webInteractionSeed(
                for: event(kind: .typingBurst, metadata: ["keystroke_count": "many"])))
        XCTAssertEqual(seed.label, "Typed on page")
        XCTAssertEqual(seed.detail, "content not decoded")
    }

    func testScrollSeedPicksTheDominantAxisAndPrefersVerticalOnTies() throws {
        func label(_ dx: Double, _ dy: Double) throws -> String {
            try XCTUnwrap(
                ActivityAnalysisEngine.webInteractionSeed(
                    for: event(
                        kind: .scrollBurst,
                        scroll: ScrollSnapshot(deltaX: dx, deltaY: dy, eventCount: 7)))
            ).label
        }
        XCTAssertEqual(try label(0, -30), "Scrolled down")
        XCTAssertEqual(try label(0, 30), "Scrolled up")
        XCTAssertEqual(try label(-50, 10), "Scrolled right")
        XCTAssertEqual(try label(50, 10), "Scrolled left")
        XCTAssertEqual(try label(-20, -20), "Scrolled down")
        XCTAssertEqual(try label(-20, 20), "Scrolled up")
        let seed = try XCTUnwrap(
            ActivityAnalysisEngine.webInteractionSeed(
                for: event(
                    kind: .scrollBurst,
                    scroll: ScrollSnapshot(deltaX: 0, deltaY: 1, eventCount: 7))))
        XCTAssertEqual(seed.detail, "7 grouped scroll events")
    }

    func testShortcutSeedJoinsModifiersAndKeyAndFallsBackWhenEmpty() throws {
        let combo = try XCTUnwrap(
            ActivityAnalysisEngine.webInteractionSeed(
                for: event(
                    kind: .keyboardShortcut,
                    keyboard: KeyboardSnapshot(
                        category: "shortcut", key: "K", modifiers: ["cmd", "shift"],
                        isRepeat: false))))
        XCTAssertEqual(combo.kind, .shortcut)
        XCTAssertEqual(combo.label, "Shortcut cmd+shift+K")
        XCTAssertNil(combo.detail)

        let bare = try XCTUnwrap(
            ActivityAnalysisEngine.webInteractionSeed(
                for: event(
                    kind: .keyboardShortcut,
                    element: ElementSnapshot(
                        role: nil, subrole: nil, title: "  Search  ", label: nil,
                        identifier: nil, isSecure: false),
                    keyboard: KeyboardSnapshot(
                        category: "shortcut", key: nil, modifiers: [], isRepeat: false))))
        XCTAssertEqual(bare.label, "Keyboard shortcut")
        XCTAssertEqual(bare.detail, "Target: Search")
    }

    func testSeedsAreNilWithoutTheirPayloadAndForNonInputKinds() {
        XCTAssertNil(ActivityAnalysisEngine.webInteractionSeed(for: event(kind: .mouseClick)))
        XCTAssertNil(ActivityAnalysisEngine.webInteractionSeed(for: event(kind: .scrollBurst)))
        XCTAssertNil(
            ActivityAnalysisEngine.webInteractionSeed(for: event(kind: .keyboardShortcut)))
        XCTAssertNil(ActivityAnalysisEngine.webInteractionSeed(for: event(kind: .urlChanged)))
    }

    func testTargetLabelPrefersTitleThenLabelThenIdentifierThenCleanedRole() {
        func target(
            role: String? = nil, subrole: String? = nil, title: String? = nil,
            label: String? = nil, identifier: String? = nil
        ) -> String? {
            ActivityAnalysisEngine.webTargetLabel(
                ElementSnapshot(
                    role: role, subrole: subrole, title: title, label: label,
                    identifier: identifier, isSecure: false))
        }
        XCTAssertNil(ActivityAnalysisEngine.webTargetLabel(nil))
        XCTAssertEqual(target(title: "T", label: "L", identifier: "I"), "T")
        XCTAssertEqual(target(title: "  ", label: "L", identifier: "I"), "L")
        XCTAssertEqual(target(label: "", identifier: "send-btn"), "send-btn")
        XCTAssertEqual(target(role: "AXScroll_Area"), "Scroll Area")
        XCTAssertEqual(target(subrole: "AXCloseButton"), "CloseButton")
        XCTAssertNil(target(role: "AX"))
        XCTAssertNil(target(role: ""))
    }

    func testPageIdentityFallsBackFromURLToHostAndNormalizedTitle() {
        XCTAssertEqual(
            ActivityAnalysisEngine.pageIdentity(URL: "https://a.example/x", title: "T", host: "a.example"),
            "https://a.example/x")
        XCTAssertEqual(
            ActivityAnalysisEngine.pageIdentity(URL: "", title: "My  Page!", host: "a.example"),
            "a.example|" + ActivityAnalysisEngine.normalizedComparable("My  Page!"))
        XCTAssertEqual(
            ActivityAnalysisEngine.pageIdentity(URL: nil, title: "!!!", host: "a.example"),
            "a.example")
    }

    // MARK: Aggregation

    func testTypingScrollAndShortcutCountersFeedPageAndSiteTotals() throws {
        let events = [
            event(at: 0, kind: .urlChanged),
            event(at: 5, kind: .typingBurst),
            event(at: 10, kind: .typingBurst),
            event(at: 15, kind: .scrollBurst, scroll: ScrollSnapshot(deltaX: 0, deltaY: -9, eventCount: 3)),
            event(
                at: 20, kind: .keyboardShortcut,
                keyboard: KeyboardSnapshot(category: "shortcut", key: "F", modifiers: ["cmd"], isRepeat: false)),
        ]
        let site = try XCTUnwrap(analyze(events).sites.first)
        let page = try XCTUnwrap(site.pages.first)
        XCTAssertEqual(page.typingBurstCount, 2)
        XCTAssertEqual(page.scrollBurstCount, 1)
        XCTAssertEqual(page.shortcutCount, 1)
        XCTAssertEqual(page.clickCount, 0)
        XCTAssertEqual(site.typingBurstCount, 2)
        XCTAssertEqual(site.scrollBurstCount, 1)
        XCTAssertEqual(site.shortcutCount, 1)
        let typing = try XCTUnwrap(page.interactions.first { $0.kind == .typing })
        XCTAssertEqual(typing.count, 2, "two bursts on the same target merge into one counted interaction")
        XCTAssertEqual(typing.firstSeen, start.addingTimeInterval(5))
        XCTAssertEqual(typing.lastSeen, start.addingTimeInterval(10))
    }

    func testEqualFirstSeenInteractionsSortByLabelAndIdsAreStable() throws {
        func clickEvents(_ title: String) -> HistoryEvent {
            event(
                at: 3, kind: .mouseClick,
                element: ElementSnapshot(
                    role: "AXButton", subrole: nil, title: title, label: nil,
                    identifier: nil, isSecure: false),
                pointer: PointerSnapshot(button: "left", x: 1, y: 1, clickCount: 1))
        }
        let events = [event(at: 0, kind: .urlChanged), clickEvents("Zeta"), clickEvents("Alpha"), clickEvents("Mid")]
        let first = try XCTUnwrap(analyze(events).sites.first)
        XCTAssertEqual(first.interactions.map(\.label), ["Alpha", "Mid", "Zeta"])
        let second = try XCTUnwrap(analyze(events.reversed()).sites.first)
        XCTAssertEqual(second.interactions.map(\.label), ["Alpha", "Mid", "Zeta"])
        XCTAssertEqual(first.interactions.map(\.id), second.interactions.map(\.id))
        XCTAssertEqual(Set(first.interactions.map(\.id)).count, 3)
    }

    func testInteractionsAreTruncatedPerPageAndFlagged() throws {
        let labels = (0..<6).map { "Btn\($0)" }
        let clicks = labels.enumerated().map { index, title in
            event(
                at: Double(index + 1), kind: .mouseClick,
                element: ElementSnapshot(
                    role: "AXButton", subrole: nil, title: title, label: nil,
                    identifier: nil, isSecure: false),
                pointer: PointerSnapshot(button: "left", x: 1, y: 1, clickCount: 1))
        }
        let analysis = analyze(
            [event(at: 0, kind: .urlChanged)] + clicks,
            options: ActivityAnalysisOptions(maximumWebInteractionsPerPage: 4))
        let page = try XCTUnwrap(analysis.sites.first?.pages.first)
        XCTAssertEqual(page.interactions.map(\.label), ["Btn0", "Btn1", "Btn2", "Btn3"])
        XCTAssertTrue(page.interactionsTruncated)
        XCTAssertEqual(page.clickCount, 6, "counters keep the full total even when the list is cut")
        XCTAssertFalse(try XCTUnwrap(analysis.sites.first).interactionsTruncated)
    }

    // MARK: Helpers

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func analyze(
        _ events: [HistoryEvent], options: ActivityAnalysisOptions = .default
    ) -> ActivityDayAnalysis {
        ActivityAnalysisEngine.analyze(
            events: events, day: start, calendar: utcCalendar, options: options)
    }

    private func event(
        at offset: Double = 0,
        kind: EventKind,
        host: String? = nil,
        URL: String? = nil,
        element: ElementSnapshot? = nil,
        pointer: PointerSnapshot? = nil,
        keyboard: KeyboardSnapshot? = nil,
        scroll: ScrollSnapshot? = nil,
        metadata: [String: String]? = nil
    ) -> HistoryEvent {
        let eventHost = host ?? self.host
        return HistoryEvent(
            id: "seed-\(kind.rawValue)-\(offset)-\(element?.title ?? "")",
            sessionID: "seed-test",
            timestamp: start.addingTimeInterval(offset),
            kind: kind,
            app: AppSnapshot(name: "Seed Browser", bundleIdentifier: "example.seed", processIdentifier: 7),
            window: WindowSnapshot(title: "Editor", role: "AXWindow", subrole: nil),
            element: element,
            url: URLSnapshot(value: URL ?? pageURL, host: eventHost, redactionApplied: true),
            pointer: pointer,
            keyboard: keyboard,
            scroll: scroll,
            classification: LocalClassification(
                category: "web", isWork: nil, confidence: 0.9, classifierVersion: "seed-test"),
            metadata: metadata
        )
    }
}
