import Foundation
import XCTest
@testable import LocalHistoryCore

final class WebActivityAnalysisTests: XCTestCase {
    func testKeepsEveryObservedSiteInsteadOfStoppingAtThePreviousSmallSummaryLimit() {
        let start = makeDate("2026-08-19T08:00:00Z")
        let events = (0..<30).map { index in
            webEvent(
                at: start.addingTimeInterval(TimeInterval(index * 60)),
                host: "site\(index).example",
                title: "Page \(index)",
                path: "/page/\(index)",
                appName: "Unlisted Web Container",
                bundleIdentifier: "example.unlisted.container"
            )
        }

        let analysis = ActivityAnalysisEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar
        )

        XCTAssertEqual(analysis.sites.count, 30)
        XCTAssertEqual(Set(analysis.sites.map(\.host)).count, 30)
        XCTAssertTrue(analysis.sites.contains { $0.host == "site29.example" })
        XCTAssertTrue(
            analysis.sites.allSatisfy {
                $0.sourceApplications == ["Unlisted Web Container"]
            }
        )
    }

    func testGroupsIdenticalClickTargetsOnTheSamePageAndKeepsTheirTotalCount() {
        let start = makeDate("2026-08-19T09:00:00Z")
        let host = "chat.example"
        let URL = "https://chat.example/conversation/42"
        let target = ElementSnapshot(
            role: "AXButton",
            subrole: nil,
            title: "Send message",
            label: "Send",
            identifier: "composer-send",
            isSecure: false
        )
        let events = [
            webEvent(at: start, host: host, title: "Conversation 42", path: "/conversation/42"),
            webInputEvent(
                at: start.addingTimeInterval(10),
                kind: .mouseClick,
                host: host,
                title: "Conversation 42",
                URL: URL,
                element: target,
                pointer: PointerSnapshot(button: "left", x: 810, y: 690, clickCount: 1)
            ),
            webInputEvent(
                at: start.addingTimeInterval(25),
                kind: .mouseClick,
                host: host,
                title: "Conversation 42",
                URL: URL,
                element: target,
                pointer: PointerSnapshot(button: "left", x: 810, y: 690, clickCount: 2)
            ),
        ]

        let analysis = ActivityAnalysisEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar
        )
        let site = tryUnwrap(analysis.sites.first { $0.host == host })
        let clicks = site.interactions.filter { $0.kind == .click }

        XCTAssertEqual(site.clickCount, 2)
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks.first?.label, "Send message")
        XCTAssertEqual(clicks.first?.count, 2)
        XCTAssertEqual(site.pages.first?.clickCount, 2)
        XCTAssertTrue(clicks.first?.detail?.contains("click sequence 2") == true)
    }

    func testUnlabelledClickStillRetainsButtonAndCoordinates() {
        let start = makeDate("2026-08-19T10:00:00Z")
        let event = webInputEvent(
            at: start,
            kind: .mouseClick,
            host: "canvas.example",
            title: "Interactive canvas",
            URL: "https://canvas.example/editor",
            pointer: PointerSnapshot(button: "right", x: 123.4, y: 456.7, clickCount: 1)
        )

        let analysis = ActivityAnalysisEngine.analyze(
            events: [event],
            day: start,
            calendar: utcCalendar
        )
        let interaction = tryUnwrap(analysis.sites.first?.interactions.first)

        XCTAssertEqual(interaction.kind, .click)
        XCTAssertTrue(interaction.label.contains("Unlabelled right click"))
        XCTAssertTrue(interaction.label.contains("123"))
        XCTAssertTrue(interaction.label.contains("457"))
        XCTAssertTrue(interaction.detail?.contains("right button") == true)
    }

    func testKeepsAccessibleWebDiscussionContextOnItsSiteAndPage() {
        let start = makeDate("2026-08-19T11:00:00Z")
        let context = "User: Improve the website analysis and retain the full visible discussion.\nAssistant: I will group pages and actions by domain."
        let event = webInputEvent(
            at: start,
            kind: .focusChanged,
            host: "chatgpt.example",
            title: "Website analysis discussion",
            URL: "https://chatgpt.example/c/website-analysis",
            metadata: [
                ActivitySemanticMetadata.version: "2",
                ActivitySemanticMetadata.text: context,
                ActivitySemanticMetadata.source: "visible",
            ]
        )

        let analysis = ActivityAnalysisEngine.analyze(
            events: [event],
            day: start,
            calendar: utcCalendar
        )
        let site = tryUnwrap(analysis.sites.first)

        XCTAssertEqual(site.semanticSnapshotCount, 1)
        XCTAssertTrue(site.rememberedContext.contains { $0.contains("Improve the website analysis") })
        XCTAssertTrue(site.pages.first?.rememberedContext.contains { $0.contains("group pages and actions") } == true)
        XCTAssertTrue(analysis.requests.contains { $0.text.contains("Improve the website analysis") })
    }

    func testNeverExposesClicksOrVisibleContextFromSuppressedWebPeriods() {
        let start = makeDate("2026-08-19T12:00:00Z")
        let hidden = HistoryEvent(
            id: UUID().uuidString,
            sessionID: "web-analysis-test",
            timestamp: start,
            kind: .mouseClick,
            app: AppSnapshot(
                name: "Unknown Browser",
                bundleIdentifier: "example.unknown.browser",
                processIdentifier: 99
            ),
            window: nil,
            element: ElementSnapshot(
                role: "AXButton",
                subrole: nil,
                title: "Secret action",
                label: nil,
                identifier: nil,
                isSecure: false
            ),
            url: URLSnapshot(
                value: "https://private.example/secret",
                host: "private.example",
                redactionApplied: true
            ),
            pointer: PointerSnapshot(button: "left", x: 5, y: 5, clickCount: 1),
            classification: LocalClassification(
                category: "private_browsing",
                isWork: nil,
                confidence: 1,
                classifierVersion: "web-analysis-test"
            ),
            suppressionReason: .privateBrowserWindow,
            metadata: [ActivitySemanticMetadata.text: "This must never appear"]
        )

        let analysis = ActivityAnalysisEngine.analyze(
            events: [hidden],
            day: start,
            calendar: utcCalendar
        )

        XCTAssertTrue(analysis.sites.isEmpty)
        XCTAssertTrue(analysis.requests.isEmpty)
        XCTAssertTrue(analysis.contextHighlights.isEmpty)
        XCTAssertEqual(analysis.coverage.privateMinuteCount, 1)
    }

    func testAgentDigestIncludesSitePageAndClickInformationWithinBudget() {
        let start = makeDate("2026-08-19T13:00:00Z")
        let events = [
            webEvent(at: start, host: "product.example", title: "Dashboard", path: "/dashboard"),
            webInputEvent(
                at: start.addingTimeInterval(12),
                kind: .mouseClick,
                host: "product.example",
                title: "Dashboard",
                URL: "https://product.example/dashboard",
                element: ElementSnapshot(
                    role: "AXButton",
                    subrole: nil,
                    title: "Create report",
                    label: nil,
                    identifier: "create-report",
                    isSecure: false
                ),
                pointer: PointerSnapshot(button: "left", x: 300, y: 200, clickCount: 1)
            ),
        ]

        let analysis = ActivityAnalysisEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar,
            options: ActivityAnalysisOptions(agentTokenBudget: 700)
        )

        XCTAssertLessThanOrEqual(analysis.estimatedAgentTokens, 700)
        XCTAssertTrue(analysis.agentMarkdown.contains("product.example"))
        XCTAssertTrue(analysis.agentMarkdown.contains("clicks=1"))
        XCTAssertTrue(analysis.agentMarkdown.contains("Create report"))
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func webEvent(
        at date: Date,
        host: String,
        title: String,
        path: String,
        appName: String = "Generic Web Container",
        bundleIdentifier: String? = "example.generic.web"
    ) -> HistoryEvent {
        webInputEvent(
            at: date,
            kind: .urlChanged,
            host: host,
            title: title,
            URL: "https://\(host)\(path)",
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
    }

    private func webInputEvent(
        at date: Date,
        kind: EventKind,
        host: String,
        title: String,
        URL: String,
        appName: String = "Generic Web Container",
        bundleIdentifier: String? = "example.generic.web",
        element: ElementSnapshot? = nil,
        pointer: PointerSnapshot? = nil,
        keyboard: KeyboardSnapshot? = nil,
        scroll: ScrollSnapshot? = nil,
        metadata: [String: String]? = nil
    ) -> HistoryEvent {
        HistoryEvent(
            id: UUID().uuidString,
            sessionID: "web-analysis-test",
            timestamp: date,
            kind: kind,
            app: AppSnapshot(
                name: appName,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: 99
            ),
            window: WindowSnapshot(title: title, role: "AXWindow", subrole: nil),
            element: element,
            url: URLSnapshot(value: URL, host: host, redactionApplied: true),
            pointer: pointer,
            keyboard: keyboard,
            scroll: scroll,
            classification: LocalClassification(
                category: "web",
                isWork: nil,
                confidence: 0.95,
                classifierVersion: "web-analysis-test"
            ),
            metadata: metadata
        )
    }

    private func makeDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Test cannot continue after missing value")
        }
        return value
    }
}
