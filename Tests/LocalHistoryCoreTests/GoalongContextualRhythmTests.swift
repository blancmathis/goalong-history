import XCTest
@testable import LocalHistoryCore

final class GoalongContextualRhythmTests: XCTestCase {
    private let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_789_200_000))
    func source() throws -> GoalongContextualRhythm.Request {
        let data: [(Double,String,String)] = [(0,"Safari","Documentation du projet Goalong"),(60,"Safari","Conversation personnelle"),(60.5,"Safari","Documentation du projet Goalong"),(120,"Safari","Documentation du projet Goalong"),(180,"Codex","Goalong implementation"),(240,"Codex","Goalong implementation")]
        let events = data.map { time, app, title in HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(36000+time), kind: .applicationActivated,
            app: .init(name: app, bundleIdentifier: "test.\(app)", processIdentifier: 0), window: .init(title: title, role: nil, subrole: nil)) }
        return try GoalongContextualRhythm.build(events: events, day: day, project: "Goalong", intent: "Construire le projet", device: "Mac de test")
    }
    func annotate(_ r: GoalongContextualRhythm.Request) -> GoalongContextualRhythm.Annotation {
        .init(request_id: r.request_id, evidence_digest: r.digest, episodes: (r.rhythm.episodes ?? []).map { e in
            .init(id: e.id, relation: e.evidence?.first?.text.contains("personnelle") == true ? "other" : "project", subject: "Sujet décrit par le contexte", explanation: "Association proposée à partir du titre observé.", evidence_refs: e.evidence?.map(\.id) ?? [])
        }, interpretation: "Un bref passage à une conversation personnelle apparaît entre les recherches du projet.", interpretation_refs: r.rhythm.episodes?.map(\.id) ?? [])
    }
    func testSameApplicationCanChangeSubjectWithoutChangingMeasuredTimes() throws {
        let r = try source()
        XCTAssertTrue(r.rhythm.episodes!.allSatisfy { $0.relation == "unclassified" })
        let applied = try GoalongContextualRhythm.apply(annotate(r), to: r)
        XCTAssertEqual(applied.brief_consultations, 1)
        XCTAssertEqual(applied.brief_consultation_ms, 500)
        XCTAssertEqual(applied.project_ms, 239500)
        XCTAssertEqual(applied.episodes!.map(\.duration_ms), r.rhythm.episodes!.map(\.duration_ms))
        XCTAssertEqual(applied.episodes!.map(\.offset_ms), r.rhythm.episodes!.map(\.offset_ms))
        XCTAssertEqual(applied.episodes![1].application, "Safari")
        XCTAssertEqual(applied.episodes![1].relation, "other")
    }
    func testStaleRequestsFabricatedEvidenceAndNewFieldsAreRejected() throws {
        let r = try source(); var a = annotate(r)
        a.evidence_digest = "stale"; XCTAssertThrowsError(try GoalongContextualRhythm.apply(a, to:r))
        a = annotate(r); a.episodes[0].evidence_refs = ["invented"]; XCTAssertThrowsError(try GoalongContextualRhythm.apply(a, to:r))
        a = annotate(r); a.episodes.removeLast(); XCTAssertThrowsError(try GoalongContextualRhythm.apply(a, to:r))
        a = annotate(r); a.episodes[0].evidence_refs = []; XCTAssertThrowsError(try GoalongContextualRhythm.apply(a, to:r))
        var json = try JSONSerialization.jsonObject(with: GoalongContextualRhythm.encode(annotate(r))) as! [String:Any]
        json["project_ms"] = 9000
        XCTAssertThrowsError(try GoalongContextualRhythm.parseAnnotation(JSONSerialization.data(withJSONObject:json)))
    }
    func testPrivateContextsAndCollectionGapsNeverBecomeProjectEvidence() throws {
        let events = [
            HistoryEvent(sessionID:"fixture",timestamp:day,kind:.applicationActivated,app:.init(name:"Secret",bundleIdentifier:"secret.app",processIdentifier:0),window:.init(title:"Sensitive task",role:nil,subrole:nil)),
            HistoryEvent(sessionID:"fixture",timestamp:day.addingTimeInterval(30),kind:.systemSleep),
            HistoryEvent(sessionID:"fixture",timestamp:day.addingTimeInterval(60),kind:.applicationActivated,app:.init(name:"Safari",bundleIdentifier:nil,processIdentifier:0)),
            HistoryEvent(sessionID:"fixture",timestamp:day.addingTimeInterval(90),kind:.applicationActivated,app:.init(name:"Safari",bundleIdentifier:nil,processIdentifier:0)),
        ]
        let r=try GoalongContextualRhythm.build(events:events,day:day,project:"Travail",intent:"",device:"Mac",masks:[" secret.app "])
        let json=String(decoding:try r.encoded(),as:UTF8.self)
        XCTAssertFalse(json.contains("Sensitive task")); XCTAssertFalse(json.contains("Secret"))
        XCTAssertEqual(r.rhythm.episodes?[1].relation,"unknown")
        XCTAssertEqual(r.rhythm.longest_project_ms,0)
        var a=GoalongContextualRhythm.Annotation(request_id:r.request_id,evidence_digest:r.digest,episodes:r.rhythm.episodes!.map { .init(id:$0.id,relation:$0.relation,subject:"",explanation:"",evidence_refs:[]) },interpretation:"",interpretation_refs:[])
        a.episodes[1].relation="project"
        XCTAssertThrowsError(try GoalongContextualRhythm.apply(a,to:r))
    }
}
