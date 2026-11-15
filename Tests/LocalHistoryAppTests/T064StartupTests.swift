#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    /// T-064 lot 10: startup disk walks leave the main thread.
    final class T064StartupTests: XCTestCase {
        func testStartupScavengeRunsOffMainAndStillRemovesAnAbandonedTemporaryFile() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-t064-scavenge-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let analysis = root.appendingPathComponent("analysis", isDirectory: true)
            try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
            let abandoned = analysis.appendingPathComponent(".2026-08-20.analysis.json.\(UUID().uuidString).tmp")
            try Data("old".utf8).write(to: abandoned)

            let done = expectation(description: "scavenged")
            var ranOnMain = true
            var deleted = 0
            AbandonedTemporaryScavenger.scavengeAtStartup(rootDirectory: root, now: Date().addingTimeInterval(25 * 60 * 60)) { report in
                ranOnMain = Thread.isMainThread
                deleted = report.deletedFiles
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            XCTAssertFalse(ranOnMain, "The launch scavenge must not run on the main thread")
            XCTAssertEqual(deleted, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        }

        func testBackgroundLaunchLoadPublishesTheSameDerivedStateAsTheSynchronousInit() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-t064-agents-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            func make(_ background: Bool) throws -> AgentActivityRuntime {
                try AgentActivityRuntime(
                    rootDirectory: root.appendingPathComponent("agents"),
                    executableURL: URL(fileURLWithPath: "/nonexistent/goalong-t064"),
                    performInitialDiscovery: false, sourceDiscovery: { [] }, pauseRoot: root,
                    loadsDerivedStateInBackground: background, onCaptured: { _ in })
            }
            let reference = try make(false)
            let runtime = try make(true)
            XCTAssertEqual(runtime.storageBytes, 0, "Nothing is measured on main at launch")
            XCTAssertTrue(runtime.indexIsValid, "No false invalid-index warning before the load")
            XCTAssertGreaterThan(reference.storageBytes, 0)

            let deadline = Date().addingTimeInterval(10)
            while runtime.storageBytes != reference.storageBytes, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(runtime.storageBytes, reference.storageBytes)
            XCTAssertEqual(runtime.indexIsValid, reference.indexIsValid)
            XCTAssertEqual(runtime.overview.day, reference.overview.day)
        }

        func testANewerOverviewIsNotReplacedByTheLaunchLoad() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-t064-agents-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = try AgentActivityRuntime(
                rootDirectory: root.appendingPathComponent("agents"),
                executableURL: URL(fileURLWithPath: "/nonexistent/goalong-t064"),
                performInitialDiscovery: false, sourceDiscovery: { [] }, pauseRoot: root,
                loadsDerivedStateInBackground: true, onCaptured: { _ in })
            // A day picked before the load lands: the load is for the old day and must not overwrite it.
            let other = Calendar.current.date(byAdding: .day, value: -3, to: runtime.selectedDay)!
            runtime.selectDay(other)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(runtime.overview.day, Calendar.current.startOfDay(for: other))
            XCTAssertEqual(runtime.storageBytes, 0, "The stale launch load was dropped")
        }
    }
#endif
