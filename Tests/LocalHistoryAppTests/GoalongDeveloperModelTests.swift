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
    func testRecapListsMostActiveProjectsFirstAndCountsQuietOnes() throws {
        let root = try fixture(), day = Calendar.current.startOfDay(for: Date())
        let projects = try ["calm", "small", "busy"].map { name -> GoalongDeveloperProject in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name + "/.git"), withIntermediateDirectories: true)
            return GoalongDeveloperProject(root: root.appendingPathComponent(name), name: name)
        }
        let buckets = [(projects[1], 2), (projects[2], 9)].map { GoalongFileModificationBucket(projectID: $0.0.id, start: day, modifiedFiles: $0.1, estimated: false, lastEventID: 1) }
        let value = GoalongDeveloperDay(day: day, t3: T3CodeMetadataReader.read(day: day, enabled: false, shouldContinue: { true }),
            agents: GoalongAgentProjectGrouping.group(.init(day: day), t3: nil, enabled: false), git: [],
            files: .init(status: .ready, buckets: buckets), selectedProjects: projects, suggestions: [], developerStatus: .ready)
        let lines = try GoalongDeveloperRecap.render(value).components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("busy") || $0.hasPrefix("small") || $0.hasPrefix("calm") }.map { String($0.prefix(4)) }, ["busy", "smal"])
        XCTAssertEqual(lines.last, "1 projet suivi sans activité observée ce jour-là.")
    }
    func testCodeDayKeepsActiveProjectsAndMeasuresTimeWithoutTheUser() throws {
        let root = try fixture(), day = Calendar.current.startOfDay(for: Date())
        let projects = try ["calm", "busy"].map { name -> GoalongDeveloperProject in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name + "/.git"), withIntermediateDirectories: true)
            return GoalongDeveloperProject(root: root.appendingPathComponent(name), name: name)
        }
        let value = GoalongDeveloperDay(day: day, t3: T3CodeMetadataReader.read(day: day, enabled: false, shouldContinue: { true }),
            agents: GoalongAgentProjectGrouping.group(.init(day: day), t3: nil, enabled: false), git: [],
            files: .init(status: .ready, buckets: [.init(projectID: projects[1].id, start: day, modifiedFiles: 4, estimated: false, lastEventID: 1)]),
            selectedProjects: projects, suggestions: [], developerStatus: .ready)
        let code = GoalongCodeDay(value)
        XCTAssertEqual(code.projects.map(\.name), ["busy"])
        XCTAssertEqual(code.fileChanges, 4); XCTAssertTrue(code.followsProjects); XCTAssertEqual(code.followedProjects, 2)
        XCTAssertEqual(code.caption, "1\u{00A0}projet · 4\u{00A0}modifications de fichiers")
        let running = [DateInterval(start: day, duration: 600), DateInterval(start: day.addingTimeInterval(300), duration: 600)]
        let present = [DateInterval(start: day.addingTimeInterval(120), duration: 180)]
        XCTAssertEqual(GoalongIntervals.seconds(running, outside: present), 720)
    }
    func testActiveProjectsSentenceSaysWhichConversationsHaveNoProject() {
        func project(_ name: String, _ conversations: Int) -> GoalongCodeDay.Project {
            var row = GoalongCodeDay.Project(id: name, name: name); row.conversations = conversations; return row
        }
        let projects = [project("atlas", 3), project("onboarding", 1)]
        let mixed = GoalongCodeDay(projects: projects, unassignedConversations: 1, followsProjects: false, followedProjects: 0)
        XCTAssertEqual(mixed.activeProjectsSentence, "2\u{00A0}projets actifs ce jour-là : 5\u{00A0}conversations d’agents, dont 1\u{00A0}sans projet.")
        let allAssigned = GoalongCodeDay(projects: projects, unassignedConversations: 0, followsProjects: false, followedProjects: 0)
        XCTAssertEqual(allAssigned.activeProjectsSentence, "2\u{00A0}projets actifs ce jour-là : 4\u{00A0}conversations d’agents.")
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
    private func waitFor(_ monitor: GoalongDeveloperFileMonitor, seconds: TimeInterval = 15, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            monitor.synchronizeForTesting()
            if done() { return }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
    }
    func testIgnoredPathStormCausesNoDayFileRead() throws {
        let root = try fixture(), store = GoalongDeveloperStore(root: root.appendingPathComponent("data"))
        try store.add(root.appendingPathComponent("repo"))
        let reads = NSLock(); var count = 0
        let monitor = GoalongDeveloperFileMonitor(root: store.root, readDay: { store, day in
            reads.lock(); count += 1; reads.unlock(); return store.read(day: day)
        })
        monitor.start(replayHistory: false); defer { monitor.stop() }
        monitor.synchronizeForTesting()
        let base = root.appendingPathComponent("repo").resolvingSymlinksInPath().path
        let flag = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        // A bucket already written makes every later batch eligible for a deletion re-check read.
        monitor.queueForTesting.sync { monitor.consume(paths: ["\(base)/Sources/first.swift"], flags: [flag], ids: [1]) }
        reads.lock(); count = 0; reads.unlock()
        let paths = (0..<10_000).map { "\(base)/.build/arm64/debug/obj\($0).o" }
        monitor.queueForTesting.sync {
            monitor.consume(paths: paths, flags: Array(repeating: flag, count: paths.count), ids: (2...10_001).map { FSEventStreamEventId($0) })
        }
        reads.lock(); XCTAssertEqual(count, 0, "Ignored paths must not reread the day file"); reads.unlock()
        monitor.queueForTesting.sync {
            monitor.consume(paths: ["\(base)/Sources/a.swift"], flags: [flag], ids: [10_002])
        }
        reads.lock(); XCTAssertGreaterThan(count, 0, "A useful path still reaches the store"); reads.unlock()
    }
    func testExclusionPathsAreCappedAtEightAndSkipMissingFolders() {
        let roots = (0..<5).map { "/r\($0)" }
        let all = GoalongDeveloperFileMonitor.exclusionPaths(roots: roots, exists: { _ in true })
        XCTAssertEqual(all.count, 8); XCTAssertTrue(all.allSatisfy { $0.hasPrefix("/") })
        XCTAssertEqual(GoalongDeveloperFileMonitor.exclusionPaths(roots: ["/a"], exists: { $0 == "/a/.build" }), ["/a/.build"])
        XCTAssertTrue(GoalongDeveloperFileMonitor.exclusionPaths(roots: ["/a"], exists: { _ in false }).isEmpty)
    }
    func testMonitorIgnoresItsOwnDataAndWritesOnlyChangedCounts() throws {
        // The data folder sits inside the followed repository, like a dotfiles repo at ~.
        let root = try fixture(), store = GoalongDeveloperStore(root: root.appendingPathComponent("repo/data"))
        try store.add(root.appendingPathComponent("repo"))
        let monitor = GoalongDeveloperFileMonitor(root: store.root)
        monitor.start(replayHistory: false); defer { monitor.stop() }
        let file = root.appendingPathComponent("repo/example.swift")
        for index in 0..<3 {
            try Data("edit \(index)".utf8).write(to: file)
            waitFor(monitor, seconds: 5) { store.read(day: Date()).fileChanges > 0 }
        }
        for _ in 0..<5 { monitor.synchronizeForTesting(); Thread.sleep(forTimeInterval: 0.2) }
        let recorded = store.read(day: Date())
        XCTAssertEqual(recorded.fileChanges, 1, "Watcher status: \(monitor.snapshotStatus())")
        let journal = try FileManager.default.contentsOfDirectory(at: store.root.appendingPathComponent("developer"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.map { try String(contentsOf: $0) }.joined()
        XCTAssertEqual(journal.split(separator: "\n").count, recorded.buckets.count)
        XCTAssertFalse(GoalongDeveloperFileMonitor.ownDataRoots([store.root]).isEmpty)
    }
    @MainActor func testFullDayFileStopsTheWatcherVisiblyAndRecovers() async throws {
        let root = try fixture(), data = root.appendingPathComponent("data"), store = GoalongDeveloperStore(root: data)
        try store.add(root.appendingPathComponent("repo"))
        let other = String(repeating: "a", count: 64), day = Calendar.current.startOfDay(for: Date())
        try store.append([.init(projectID: other, start: day, modifiedFiles: 1, estimated: false, lastEventID: 1)], day: day)
        let journal = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: data.appendingPathComponent("developer"), includingPropertiesForKeys: nil).first)
        let handle = try FileHandle(forWritingTo: journal); try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 10, count: 2_097_152 - 200)); try handle.close()
        let monitor = GoalongDeveloperFileMonitor(root: data)
        monitor.start(replayHistory: false); defer { monitor.stop() }
        try Data("one".utf8).write(to: root.appendingPathComponent("repo/one.swift"))
        let full = GoalongDeveloperLaneStatus.failed("La limite quotidienne des compteurs de fichiers est atteinte.")
        waitFor(monitor) { monitor.snapshotStatus() == full }
        XCTAssertEqual(monitor.snapshotStatus(), full)
        XCTAssertEqual(GoalongDeveloperMonitorStatus.current(root: data), full)
        let consents = GoalongCapabilityConsentStore(fileURL: data.appendingPathComponent("capability-consent.json"))
        let model = GoalongDeveloperModel(root: data, consents: consents)
        XCTAssertTrue(model.setEnabled(true)); await model.refresh(day: Date())
        XCTAssertEqual(model.value?.developerStatus, .failed("Suivi des fichiers interrompu : La limite quotidienne des compteurs de fichiers est atteinte."))
        try FileManager.default.removeItem(at: journal)
        try Data("two".utf8).write(to: root.appendingPathComponent("repo/two.swift"))
        waitFor(monitor) { monitor.snapshotStatus() == .ready }
        XCTAssertEqual(monitor.snapshotStatus(), .ready)
        await model.refresh(day: Date())
        XCTAssertNotEqual(model.value?.developerStatus, full)
    }
    @MainActor func testSuggestionsDropFollowedProjectsAndSurviveARemoval() throws {
        let root = try fixture(), day = Calendar.current.startOfDay(for: Date())
        let projects = try ["alpha", "beta"].map { name -> GoalongDeveloperProject in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name + "/.git"), withIntermediateDirectories: true)
            return GoalongDeveloperProject(root: root.appendingPathComponent(name), name: name)
        }
        let model = GoalongDeveloperModel(root: root.appendingPathComponent("data"), consents: GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("data/capability-consent.json")))
        model.setValueForTesting(GoalongDeveloperDay(day: day, t3: T3CodeMetadataReader.read(day: day, enabled: false, shouldContinue: { true }),
            agents: GoalongAgentProjectGrouping.group(.init(day: day), t3: nil, enabled: false), git: [],
            files: .init(status: .noData, buckets: []), selectedProjects: [], suggestions: projects, developerStatus: .noData))
        try model.addProject(projects[0])
        XCTAssertEqual(model.suggestions.map(\.name), ["beta"])
        try model.removeProject(id: model.selectedProjects[0].id)
        XCTAssertEqual(model.suggestions.map(\.name), ["alpha", "beta"])
    }
}
#endif
