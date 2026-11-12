import Foundation
import XCTest
@testable import LocalHistoryCore

/// T-055: a context whose content changes (AI chat, messaging, untitled page) is judged on what is visible,
/// never asked to the user as one « est-ce du travail ? » for the whole page.
final class GoalongWorkContentVaryingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))! }
    private func event(_ seconds: Double, app: String, bundle: String? = nil, host: String? = nil, title: String?) -> HistoryEvent {
        HistoryEvent(id: UUID().uuidString, sessionID: "fixture", timestamp: day.addingTimeInterval(seconds), kind: .heartbeat,
            app: .init(name: app, bundleIdentifier: bundle ?? "fixture." + app, processIdentifier: 1),
            window: WindowSnapshot(title: title, role: nil, subrole: nil),
            url: host.map { .init(value: "https://" + $0, host: $0, redactionApplied: true) },
            classification: .init(category: "fixture", isWork: nil, confidence: 0.99, classifierVersion: "legacy"))
    }
    private func label(_ app: String, bundle: String? = nil, host: String? = nil, _ title: String?) -> GoalongWorkContext.Label {
        GoalongWorkContext.Label(application: app, bundleIdentifier: bundle ?? "fixture." + app, host: host, title: title)
    }

    func testAIChatsMessagingAndGenericTitlesVaryWithContent() {
        let varying = [
            label("Google Chrome", host: "chatgpt.com", "ChatGPT - aside"),
            label("Safari", host: "www.chatgpt.com", "ChatGPT Home"),
            label("Safari", host: "claude.ai", "Plan de lancement - Claude"),
            label("ChatGPT", bundle: "com.openai.chat", "Nouvelle discussion"),
            label("Slack", bundle: "com.tinyspeck.slackmacgap", "Atlas (Canal) - Peerlab - Slack"),
            label("Messages", bundle: "com.apple.MobileSMS", "Léa"),
            label("Pages", "Sans titre"),
            label("Google Chrome", host: "docs.google.com", "Document sans titre - Google Docs"),
            label("Safari", host: "example.org", "Home"),
            label("Notes", "Notes"),
        ]
        for value in varying { XCTAssertTrue(GoalongWorkContext.variesWithContent(value), "\(value)") }
        let fixed = [
            label("Xcode", "Goalong — GoalongWorkClarify.swift"),
            label("Google Chrome", host: "docs.google.com", "Plan Atlas Q4 - Google Docs"),
            label("Safari", host: "notion.so", "Notes de réunion"),
            label("Finder", nil),
            label("Pages", "Rapport"),
        ]
        for value in fixed { XCTAssertFalse(GoalongWorkContext.variesWithContent(value), "\(value)") }
    }

    /// The owner's case: many ChatGPT pages (« ChatGPT Home », a conversation…) left unsure by the classification
    /// became one question each. None is a question now; a page with a precise title still is.
    func testUnsureContentVaryingContextsAreNeverQuestions() {
        var events: [HistoryEvent] = []
        let pages: [(String, String?, String?, String)] = [
            ("Google Chrome", nil, "chatgpt.com", "ChatGPT Home"),
            ("Google Chrome", nil, "chatgpt.com", "ChatGPT - aside"),
            ("ChatGPT", "com.openai.chat", nil, "ChatGPT"),
            ("Pages", nil, nil, "Sans titre"),
            ("Pages", nil, nil, "Rapport Atlas"),
        ]
        for (index, page) in pages.enumerated() {
            events += (0...10).map { event(36_000 + Double(index * 900 + $0 * 60), app: page.0, bundle: page.1, host: page.2, title: page.3) }
        }
        let observation = GoalongWorkClassification.observation(events: events, day: day, now: day.addingTimeInterval(86_400), calendar: calendar)
        let unsure = Dictionary(uniqueKeysWithValues: observation.labels.keys.map { ($0, GoalongWorkAssignment(verdict: .unclear)) })
        let summary = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: GoalongWorkVerdicts(unsure))
        let precise = label("Pages", "Rapport Atlas").key
        XCTAssertEqual(summary.states[precise], .toClarify(.agentUnsure))
        for (key, value) in observation.labels where key != precise {
            XCTAssertEqual(summary.states[key], .waiting(.judgedByContent), "\(value)")
        }
        XCTAssertEqual(summary.count(.toClarify), 1)
        // Excluded from sharing, a content-varying page is not asked either: nothing can judge it.
        let blocked = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: GoalongWorkVerdicts(),
                                                       permits: { _ in false })
        XCTAssertEqual(blocked.states[label("Google Chrome", host: "chatgpt.com", "ChatGPT Home").key], .waiting(.sharingBlocked))
        XCTAssertEqual(blocked.states[precise], .toClarify(.neverSent))
        // A verdict, once given, still classifies the page.
        let answered = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: GoalongWorkVerdicts(
            [label("Google Chrome", host: "chatgpt.com", "ChatGPT - aside").key: .init(verdict: .other)]))
        XCTAssertEqual(answered.states[label("Google Chrome", host: "chatgpt.com", "ChatGPT - aside").key], .classified(.other, .agent))
    }

    /// The classification is told that such a context is judged on its visible content, and gets that content.
    func testRequestFlagsContentVaryingContextsAndKeepsTheirExcerpt() throws {
        let chat = label("Google Chrome", host: "chatgpt.com", "ChatGPT Home"), report = label("Pages", "Rapport Atlas")
        let events = (0...10).map { event(36_000 + Double($0 * 60), app: "Google Chrome", host: "chatgpt.com", title: "ChatGPT Home") }
            + (0...10).map { event(40_000 + Double($0 * 60), app: "Pages", title: "Rapport Atlas") }
        let observation = GoalongWorkClassification.observation(events: events, day: day, now: day.addingTimeInterval(86_400), calendar: calendar)
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels, verdicts: GoalongWorkVerdicts(), calendar: calendar)
        let definition = GoalongWorkDefinition(goals: "Atlas")
        let request = GoalongWorkClassification.request(date: "2026-11-12", definition: definition, pending: pending, batch: pending.keys,
            day: observation.day, verdicts: GoalongWorkVerdicts(), knownTasks: [], examples: [], calendar: calendar,
            contextExcerpts: [chat.key: "Rédige le plan de lancement de l’app Atlas"])
        let sentChat = try XCTUnwrap(request.contexts.first { request.keys[$0.id] == chat.key })
        let sentReport = try XCTUnwrap(request.contexts.first { request.keys[$0.id] == report.key })
        XCTAssertEqual(sentChat.varies, true); XCTAssertNil(sentReport.varies)
        XCTAssertEqual(sentChat.visible_context_excerpt, "Rédige le plan de lancement de l’app Atlas")
        let prompt = GoalongWorkClassification.prompt(request, definition: definition)
        XCTAssertTrue(prompt.contains("\"d\":true")); XCTAssertTrue(prompt.contains("jamais sur l’app, le site ou le titre"))
    }

    /// An owner answer about one ChatGPT page is not shown as an example: it would teach « ChatGPT = travail ».
    func testAnswersAboutContentVaryingPagesAreNotExamples() {
        let chat = label("Google Chrome", host: "chatgpt.com", "ChatGPT - aside")
        let doc = label("Google Chrome", host: "docs.google.com", "Plan Atlas Q4")
        let examples = GoalongWorkClassification.nearestExamples(
            [(chat, .init(verdict: .work, task: "Atlas")), (doc, .init(verdict: .work, task: "Atlas"))],
            for: [label("Google Chrome", host: "chatgpt.com", "ChatGPT Home")])
        XCTAssertEqual(examples.map(\.title), ["Plan Atlas Q4"])
    }
}
