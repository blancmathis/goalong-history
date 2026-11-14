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
        let summary = GoalongWorkClassification.states(day: observation.day, labels: observation.labels,
                                                       verdicts: GoalongWorkVerdicts(unsure, judgedOnContent: Set(unsure.keys)))
        let precise = label("Pages", "Rapport Atlas").key
        XCTAssertEqual(summary.states[precise], .toClarify(.agentUnsure))
        for (key, value) in observation.labels where key != precise {
            XCTAssertEqual(summary.states[key], .waiting(.judgedByContent), "\(value)")
        }
        XCTAssertEqual(summary.count(.toClarify), 1)
        // Excluded from sharing, nothing can judge a content-varying page: the owner is asked, never left silent (review B1).
        let blocked = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: GoalongWorkVerdicts(),
                                                       permits: { _ in false })
        XCTAssertEqual(blocked.states[label("Google Chrome", host: "chatgpt.com", "ChatGPT Home").key], .toClarify(.neverSent))
        XCTAssertEqual(blocked.states[precise], .toClarify(.neverSent))
        // A verdict judged on the content still classifies the page.
        let aside = label("Google Chrome", host: "chatgpt.com", "ChatGPT - aside").key
        let answered = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: GoalongWorkVerdicts(
            [aside: .init(verdict: .other)], judgedOnContent: [aside]))
        XCTAssertEqual(answered.states[aside], .classified(.other, .agent))
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

    private func chatObservation(minutes: Int = 11, title: String = "ChatGPT Home") -> GoalongWorkClassification.Observation {
        let events = (0...minutes).map { event(36_000 + Double($0 * 60), app: "Google Chrome", host: "chatgpt.com", title: title) }
            + (0...10).map { event(40_000 + Double($0 * 60), app: "Pages", title: "Rapport Atlas") }
        return GoalongWorkClassification.observation(events: events, day: day, now: day.addingTimeInterval(86_400), calendar: calendar)
    }

    /// Review B1: an unsure content-varying context waits only while the next pass can read its content. Visible text
    /// not shared, no try left, or too short to be asked again: the owner is asked about it, with an honest reason.
    func testUnreadableContentVaryingContextFallsBackToAQuestion() {
        let observation = chatObservation(), chat = label("Google Chrome", host: "chatgpt.com", "ChatGPT Home").key
        let unsure = GoalongWorkVerdicts([chat: .init(verdict: .unclear)], retries: [chat: .init(attempts: 1, lastAskedDay: "2026-11-11")],
                                         judgedOnContent: [chat])
        func state(_ verdicts: GoalongWorkVerdicts, content: Bool = true, in value: GoalongWorkClassification.Observation? = nil) -> GoalongWorkState? {
            let value = value ?? observation
            return GoalongWorkClassification.states(day: value.day, labels: value.labels, verdicts: verdicts,
                                                    permitsContent: { _ in content }).states[chat]
        }
        XCTAssertEqual(state(unsure), .waiting(.judgedByContent))
        XCTAssertEqual(state(unsure, content: false), .toClarify(.contentUnseen), "Visible text not shared: never silent")
        var spent = unsure; spent.retries[chat] = .init(attempts: 3, lastAskedDay: "2026-11-11")
        XCTAssertEqual(state(spent), .toClarify(.contentUnseen), "Three tries spent: never silent")
        XCTAssertEqual(state(unsure, in: chatObservation(minutes: 3)), .toClarify(.contentUnseen), "Under 5 min it is never asked again")
        XCTAssertFalse(GoalongWorkState.Waiting.judgedByContent.message.contains("ce qui est écrit"), "The message promises only the next pass")
    }

    /// Review M1: an older agent verdict on a content-varying page judged its title only. It is kept but not applied,
    /// and the page is sent again with its content. The owner's answers and rules still apply.
    func testOlderTitleOnlyVerdictsOnContentVaryingPagesAreNotApplied() {
        let observation = chatObservation(), chat = label("Google Chrome", host: "chatgpt.com", "ChatGPT Home").key
        let report = label("Pages", "Rapport Atlas").key
        let old = GoalongWorkVerdicts([chat: .init(verdict: .work, task: "Atlas"), report: .init(verdict: .work, task: "Atlas")])
        let states = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: old).states
        XCTAssertEqual(states[chat], .waiting(.notYetPassed)); XCTAssertEqual(states[report], .classified(.work, .agent))
        XCTAssertEqual(old.contexts[chat]?.verdict, .work, "Nothing stored is deleted")
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: observation.labels, verdicts: old, calendar: calendar)
        XCTAssertEqual(pending.keys, [chat]); XCTAssertEqual(pending.varying, [chat])
        let applied = observation.day.applying(old)
        XCTAssertFalse(applied.segments.contains { $0.contextKey == chat && $0.kind == .work }, "Activité does not apply it either")
        var owner = old; owner.contexts[chat] = .init(verdict: .other, byOwner: true)
        XCTAssertEqual(GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: owner).states[chat],
                       .classified(.other, .context))
        let site = GoalongWorkVerdicts(old.contexts, rules: GoalongWorkRules([GoalongWorkRule(scope: .site, target: "chatgpt.com", label: "chatgpt.com", verdict: .work)!]))
        XCTAssertEqual(GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: site).states[chat],
                       .classified(.work, .site), "An explicit site rule still applies")
        // A group verdict is never handed to a content-varying page.
        let inherited = GoalongWorkClassification.inherited(labels: observation.labels, verdicts: GoalongWorkVerdicts(),
            groups: [GoalongWorkContext.groupKey(label("Google Chrome", host: "chatgpt.com", "ChatGPT Home")): .init(verdict: .work)])
        XCTAssertNil(inherited[chat])
    }

    /// Review M3: counters, numbers and more generic words.
    func testGenericTitlesIgnoreCountersAndNumbers() {
        let generic = [
            label("Safari", host: "x.com", "(3) Home / X"), label("Code", "Untitled-1"), label("Pages", "Sans titre 2"),
            label("Safari", host: "example.org", "Page d’accueil"), label("Figma", "Welcome"), label("Safari", host: "example.org", "Bienvenue"),
            label("Notion", "Settings"), label("Safari", host: "example.org", "Réglages"), label("Safari", host: "instagram.com", "Explore"),
            label("Xcode", "Xcode"),
        ]
        for value in generic { XCTAssertTrue(GoalongWorkContext.isGenericTitle(value), "\(value)") }
        for value in [label("Pages", "Rapport 2"), label("Safari", host: "x.com", "(3) Lancement Atlas / X"), label("Finder", nil)] {
            XCTAssertFalse(GoalongWorkContext.isGenericTitle(value), "\(value)")
        }
    }

    /// Review M4: the agent sends masked labels. A scope that removes the site still sends `d` (and so its excerpt),
    /// as the screen says: the raw label decides.
    func testMaskedLabelKeepsTheContentFlagOfTheRawLabel() throws {
        let observation = chatObservation(title: "Plan de lancement")
        let chat = label("Google Chrome", host: "chatgpt.com", "Plan de lancement").key
        let masked = observation.labels.mapValues { GoalongWorkContext.Label(application: $0.application, bundleIdentifier: $0.bundleIdentifier, host: nil, title: $0.title) }
        XCTAssertFalse(GoalongWorkContext.variesWithContent(masked[chat]!))
        let pending = GoalongWorkClassification.pending(day: observation.day, labels: masked, verdicts: GoalongWorkVerdicts(),
                                                        rawLabels: observation.labels, calendar: calendar)
        XCTAssertEqual(pending.varying, [chat])
        let request = GoalongWorkClassification.request(date: "2026-11-12", definition: GoalongWorkDefinition(goals: "Atlas"), pending: pending,
            batch: pending.keys, day: observation.day, verdicts: GoalongWorkVerdicts(), knownTasks: [], examples: [], calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(request.contexts.first { request.keys[$0.id] == chat }).varies, true)
    }
}
