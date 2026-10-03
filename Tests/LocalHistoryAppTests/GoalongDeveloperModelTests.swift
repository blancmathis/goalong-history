#if os(macOS)
import XCTest
import Foundation
import LocalHistoryCore
import AgentActivity
@testable import LocalHistoryApp

final class GoalongDeveloperModelTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").appendingPathComponent("goalong-developer-ui-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    @MainActor func testProjectSelectionAndConsentAPIsRemainIndependent() async throws {
        let root = try fixture(), consents = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("data/capability-consent.json"))
        let model = GoalongDeveloperModel(root: root.appendingPathComponent("data"), consents: consents)
        XCTAssertEqual(model.status, .disabled)
        try model.addProject(root.appendingPathComponent("repo")); XCTAssertEqual(model.selectedProjects.count, 1)
        let restored = GoalongDeveloperModel(root: root.appendingPathComponent("data"), consents: consents)
        XCTAssertEqual(restored.selectedProjects.count, 1)
        XCTAssertFalse(consents.isEnabled(.developerActivity))
        XCTAssertTrue(model.setEnabled(true)); XCTAssertFalse(consents.isEnabled(.aiConversations))
        await model.refresh(day: Date()); XCTAssertEqual(model.value?.selectedProjects.count, 1)
        XCTAssertEqual(model.value?.t3.status, .disabled)
        try model.removeProject(id: model.selectedProjects[0].id); XCTAssertTrue(model.selectedProjects.isEmpty)
        XCTAssertTrue(model.setEnabled(false)); XCTAssertNil(model.value)
    }
    func testRecapRequiresItsOwnFlagAndHonoursExclusionsBeforeReading() throws {
        let root = try fixture(), consents = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("data/capability-consent.json"))
        var selection = GoalongAnalysisSelection(), privacy = GoalongPrivacyPolicy()
        XCTAssertNil(try GoalongDeveloperRecap.build(day: Date(), selection: selection, agents: .init(day: Date()), privacy: privacy, root: root, consents: consents))
        selection.developer = true; privacy.domains = ["example.invalid"]
        let rendered = try GoalongDeveloperRecap.build(day: Date(), selection: selection, agents: .init(day: Date()), privacy: privacy, root: root, consents: consents)
        XCTAssertTrue(rendered?.contains("omis") == true)
        let legacy = Data("{\"version\":1,\"reviewed\":false,\"computer\":false,\"screenTime\":false,\"conversations\":false,\"details\":false,\"revision\":\"legacy\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(GoalongAnalysisSelection.self, from: legacy).developer)
    }
    func testDeveloperOnlySourceCountsPermitARecapWithoutMacEvidence() throws {
        let day = Date(), activity = ActivityAnalysisEngine.analyze(events: [], day: day)
        let counts = ChatGPTRecapSourceCounts(localEvents: 0, activeMinutes: 0, semanticSnapshots: 0,
            screenTimeDevices: 0, screenTimeApplications: 0, agentCaptures: 0, agentMessages: 0,
            importedChatMessages: 0, computerHistoryEpisodes: nil, computerHistoryResources: nil,
            workflowSuggestions: nil, developerProjects: 1)
        let context = ChatGPTRecapContext(day: day, activity: activity, computerHistory: nil, screenTime: nil,
            agentActivity: .init(day: day), importedChats: [], localJournalSourceAbsent: true,
            renderedData: "Développement", sourceCounts: counts, digest: "fixture")
        XCTAssertTrue(context.hasMeaningfulData)
        XCTAssertEqual(try JSONDecoder().decode(ChatGPTRecapSourceCounts.self, from: JSONEncoder().encode(counts)), counts)
    }
    func testCounterJournalsAreRemovedWithDerivedDayDeletion() throws {
        let root = try fixture(), day = Calendar.current.startOfDay(for: Date()), store = GoalongDeveloperStore(root: root.appendingPathComponent("data"))
        let project = GoalongDeveloperProject(root: root.appendingPathComponent("repo"))
        try store.append([.init(projectID: project.id, start: day, modifiedFiles: 3, estimated: false, lastEventID: 7)], day: day)
        _ = try DerivedHistoryCleaner(rootDirectory: store.root, codexMemoryDirectory: store.root.appendingPathComponent("codex-memory")).prepareDeletion(days: [day]).execute()
        XCTAssertEqual(store.read(day: day).status, .noData)
    }
    func testRealFileEventsWriteOnlyCountsAndStopDuringPause() throws {
        let root = try fixture(), store = GoalongDeveloperStore(root: root.appendingPathComponent("data"))
        try store.add(root.appendingPathComponent("repo"))
        let monitor = GoalongDeveloperFileMonitor(root: store.root)
        monitor.start(replayHistory: false); defer { monitor.stop() }
        XCTAssertEqual(monitor.snapshotStatus(), .ready)
        let file = root.appendingPathComponent("repo/example.swift")
        try Data("FILE-CONTENT-NEVER-READ".utf8).write(to: file)
        let deadline = Date().addingTimeInterval(15)
        repeat {
            monitor.synchronizeForTesting()
            if store.read(day: Date()).fileChanges > 0 { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        let recorded = store.read(day: Date())
        XCTAssertGreaterThan(recorded.fileChanges, 0, "Watcher status: \(monitor.snapshotStatus())")
        let directory = store.root.appendingPathComponent("developer")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let raw = try files.map { try String(contentsOf: $0) }.joined()
        XCTAssertFalse(raw.contains("example.swift")); XCTAssertFalse(raw.contains("FILE-CONTENT")); XCTAssertFalse(raw.contains(root.path))
        var pause = GoalongGlobalPause(); pause.paused = true
        try GoalongDeveloperFileIO.write(JSONEncoder().encode(pause), name: "global-pause.json", directory: store.root)
        try Data("paused".utf8).write(to: root.appendingPathComponent("repo/paused.swift"))
        monitor.synchronizeForTesting(); XCTAssertEqual(store.read(day: Date()).fileChanges, recorded.fileChanges)
        XCTAssertFalse(GoalongDeveloperFileMonitor.permits(relativePath: "node_modules/pkg/index.js"))
        XCTAssertFalse(GoalongDeveloperFileMonitor.permits(relativePath: "src/.DS_Store"))
        XCTAssertTrue(GoalongDeveloperFileMonitor.permits(relativePath: "Sources/file.swift"))
    }
}
#endif
