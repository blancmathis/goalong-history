import Foundation
import XCTest

@testable import LocalHistoryCore

final class ActivityAnalysisTests: XCTestCase {
    func testCompressesNoisyEventsIntoRepresentativeMinutesWithinBudget() {
        let start = makeDate("2026-08-18T09:00:00Z")
        var events: [HistoryEvent] = []
        for minute in 0..<10 {
            for eventIndex in 0..<20 {
                events.append(
                    event(
                        at: start.addingTimeInterval(TimeInterval(minute * 60 + eventIndex * 2)),
                        kind: eventIndex.isMultiple(of: 3) ? .windowChanged : .mouseClick,
                        appName: "Xcode",
                        bundleIdentifier: "com.apple.dt.Xcode",
                        title: "ActivityAnalysis.swift — goalong-history",
                        category: "software_development",
                        isWork: true
                    )
                )
            }
        }

        let analysis = ActivityAnalysisEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar,
            options: ActivityAnalysisOptions(agentTokenBudget: 500)
        )

        XCTAssertEqual(analysis.coverage.sourceEventCount, 200)
        XCTAssertEqual(analysis.coverage.representativeMinuteCount, 10)
        XCTAssertEqual(analysis.activeSeconds, 600)
        XCTAssertEqual(analysis.focusBlocks.count, 1)
        XCTAssertLessThanOrEqual(analysis.estimatedAgentTokens, 500)
        XCTAssertTrue(analysis.agentMarkdown.contains("events=200↓10 representative minutes"))
    }

    func testGroupsChangingPagesOnOneSiteAndSeparatesAnotherSite() {
        let start = makeDate("2026-08-18T09:00:00Z")
        let events = [
            webEvent(at: start, host: "github.com", title: "Pull requests · goalong-history", path: "/pulls"),
            webEvent(
                at: start.addingTimeInterval(60), host: "github.com", title: "Improve analysis · Pull Request",
                path: "/pull/4"),
            webEvent(
                at: start.addingTimeInterval(120), host: "developer.apple.com", title: "Accessibility API",
                path: "/accessibility"),
            webEvent(
                at: start.addingTimeInterval(180), host: "developer.apple.com", title: "AXUIElement",
                path: "/axuielement"),
        ]

        let analysis = ActivityAnalysisEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar
        )

        XCTAssertEqual(analysis.focusBlocks.count, 2)
        XCTAssertEqual(analysis.sites.map(\.host), ["developer.apple.com", "github.com"].sorted())
        XCTAssertEqual(analysis.sites.first(where: { $0.host == "github.com" })?.pages.count, 2)
    }

    func testPreservesMultipleSitesSeenInsideOneCompressedMinute() {
        let start = makeDate("2026-08-18T10:00:00Z")
        let events = [
            webEvent(at: start, host: "github.com", title: "Repository", path: "/repo"),
            webEvent(
                at: start.addingTimeInterval(25),
                host: "developer.apple.com",
                title: "Documentation",
                path: "/docs"
            ),
        ]

        let analysis = ActivityAnalysisEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar
        )

        XCTAssertEqual(analysis.coverage.representativeMinuteCount, 1)
        XCTAssertEqual(Set(analysis.sites.map(\.host)), Set(["github.com", "developer.apple.com"]))
        XCTAssertEqual(analysis.sites.reduce(0) { $0 + $1.activeSeconds }, 60)
    }

    func testExtractsRequestsFromRichContextButNeverFromSuppressedPeriods() {
        let start = makeDate("2026-08-18T11:00:00Z")
        let visible = event(
            at: start,
            kind: .focusChanged,
            appName: "ChatGPT",
            bundleIdentifier: "com.openai.chat",
            title: "Improve the Goalong History analysis",
            host: "chatgpt.com",
            URL: "https://chatgpt.com/c/analysis",
            metadata: [
                ActivitySemanticMetadata.version: "1",
                ActivitySemanticMetadata.text:
                    "Improve the analysis page and show every visited site clearly?\nThe existing timeline repeats too many window changes.",
            ]
        )
        let privateEvent = event(
            at: start.addingTimeInterval(60),
            kind: .focusChanged,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            suppressionReason: .privateBrowserWindow,
            metadata: [ActivitySemanticMetadata.text: "Reveal this private request?"]
        )

        let analysis = ActivityAnalysisEngine.analyze(
            events: [visible, privateEvent],
            day: start,
            calendar: utcCalendar
        )

        XCTAssertTrue(analysis.requests.contains { $0.text.contains("Improve the analysis page") })
        XCTAssertFalse(analysis.requests.contains { $0.text.contains("private request") })
        XCTAssertEqual(analysis.coverage.semanticSnapshotCount, 1)
        XCTAssertEqual(analysis.coverage.privateMinuteCount, 1)
    }

    func testSemanticSanitizerRedactsCommonCredentials() {
        let raw = "api_key=sk-abcdefghijklmnopqrstuvwxyz password: hunter2 token ghp_abcdefghijklmnopqrstuvwxyz1234"
        let cleaned = ActivitySemanticTextSanitizer.clean(raw, maximumLength: 500)

        XCTAssertNotNil(cleaned)
        XCTAssertFalse(cleaned?.contains("hunter2") == true)
        XCTAssertFalse(cleaned?.contains("sk-abcdefghijklmnopqrstuvwxyz") == true)
        XCTAssertFalse(cleaned?.contains("ghp_abcdefghijklmnopqrstuvwxyz1234") == true)
        XCTAssertTrue(cleaned?.contains("[REDACTED") == true)
    }

    func testCompiledSemanticSanitizerRulesPreserveOrderedReplacementBehavior() {
        let corpus = [
            "  tabs\tand   spaces\r\n\rline\n\n\nend  ",
            "PASSWORD: basic hidden-value, access_token=Bearer another-value",
            "sk-abcdefghijklmnop ghp_abcdefghijklmnopqrstuvwxyz1234",
            "eyJabcdefghijkl.abcdefgh.abcdefgh 4111 1111 1111 1111",
            "Résumé sans secret et texte 日本語",
        ]
        let rules: [(String, String)] = [
            ("[\\t ]+", " "),
            ("\\r\\n?", "\n"),
            ("\\n{3,}", "\n\n"),
            (
                #"(?i)\b(password|passwd|secret|api[ _-]?key|access[ _-]?token|authorization)\s*[:=]\s*(?:(?:bearer|basic)\s+)?[^\s,;]+"#,
                "$1=[REDACTED]"
            ),
            (#"\bsk-[A-Za-z0-9_-]{16,}\b"#, "[REDACTED_KEY]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, "[REDACTED_TOKEN]"),
            (
                #"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
                "[REDACTED_TOKEN]"
            ),
            (#"\b(?:\d[ -]*?){13,19}\b"#, "[REDACTED_NUMBER]"),
        ]

        for raw in corpus {
            var expected = raw.replacingOccurrences(of: "\u{0000}", with: "")
            for (pattern, replacement) in rules {
                expected = expected.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
            }
            expected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(ActivitySemanticTextSanitizer.redact(raw), expected)
        }
    }

    func testAgentDigestIsDeterministicForTheSameInputs() {
        let start = makeDate("2026-08-18T14:00:00Z")
        let events = [
            webEvent(at: start, host: "github.com", title: "goalong-history", path: "/blancmathis/goalong-history"),
            webEvent(
                at: start.addingTimeInterval(60), host: "github.com", title: "Activity analysis", path: "/issues/10"),
        ]
        let generatedAt = makeDate("2026-08-18T23:00:00Z")
        let first = ActivityAnalysisEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar,
            generatedAt: generatedAt
        )
        let second = ActivityAnalysisEngine.analyze(
            events: events,
            day: start,
            calendar: utcCalendar,
            generatedAt: generatedAt
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.agentMarkdown, second.agentMarkdown)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func webEvent(at date: Date, host: String, title: String, path: String) -> HistoryEvent {
        event(
            at: date,
            kind: .urlChanged,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: title,
            host: host,
            URL: "https://\(host)\(path)",
            category: "web"
        )
    }

    private func event(
        at date: Date,
        kind: EventKind,
        appName: String,
        bundleIdentifier: String?,
        title: String? = nil,
        host: String? = nil,
        URL: String? = nil,
        category: String = "other",
        isWork: Bool? = nil,
        suppressionReason: SuppressionReason? = nil,
        metadata: [String: String]? = nil
    ) -> HistoryEvent {
        HistoryEvent(
            id: UUID().uuidString,
            sessionID: "analysis-test",
            timestamp: date,
            kind: kind,
            app: AppSnapshot(
                name: appName,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: 42
            ),
            window: title.map { WindowSnapshot(title: $0, role: "AXWindow", subrole: nil) },
            url: URL.map { URLSnapshot(value: $0, host: host, redactionApplied: true) },
            classification: LocalClassification(
                category: category,
                isWork: isWork,
                confidence: 0.9,
                classifierVersion: "analysis-test"
            ),
            suppressionReason: suppressionReason,
            metadata: metadata
        )
    }

    private func makeDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
