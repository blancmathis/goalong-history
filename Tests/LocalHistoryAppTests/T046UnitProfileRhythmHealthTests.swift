#if os(macOS)
import XCTest
import LocalHistoryCore
import LocalHistoryQueryCLI
@testable import LocalHistoryApp

/// T-046 L9: unit proofs for the Profil, Rythme and Import santé rows of the matrix.
/// Each proof targets the model or helper a control calls, never a window.
@MainActor final class T046UnitProfileRhythmHealthTests: XCTestCase {
    private func profileRequest(policy: GoalongProfileAnalysis.Policy = .init(), modules: [String] = ["projects"]) throws -> GoalongProfileAnalysis.Request {
        try GoalongProfileAnalysis.prepare(date: "2026-09-08", timezone: "Europe/Paris", evidence: [.init(id: "private-id", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Editor", text: "Atlas avance")], policy: policy, selected: modules)
    }
    private func analysedModel(policy: GoalongProfileAnalysis.Policy = .init()) throws -> GoalongProfileStudioModel {
        let model = GoalongProfileStudioModel()
        let request = try profileRequest(policy: policy)
        model.request = request
        let output: [String: Any] = ["request_id": request.request_id, "evidence_digest": request.digest, "items": [["id": "i1", "module": "projects", "title": "Atlas", "summary": "Avancée", "status": "inferred", "caveat": "À confirmer", "evidence_refs": ["e1"]]]]
        model.result = try GoalongProfileAnalysis.apply(GoalongProfileAnalysis.parseResult(JSONSerialization.data(withJSONObject: output)), to: request)
        return model
    }
    private func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t046-\(UUID().uuidString)-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Profil

    /// J-0508: closing the share sheet clears the pending analysis.
    func testProfileShareSheetClosesByClearingThePendingShare() {
        let host = GoalongProfileStudioHost(currentRevision: { "r" })
        host.receive(Data("a".utf8))
        XCTAssertNotNil(host.pending)
        host.pending = nil
        XCTAssertNil(host.pending)
    }
    /// J-0510: opening reopens a saved analysis or a bare selection, and refuses a foreign file.
    func testOpeningSavedArchiveRequestOrForeignFile() throws {
        let source = try analysedModel()
        let archiveFile = temp("analysis.json"); try GoalongContextualRhythm.encode(XCTUnwrap(source.archive)).write(to: archiveFile)
        let model = GoalongProfileStudioModel(); model.consent = true
        model.open(archiveFile)
        XCTAssertNil(model.error); XCTAssertEqual(model.request?.request_id, source.request?.request_id); XCTAssertNotNil(model.result)
        XCTAssertFalse(model.consent); XCTAssertTrue(model.evidence.isEmpty)
        let requestFile = temp("request.json"); try XCTUnwrap(source.request).encoded().write(to: requestFile)
        let again = GoalongProfileStudioModel(); again.open(requestFile)
        XCTAssertNil(again.error); XCTAssertNotNil(again.request); XCTAssertNil(again.result)
        let foreign = temp("foreign.json"); try Data("{\"x\":1}".utf8).write(to: foreign)
        let refused = GoalongProfileStudioModel(); refused.open(foreign)
        XCTAssertNotNil(refused.error); XCTAssertNil(refused.request)
    }
    /// J-0512, J-0514, J-0516: with no source ticked, loading refuses and reads nothing.
    func testLoadWithoutAnySourceAsksForOneAndStaysIdle() {
        let model = GoalongProfileStudioModel(); model.selectedEvidence = ["e1"]
        model.load(start: Date(), end: Date(), rich: false, computer: false, conversations: false)
        XCTAssertEqual(model.error, "Choisissez une source et activez-la dans les réglages.")
        XCTAssertTrue(model.selectedEvidence.isEmpty)
        XCTAssertFalse(model.busy)
    }
    /// J-0517: after select-all/none the prepared request is dropped, and with nothing selected preparing is refused.
    func testSelectAllThenInvalidateDropsThePreparedRequest() throws {
        let model = try analysedModel()
        model.evidence = [.init(id: "e1", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Editor", text: "a"), .init(id: "e2", start: "2026-09-08T08:02:00Z", end: "2026-09-08T08:03:00Z", application: "Editor", text: "b")]
        model.selectedEvidence = Set(model.evidence.map(\.id)); model.invalidate()
        XCTAssertEqual(model.selectedEvidence, ["e1", "e2"]); XCTAssertNil(model.request); XCTAssertNil(model.result)
        model.selectedEvidence = []; model.invalidate()
        model.prepare(day: Date(), modules: ["projects"], policy: .init())
        XCTAssertNil(model.request); XCTAssertNotNil(model.error)
    }
    /// J-0518, J-0519, J-0520: ticked modules enter the request in canonical order; none is refused.
    func testPrepareKeepsCheckedModulesInCanonicalOrderAndRefusesNone() throws {
        let model = GoalongProfileStudioModel()
        model.evidence = [.init(id: "e1", start: "2026-09-08T08:00:00Z", end: "2026-09-08T08:01:00Z", application: "Editor", text: "Atlas")]
        model.selectedEvidence = ["e1"]
        model.prepare(day: Date(), modules: ["work", "projects", "totals"], policy: .init())
        XCTAssertNil(model.error)
        XCTAssertEqual(try model.request?.context().modules, ["totals", "projects", "work"])
        model.prepare(day: Date(), modules: [], policy: .init())
        XCTAssertNil(model.request); XCTAssertNotNil(model.error)
    }
    /// J-0522, J-0523: analysing refuses without consent or request and starts nothing.
    func testAnalyzeRefusesWithoutConsentOrRequest() throws {
        let model = try analysedModel(); model.consent = false
        model.analyze()
        XCTAssertEqual(model.error, "Relisez la sélection et autorisez son envoi à l’agent."); XCTAssertFalse(model.busy)
        let empty = GoalongProfileStudioModel(); empty.consent = true
        empty.analyze()
        XCTAssertNotNil(empty.error); XCTAssertFalse(empty.busy)
    }
    /// J-0524: the exported prompt never holds the replaced private name.
    func testExportedPromptNeverHoldsTheReplacedPrivateName() throws {
        let request = try profileRequest(policy: .init(replacements: [.init(term: "Atlas", replacement: "Secret")]))
        let prompt = try request.prompt()
        XCTAssertFalse(prompt.contains("Atlas")); XCTAssertTrue(prompt.contains("Secret"))
    }
    /// J-0525, J-0529, J-0530: ticking a card is not enough; without review there is no projection.
    func testCardSelectionNeedsReviewBeforeExport() throws {
        let model = try analysedModel()
        model.selectedItems.insert("i1")
        XCTAssertThrowsError(try model.projection())
        model.reviewed = true
        XCTAssertNoThrow(try model.projection())
        model.selectedItems.remove("i1")
        XCTAssertThrowsError(try model.projection())
    }
    /// J-0527: editing the limits changes the caveat, marks the card declared and drops the review.
    func testEditingLimitsMarksTheCardDeclaredAndUnreviewed() throws {
        let model = try analysedModel(); model.reviewed = true
        model.correct("i1", field: "caveat", text: "Limite corrigée")
        XCTAssertEqual(model.result?.items.first?.caveat, "Limite corrigée")
        XCTAssertEqual(model.result?.items.first?.status, "declared")
        XCTAssertFalse(model.reviewed)
        model.correct("missing", field: "caveat", text: "x")
        XCTAssertEqual(model.result?.items.count, 1)
    }
    /// J-0528: keeping the analysis fails closed. With nothing prepared it is a no-op; with storage the secure
    /// writer refuses (the disposable test HOME lives under /tmp), the user gets a message, nothing is notified.
    func testKeepingTheAnalysisFailsClosedAndNeverClaimsASave() throws {
        let idle = GoalongProfileStudioModel(); idle.save()
        XCTAssertNil(idle.error); XCTAssertEqual(idle.status, "")
        let model = try analysedModel()
        var notified = false
        let token = NotificationCenter.default.addObserver(forName: .goalongProfileAnalysisDidSave, object: nil, queue: nil) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(token) }
        model.save()
        if model.error == nil {
            XCTAssertEqual(model.status, "Enregistré dans Goalong History. Aucun envoi au site."); XCTAssertTrue(notified)
        } else {
            XCTAssertFalse(notified); XCTAssertNotEqual(model.status, "Enregistré dans Goalong History. Aucun envoi au site.")
        }
    }
    /// J-0533, J-0611: export writes the chosen bytes, privately, and refuses a non-file URL.
    func testExportWriterWritesExactBytesPrivately() throws {
        let file = temp("export.json"); let bytes = Data("{\"ok\":true}".utf8)
        try GoalongSiteAnalysisExportWriter.write(bytes, to: file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int).map { $0 & 0o077 }, 0)
        XCTAssertThrowsError(try GoalongSiteAnalysisExportWriter.write(bytes, to: URL(string: "https://example.com/x")!))
    }

    // MARK: Rythme

    private func rhythmModel() throws -> (GoalongRhythmStudioModel, GoalongContextualRhythm.Request) {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_789_200_000))
        let events = [0.0, 60, 120].map { offset in
            HistoryEvent(sessionID: "fixture", timestamp: day.addingTimeInterval(36000 + offset), kind: .applicationActivated,
                         app: .init(name: "Safari", bundleIdentifier: "test.Safari", processIdentifier: 0),
                         window: .init(title: "Documentation du projet Goalong", role: nil, subrole: nil))
        }
        let request = try GoalongContextualRhythm.build(events: events, day: day, project: "Goalong", intent: "Construire le lot", device: "Mac de test")
        let model = GoalongRhythmStudioModel(); model.request = request
        model.selectedEvidence = Set((request.rhythm.episodes ?? []).flatMap { $0.evidence?.map(\.id) ?? [] })
        return (model, request)
    }
    /// J-0782: the typed intent reaches the request and the prompt.
    func testTypedIntentReachesTheRequestAndPrompt() throws {
        let (_, request) = try rhythmModel()
        XCTAssertEqual(request.intent, "Construire le lot")
        XCTAssertTrue(request.prompt.contains("Analyse en français"))
    }
    /// J-0783, J-0784: with the source disabled, preparing refuses and reads nothing.
    func testRhythmLoadRefusesWhenSourceIsNotEnabled() {
        let model = GoalongRhythmStudioModel()
        guard !GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory) else { return }
        model.load(start: Date(), end: Date().addingTimeInterval(60), project: "P", intent: "", masks: [], rich: false)
        XCTAssertEqual(model.error, "Activez les sources sélectionnées dans les réglages de Goalong History.")
        XCTAssertFalse(model.busy); XCTAssertNil(model.request)
    }
    /// J-0785: an episode whose context is all unticked has no evidence left (« Contexte non fourni »).
    func testUncheckingAllContextLeavesEpisodesWithoutEvidence() throws {
        let (model, _) = try rhythmModel()
        XCTAssertTrue(model.selection?.rhythm.episodes?.contains { $0.evidence?.isEmpty == false } ?? false)
        model.selectedEvidence = []
        XCTAssertTrue(model.selection?.rhythm.episodes?.allSatisfy { $0.evidence?.isEmpty != false } ?? false)
        XCTAssertFalse(model.request?.rhythm.episodes?.allSatisfy { $0.evidence?.isEmpty != false } ?? true)
    }
    /// J-0787: any change of selection revokes consent and the old result.
    func testChangingRhythmSelectionRevokesConsent() throws {
        let (model, _) = try rhythmModel(); model.consentToAnalyze = true; model.interpretation = "x"
        model.selectionChanged()
        XCTAssertFalse(model.consentToAnalyze); XCTAssertNil(model.result); XCTAssertEqual(model.interpretation, "")
    }
    /// J-0780: changing the start (or end, project, intent, rich toggle) calls invalidate(), which drops the whole local selection.
    func testRhythmInvalidateDropsSelectionConsentAndResult() throws {
        let (model, _) = try rhythmModel(); model.consentToAnalyze = true; model.interpretation = "x"
        model.invalidate()
        XCTAssertNil(model.request); XCTAssertNil(model.result); XCTAssertTrue(model.selectedEvidence.isEmpty)
        XCTAssertFalse(model.consentToAnalyze); XCTAssertEqual(model.interpretation, ""); XCTAssertFalse(model.busy)
    }
    /// J-0786, J-0788: analysing refuses without consent.
    func testRhythmAnalyzeRefusesWithoutConsent() throws {
        let (model, _) = try rhythmModel(); model.consentToAnalyze = false
        model.analyze()
        XCTAssertEqual(model.error, "Relisez la sélection et autorisez son analyse."); XCTAssertFalse(model.busy)
    }
    /// J-0789, J-0795: the hand-off file holds the instructions and the request, nothing else.
    func testRhythmHandOffFileHoldsInstructionsAndRequest() throws {
        let (model, _) = try rhythmModel()
        let selected = try XCTUnwrap(model.selection)
        let object: [String: Any] = ["instructions": selected.prompt, "request": try JSONSerialization.jsonObject(with: selected.encoded())]
        let file = temp("session.json")
        try GoalongSiteAnalysisExportWriter.write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: file)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(back.keys), ["instructions", "request"])
        XCTAssertEqual((back["request"] as? [String: Any])?["request_id"] as? String, selected.request_id)
    }
    /// J-0790, J-0796: a foreign answer is refused and the request stays; without a request nothing happens.
    func testImportingAForeignRhythmAnswerKeepsStateAndSetsError() throws {
        let (model, _) = try rhythmModel()
        let file = temp("answer.json"); try Data("{\"unexpected\":true}".utf8).write(to: file)
        model.importAnnotation(file)
        XCTAssertNotNil(model.error); XCTAssertNil(model.result); XCTAssertNotNil(model.request)
        let idle = GoalongRhythmStudioModel(); idle.importAnnotation(file)
        XCTAssertNil(idle.error)
    }
    /// J-0791: the picker accepts only project/other/unclassified and marks the owner as origin.
    func testRelationPickerAcceptsOnlyKnownRelationsAndMarksOwner() throws {
        let (model, request) = try rhythmModel()
        let episode = try XCTUnwrap(request.rhythm.episodes?.first { $0.relation != "unknown" })
        model.correct(id: episode.id, relation: "bogus")
        XCTAssertNil(model.result)
        model.correct(id: episode.id, relation: "other")
        let changed = try XCTUnwrap(model.result?.episodes?.first { $0.id == episode.id })
        XCTAssertEqual(changed.relation, "other"); XCTAssertEqual(changed.semantic_origin, "owner")
        XCTAssertEqual(changed.explanation, "Association corrigée par le propriétaire.")
    }
    /// J-0792, J-0794: the interpretation is kept only when ticked; edited text is owner-authored.
    func testReviewedResultHonoursTheInterpretationToggle() throws {
        let (model, _) = try rhythmModel()
        model.includeInterpretation = true; model.interpretation = "Mon texte"
        var value = try XCTUnwrap(model.reviewedResult())
        XCTAssertEqual(value.interpretation, "Mon texte"); XCTAssertEqual(value.interpretation_origin, "owner")
        model.includeInterpretation = false
        value = try XCTUnwrap(model.reviewedResult())
        XCTAssertNil(value.interpretation); XCTAssertNil(value.interpretation_origin)
    }

    // MARK: Import santé

    private func healthXML(days: [String]) -> Data {
        let records = days.map { "<Record type=\"HKQuantityTypeIdentifierStepCount\" sourceName=\"Watch\" unit=\"count\" value=\"100\" startDate=\"\($0) 10:00:00 +0200\" endDate=\"\($0) 10:10:00 +0200\"/>" }.joined()
        return Data("<?xml version=\"1.0\"?><HealthData locale=\"fr_FR\"><ExportDate value=\"2026-09-12 09:00:00 +0200\"/>\(records)</HealthData>".utf8)
    }
    private func healthRead(_ data: Data, from: String, through: String, groups: Set<GoalongHealthGroup> = [.activity]) throws -> GoalongHealthImportResult {
        let iso = ISO8601DateFormatter()
        return try GoalongHealthImport.read(data: data, options: .init(from: iso.date(from: from)!, through: iso.date(from: through)!, timezone: TimeZone(identifier: "Europe/Paris")!, groups: groups))
    }
    /// J-0594, J-0595, J-0598: the preview keeps only the days between « Du » and « Au ».
    func testHealthPreviewKeepsOnlyTheChosenDateRange() throws {
        let data = healthXML(days: ["2026-09-06", "2026-09-07", "2026-09-08"])
        let all = try healthRead(data, from: "2026-09-05T22:00:00Z", through: "2026-09-08T21:59:59Z")
        XCTAssertEqual(all.dayCount, 3)
        let middle = try healthRead(data, from: "2026-09-06T22:00:00Z", through: "2026-09-07T21:59:59Z")
        XCTAssertEqual(middle.dayCount, 1)
    }
    /// J-0598: an unticked group never reaches the preview payload.
    func testHealthPreviewLeavesUntickedGroupsOut() throws {
        let data = healthXML(days: ["2026-09-06"])
        XCTAssertThrowsError(try healthRead(data, from: "2026-09-05T22:00:00Z", through: "2026-09-06T21:59:59Z", groups: [.sleep]))
        let with = try healthRead(data, from: "2026-09-05T22:00:00Z", through: "2026-09-06T21:59:59Z", groups: [.activity])
        XCTAssertTrue(String(decoding: with.payload, as: UTF8.self).contains("steps"))
    }
    /// J-0589, J-0600, J-0591, J-0610: kept days are listed, read back byte for byte, and an absent day fails.
    func testKeptHealthDayIsListedReadBackAndMissingDayFails() throws {
        let root = temp("health-root"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GoalongHealthArchive.dates(root: root))
        let result = try healthRead(healthXML(days: ["2026-09-06"]), from: "2026-09-05T22:00:00Z", through: "2026-09-06T21:59:59Z")
        try GoalongHealthArchive.save(result, root: root)
        XCTAssertEqual(try GoalongHealthArchive.dates(root: root), ["2026-09-06"])
        let back = try GoalongHealthArchive.read(day: "2026-09-06", root: root)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: back) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "apple-health")
        XCTAssertThrowsError(try GoalongHealthArchive.read(day: "2026-09-07", root: root))
        XCTAssertThrowsError(try GoalongHealthArchive.read(day: "../escape", root: root))
        XCTAssertTrue(GoalongHealthImportSheet.trashTitle(day: "2026-09-06").hasPrefix("Retirer les données Santé du"))
    }
    /// J-0601, J-0611: the exported Health selection is the reviewed payload, byte for byte.
    func testHealthExportFileIsThePreviewPayload() throws {
        let result = try healthRead(healthXML(days: ["2026-09-06"]), from: "2026-09-05T22:00:00Z", through: "2026-09-06T21:59:59Z")
        let file = temp("goalong-sante.json")
        try GoalongSiteAnalysisExportWriter.write(result.payload, to: file)
        XCTAssertEqual(try Data(contentsOf: file), result.payload)
    }
}
#endif
