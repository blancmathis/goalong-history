#if os(macOS)
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// H17 N2: a successful import must clear the red error left by an earlier failure.
@MainActor final class GoalongImportClearsErrorTests: XCTestCase {
    private func write(_ object: Any) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-import-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testProfileImportSuccessClearsAnEarlierError() throws {
        let model = GoalongProfileStudioModel()
        let request = try GoalongProfileAnalysis.prepare(date: "2026-09-08", timezone: "Europe/Paris", evidence: [.init(id: "private-id", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Editor", text: "Atlas")], policy: .init(), selected: ["projects"])
        model.request = request
        model.importResult(try write(["unexpected": true]))
        XCTAssertNotNil(model.error)
        model.importResult(try write(["request_id": request.request_id, "evidence_digest": request.digest, "items": [["id": "i1", "module": "projects", "title": "Atlas", "summary": "Avancée", "status": "inferred", "caveat": "À confirmer", "evidence_refs": ["e1"]]]]))
        XCTAssertNotNil(model.result)
        XCTAssertNil(model.error)
    }

    func testRhythmImportSuccessClearsAnEarlierError() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_789_200_000))
        let events = [0.0, 60, 120].map { offset in
            HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(36000 + offset), kind: .applicationActivated,
                         app: .init(name: "Safari", bundleIdentifier: "test.Safari", processIdentifier: 0),
                         window: .init(title: "Documentation du projet Goalong", role: nil, subrole: nil))
        }
        let request = try GoalongContextualRhythm.build(events: events, day: day, project: "Goalong", intent: "Construire", device: "Mac de test")
        let model = GoalongRhythmStudioModel()
        model.request = request
        let episodes = request.rhythm.episodes ?? []
        model.selectedEvidence = Set(episodes.flatMap { $0.evidence?.map(\.id) ?? [] })
        model.importAnnotation(try write(["unexpected": true]))
        XCTAssertNotNil(model.error)
        model.importAnnotation(try write([
            "request_id": request.request_id, "evidence_digest": request.digest,
            "episodes": episodes.map { ["id": $0.id, "relation": "project", "subject": "Sujet", "explanation": "Titre observé.", "evidence_refs": $0.evidence?.map(\.id) ?? []] },
            "interpretation": "Travail sur le projet.", "interpretation_refs": episodes.map(\.id),
        ]))
        XCTAssertNotNil(model.result)
        XCTAssertNil(model.error)
    }
}
#endif
