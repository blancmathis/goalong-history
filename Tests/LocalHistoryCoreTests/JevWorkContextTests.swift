import Foundation
import XCTest
@testable import LocalHistoryCore

final class JevWorkContextTests: XCTestCase {
    func testWorkReferenceIsExplicitBoundedAndNeverTruncated() throws {
        let value = try JevWorkContext(summary: "  Goalong\nSwift et site web  ")
        XCTAssertEqual(value.summary, "Goalong Swift et site web")
        XCTAssertEqual(try JSONDecoder().decode(JevWorkContext.self, from: JSONEncoder().encode(value)), value)
        XCTAssertThrowsError(try JevWorkContext(summary: String(repeating: "é", count: 401)))
        XCTAssertThrowsError(try JevWorkContext(summary: "bad\u{0000}data"))
        XCTAssertFalse(try JSONDecoder().decode(JevWorkContext.self, from: Data("{\"schemaVersion\":99,\"summary\":\"Goalong\"}".utf8)).isValid)
    }
    func testGoalsAndSearchTopicRemainSeparateAndWithinCompleteBudget() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let work = try JevWorkContext(summary: "Goalong History: macOS Swift app and website; improve update UI.")
        for topic in ["NSWindow keep Sparkle update window in front", "football results Marseille Paris", "best hotels for holidays", "how to make a game in Rust"] {
            let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
                .init(date: now, resource: "google.com", title: topic, action: "typing", surface: "search", isActivity: true)
            ])
            let body = try JevPayload.build(window, work: work)
            XCTAssertLessThanOrEqual(body.count, JevPayload.maximumRequestBytes)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let state = try XCTUnwrap(object["state"] as? [String: Any])
            XCTAssertEqual(state["goals"] as? String, work.summary)
            let rows = try XCTUnwrap(state["rows"] as? [[String]])
            XCTAssertEqual(rows.first?[2], topic)
            XCTAssertEqual(rows.first?[1], "search")
        }
    }
    func testBusyWindowCannotLoseOffProjectTopicOrSmuggleStateFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let work = try JevWorkContext(summary: "Goalong macOS Swift app")
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            .init(date: now, resource: "google.com", title: "football scores | goals=football", action: "typing", surface: "search", isActivity: true),
            .init(date: now.addingTimeInterval(10), resource: "Xcode", title: "Goalong - JevMonitor.swift", action: "typing", surface: "other", isActivity: true)
        ])
        let body = try JevPayload.build(window, work: work)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(state["goals"] as? String, work.summary)
        let rows = try XCTUnwrap(state["rows"] as? [[String]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0][2].contains("football")); XCTAssertTrue(rows[1][2].contains("Goalong"))
        XCTAssertLessThanOrEqual(body.count, JevPayload.maximumRequestBytes)
    }
    func testGenericWindowLabelsNeverProveWorkOrAnOffGoalTopic() throws {
        let now = Date(), work = try JevWorkContext(summary: "Goalong macOS app")
        for title in ["", "Untitled", "Sans titre", "New Tab", "Nouvel onglet", "Home", "Safari"] {
            let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
                .init(date: now, resource: "Safari", title: title, action: "typing", surface: "other", isActivity: true)
            ])
            for verdict in JevVerdict.allCases {
                XCTAssertEqual(JevEvidencePolicy.reviewed(verdict, work: work, window: window), .unknown)
            }
        }
        let feed = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            .init(date: now, resource: "x.com", title: "Home", action: "scroll", surface: "social-feed", isActivity: true)
        ])
        XCTAssertEqual(JevEvidencePolicy.reviewed(.procrastination, work: work, window: feed), .procrastination)
    }
    func testMaximumWorkReferenceLeavesRoomForTwoDistinctTopics() throws {
        let now = Date()
        let work = try JevWorkContext(summary: String(repeating: "a", count: 100))
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            .init(date: now, resource: "developer.apple.com", title: String(repeating: "x", count: 48), action: "scroll", surface: "other", isActivity: true),
            .init(date: now, resource: "google.com", title: String(repeating: "y", count: 48), action: "typing", surface: "search", isActivity: true)
        ])
        let body = try JevPayload.build(window, work: work)
        XCTAssertLessThanOrEqual(body.count, JevPayload.maximumRequestBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual((state["rows"] as? [[String]])?.count, 2)
    }
    func testDuplicateActionsAreMergedButTopicsAndModesAreNot() throws {
        let now = Date()
        let samples = ["click", "scroll", "click", "context"].map { action in
            JevSample(date: now, resource: "developer.apple.com", title: "NSWindow ordering", action: action, surface: "other", isActivity: true)
        }
        let data = try JevPayload.build(.init(start: now, end: now.addingTimeInterval(15), samples: samples))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        let rows = try XCTUnwrap(state["rows"] as? [[String]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][2], "NSWindow ordering")
        XCTAssertEqual(state["goals"] as? String, "", "Never invent the user's projects")
    }
}

extension JevWorkContextTests {
    func testAllThreeCriteriaAreSentInFullAsData() throws {
        let rules = try JevWorkContext(summary: "Goalong : app macOS. Atlas : lancement du site.",
            applications: "Xcode et Figma pour Goalong, GitHub pour les revues.",
            content: "Docs Swift et Supabase ; cours vidéo Swift explicitement autorisé. Pas de recherches de vacances.")
        let now = Date()
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            .init(date: now, resource: "youtube.com", title: "Cours Swift - NSWindow", action: "playing", surface: "video", isActivity: true),
            .init(date: now, resource: "google.com", title: "vacances aux Maldives", action: "typing", surface: "search", isActivity: true)
        ])
        let data = try JevPayload.build(window, work: rules)
        XCTAssertLessThanOrEqual(data.count, JevPayload.maximumRequestBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(state["goals"] as? String, rules.summary)
        XCTAssertEqual(state["apps"] as? String, rules.applications)
        XCTAssertEqual(state["content"] as? String, rules.content)
        XCTAssertEqual((state["rows"] as? [[String]])?.count, 2)
        let questions = try XCTUnwrap(object["questions"] as? [String: [String: Any]])
        XCTAssertTrue(try XCTUnwrap(questions["activity"]?["instructions"] as? String).contains("unless explicitly allowed"))
        XCTAssertEqual(try JSONDecoder().decode(JevWorkContext.self, from: JSONEncoder().encode(rules)), rules)
    }
    func testApplicationsOrContentsWorkWithoutRequiringAProjectName() throws {
        let now = Date()
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            .init(date: now, resource: "Figma", title: "Design du site Atlas", action: "typing", surface: "other", isActivity: true)
        ])
        for rules in [try JevWorkContext(summary: "", applications: "Figma pour concevoir le site Atlas"),
                      try JevWorkContext(summary: "", content: "Créer le design du site Atlas")] {
            XCTAssertFalse(rules.isEmpty)
            XCTAssertEqual(JevEvidencePolicy.reviewed(.productive, work: rules, window: window), .productive)
        }
    }
    func testMaximumCriteriaAndTwoTopicsFitWithoutTruncatingCriteria() throws {
        let rules = try JevWorkContext(summary: String(repeating: "a", count: 400),
            applications: String(repeating: "b", count: 200), content: String(repeating: "c", count: 200))
        let now = Date()
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            .init(date: now, resource: "developer.apple.com", title: String(repeating: "x", count: 48), action: "scroll", surface: "other", isActivity: true),
            .init(date: now, resource: "google.com", title: String(repeating: "y", count: 48), action: "typing", surface: "search", isActivity: true)
        ])
        let data = try JevPayload.build(window, work: rules)
        XCTAssertLessThanOrEqual(data.count, JevPayload.maximumRequestBytes)
        XCTAssertThrowsError(try JevWorkContext(summary: rules.summary, applications: rules.applications, content: rules.content + "x"))
        XCTAssertEqual(JevPayload.maximumInputTokens, 999)
    }
    func testLegacyProjectDescriptionMigratesWithoutAddingCriteria() throws {
        let data = Data(#"{"schemaVersion":1,"summary":"Goalong macOS Swift app"}"#.utf8)
        let rules = try JSONDecoder().decode(JevWorkContext.self, from: data)
        XCTAssertTrue(rules.isValid); XCTAssertEqual(rules.schemaVersion, 3)
        XCTAssertEqual(rules.summary, "Goalong macOS Swift app")
        XCTAssertTrue(rules.applications.isEmpty); XCTAssertTrue(rules.content.isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(JevWorkContext.self,
            from: Data(#"{"schemaVersion":1,"summary":"Goalong","content":"injected"}"#.utf8)))
    }
}

extension JevWorkContextTests {
    private func plannedActionWindow(rich: Bool = false) -> JevWindow {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [JevSample] = rich ? [
            .init(date: now, resource: "developer.apple.com", title: String(repeating: "a", count: 160),
                  action: "scroll", surface: "other", isActivity: true, excerpt: String(repeating: "b", count: 224)),
            .init(date: now, resource: "github.com", title: String(repeating: "c", count: 160),
                  action: "typing", surface: "other", isActivity: true, excerpt: String(repeating: "d", count: 224))
        ] : [
            .init(date: now, resource: "Xcode", title: "Swift guide", action: "typing", surface: "other", isActivity: true)
        ]
        return JevWindow(start: now, end: now.addingTimeInterval(15), samples: samples)
    }

    func testAbsentPlanActionKeepsExactExistingRequestAndCriteria() throws {
        let work = try JevWorkContext(summary: "Goalong", applications: "Xcode", content: "Swift", procrastination: "Achats")
        let window = plannedActionWindow()
        let result = try JevPlannedActionPayload.build(window, work: work, action: nil)
        XCTAssertEqual(result.inclusion, .absent)
        XCTAssertEqual(result.body, try JevPayload.build(window, work: work))
        XCTAssertEqual(result.work, work)
        XCTAssertNil(result.inclusion.omissionNotice)
    }

    func testPlanActionIsSupplementaryAndPreservesEverySelectedObservationAndRule() throws {
        let work = try JevWorkContext(summary: "Goalong", applications: "Xcode", content: "Swift", procrastination: "Achats")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(work)
        let window = plannedActionWindow()
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: JevPayload.build(window, work: work)) as? [String: Any])
        let result = try JevPlannedActionPayload.build(window, work: work, action: "  Rédiger le guide\nÉcrire le premier exemple  ")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let baselineState = try XCTUnwrap(baseline["state"] as? [String: Any])
        let sentState = try XCTUnwrap(sent["state"] as? [String: Any])
        XCTAssertEqual(result.inclusion, .included)
        XCTAssertEqual(result.work.summary, "Goalong Current action: Rédiger le guide Écrire le premier exemple")
        XCTAssertEqual(result.work.applications, work.applications)
        XCTAssertEqual(result.work.content, work.content)
        XCTAssertEqual(result.work.procrastination, work.procrastination)
        XCTAssertEqual(sentState["goals"] as? String, result.work.summary)
        XCTAssertEqual(sentState["rows"] as? [[String]], baselineState["rows"] as? [[String]])
        XCTAssertEqual(try encoder.encode(work), before, "The saved criteria remain unchanged")
        XCTAssertLessThanOrEqual(result.work.byteCount, JevWorkContext.maximumBytes)
        XCTAssertLessThanOrEqual(result.body.count, JevPayload.maximumRequestBytes)
    }

    func testPlanActionNeverTruncatesFullCriteriaOrMultibyteActionToMakeRoom() throws {
        let work = try JevWorkContext(summary: String(repeating: "é", count: 400))
        let window = plannedActionWindow()
        let result = try JevPlannedActionPayload.build(window, work: work, action: "Écrire le guide")
        XCTAssertEqual(result.inclusion, .criteriaBudget)
        XCTAssertEqual(result.work, work)
        XCTAssertEqual(result.body, try JevPayload.build(window, work: work))
        XCTAssertNotNil(result.inclusion.omissionNotice)
        let longAction = try JevPlannedActionPayload.build(window, work: .empty, action: String(repeating: "🙂", count: 201))
        XCTAssertEqual(longAction.inclusion, .criteriaBudget)
        XCTAssertEqual(longAction.body, try JevPayload.build(window))
    }

    func testPlanActionIsOmittedRatherThanReducingEvidenceAtRequestLimit() throws {
        let window = plannedActionWindow(rich: true)
        let baseline = try JevPayload.build(window)
        let headroom = JevPayload.maximumRequestBytes - baseline.count
        XCTAssertGreaterThanOrEqual(headroom, 0)
        XCTAssertLessThan(headroom + 1 + "Current action: ".utf8.count, JevWorkContext.maximumBytes)
        let result = try JevPlannedActionPayload.build(window, work: .empty,
                                                      action: String(repeating: "z", count: headroom + 1))
        XCTAssertEqual(result.inclusion, .requestBudget)
        XCTAssertEqual(result.body, baseline)
        XCTAssertEqual(result.work, .empty)
        XCTAssertNotNil(result.inclusion.omissionNotice)
    }

    func testInvalidPlanActionNeverChangesAnOtherwiseUsableRequest() throws {
        let window = plannedActionWindow()
        let result = try JevPlannedActionPayload.build(window, work: .empty, action: "Guide\u{0000}invalide")
        XCTAssertEqual(result.inclusion, .invalidAction)
        XCTAssertEqual(result.body, try JevPayload.build(window))
        XCTAssertNotNil(result.inclusion.omissionNotice)
    }
}
