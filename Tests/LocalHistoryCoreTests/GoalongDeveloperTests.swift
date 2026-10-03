import XCTest
@testable import LocalHistoryCore

final class GoalongDeveloperTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 3))! }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-developer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/.git/logs/refs/heads"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testCanonicalWorktreeAndSubdirectoryResolveToOneRepository() throws {
        let root = try fixture(), main = root.appendingPathComponent("repo"), work = root.appendingPathComponent("work")
        let git = main.appendingPathComponent(".git/worktrees/work")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("gitdir: ../repo/.git/worktrees/work\n".utf8).write(to: work.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to: git.appendingPathComponent("commondir"))
        XCTAssertEqual(GoalongRepositoryResolver.canonicalRoot(work), main)
        XCTAssertEqual(GoalongRepositoryResolver.canonicalRoot(work.appendingPathComponent("Sources")), main)
        XCTAssertEqual(GoalongDeveloperProject(root: work).id, GoalongDeveloperProject(root: main).id)
        let store = GoalongDeveloperStore(root: root.appendingPathComponent("data"))
        try store.add(main); try store.add(work)
        let selected = try XCTUnwrap(store.configuration().projects.first)
        XCTAssertEqual(try store.configuration().projects.count, 1)
        XCTAssertEqual(Set(selected.observationRoots), Set([main.path, work.path]))
        XCTAssertEqual(GoalongRepositoryResolver.workingRoot(work.appendingPathComponent("Sources")).path, work.path)
    }
    func testReflogsDeduplicateCommitsAcrossHeadBranchesAndWorktrees() throws {
        let root = try fixture(), repo = root.appendingPathComponent("repo"), git = repo.appendingPathComponent(".git")
        let seconds = Int(day.timeIntervalSince1970)
        let hash = String(repeating: "a", count: 40), old = String(repeating: "0", count: 40)
        let row = "\(old) \(hash) Name <private@example.invalid> \(seconds + 3600) +0000\tcommit: SUBJECT-NEVER-RETURNED\n"
        try Data(row.utf8).write(to: git.appendingPathComponent("logs/HEAD"))
        try Data((row + "\(hash) \(old) Name <private@example.invalid> \(seconds + 3700) +0000\tcheckout: PRIVATE-BRANCH-NAME\n").utf8).write(to: git.appendingPathComponent("logs/refs/heads/main"))
        try FileManager.default.createDirectory(at: git.appendingPathComponent("worktrees/work/logs"), withIntermediateDirectories: true)
        try Data(row.utf8).write(to: git.appendingPathComponent("worktrees/work/logs/HEAD"))
        let value = GoalongGitActivityReader.read(project: .init(root: repo), day: day, calendar: calendar)
        XCTAssertEqual(value.status, .ready); XCTAssertEqual(value.commits.count, 1); XCTAssertEqual(value.actions.map(\.kind), [.commit, .checkout])
        XCTAssertFalse(String(describing: value).contains("SUBJECT-NEVER-RETURNED")); XCTAssertFalse(String(describing: value).contains("private@example"))
    }
    func testGitTailBudgetsAndCancelledReadsArePartial() throws {
        let root = try fixture(), repo = root.appendingPathComponent("repo")
        try Data(String(repeating: "x", count: 2048).utf8).write(to: repo.appendingPathComponent(".git/logs/HEAD"))
        var limits = GoalongGitActivityReader.Limits(); limits.maximumBytesPerFile = 64
        XCTAssertEqual(GoalongGitActivityReader.read(project: .init(root: repo), day: day, limits: limits).status, .partial)
        XCTAssertEqual(GoalongGitActivityReader.read(project: .init(root: repo), day: day, shouldContinue: { false }).status, .partial)
    }
    func testSelectedProjectsNeedExplicitAddAndSurviveReload() throws {
        let root = try fixture(), store = GoalongDeveloperStore(root: root.appendingPathComponent("data"))
        XCTAssertTrue(try store.configuration().projects.isEmpty)
        try store.add(root.appendingPathComponent("repo")); try store.add(root.appendingPathComponent("repo"))
        let project = try XCTUnwrap(store.configuration().projects.first)
        XCTAssertEqual(try store.configuration().projects.count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("data/developer-projects.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try store.remove(projectID: project.id); XCTAssertTrue(try store.configuration().projects.isEmpty)
    }
    func testBucketSnapshotsReplaceCountsAndContainNoFilePaths() throws {
        let root = try fixture(), store = GoalongDeveloperStore(root: root.appendingPathComponent("data")), project = GoalongDeveloperProject(root: root.appendingPathComponent("repo"))
        for count in [1, 3] { try store.append([.init(projectID: project.id, start: day, modifiedFiles: count, estimated: false, lastEventID: UInt64(count))], day: day, calendar: calendar) }
        let value = store.read(day: day, calendar: calendar)
        XCTAssertEqual(value.status, .ready); XCTAssertEqual(value.fileChanges, 3); XCTAssertEqual(value.buckets.count, 1)
        let raw = try String(contentsOf: root.appendingPathComponent("data/developer/2026-10-03.jsonl"))
        XCTAssertFalse(raw.contains(root.path)); XCTAssertFalse(raw.contains("rootPath"))
        try store.remove(day: day, calendar: calendar); XCTAssertEqual(store.read(day: day, calendar: calendar).status, .noData)
    }
    func testFileStoresRejectSymbolicLinksAndUnknownFormats() throws {
        let root = try fixture(), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside"); try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("developer-projects.json"), withDestinationURL: outside)
        let store = GoalongDeveloperStore(root: data)
        XCTAssertThrowsError(try store.configuration()); XCTAssertThrowsError(try GoalongDeveloperFileIO.write(Data("changed".utf8), name: "developer-projects.json", directory: data))
        XCTAssertEqual(try String(contentsOf: outside), "unchanged")
    }
    func testIntervalUnionAndParallelismUseHalfOpenBounds() {
        let intervals = [DateInterval(start: day, duration: 600), DateInterval(start: day.addingTimeInterval(300), duration: 600), DateInterval(start: day.addingTimeInterval(900), duration: 100)]
        XCTAssertEqual(GoalongDeveloperIntervals.unionSeconds(intervals), 1000)
        XCTAssertEqual(GoalongDeveloperIntervals.maximumParallel(intervals), 2)
    }
}
