#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    /// T-045 T2: `ActivityAnalysisStore` file handling. It writes under the data root, so these tests only run in the
    /// throwaway HOME made by `scripts/run_swift_tests.sh`.
    final class T045T2AnalysisStoreTests: XCTestCase {
        private let fm = FileManager.default
        private let store = ActivityAnalysisStore()
        private var created: [URL] = []

        override func setUpWithError() throws {
            let path = ActivityAnalysisPaths.applicationSupportDirectory.path
            guard path.hasPrefix("/tmp/goalong-") || path.hasPrefix("/private/tmp/goalong-") else {
                throw XCTSkip("data root \(path) is not a throwaway HOME")
            }
            try fm.createDirectory(at: ActivityAnalysisPaths.analysisDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: ActivityAnalysisPaths.eventsDirectory, withIntermediateDirectories: true)
        }

        override func tearDown() {
            for url in created { try? fm.removeItem(at: url) }
            created = []
        }

        private func touch(_ url: URL, _ text: String = "x") throws {
            try Data(text.utf8).write(to: url)
            created.append(url)
        }

        private func writeAnalysis(_ analysis: ActivityDayAnalysis, day: Date) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try touch(ActivityAnalysisPaths.JSONFile(for: day), "")
            try encoder.encode(analysis).write(to: ActivityAnalysisPaths.JSONFile(for: day))
        }

        func testPathsUseTheLocalDayString() {
            let day = T045T2Fixtures.date(2026, 3, 10, hour: 23, minute: 30)
            XCTAssertEqual(ActivityAnalysisPaths.dayString(day), "2026-03-10")
            XCTAssertEqual(ActivityAnalysisPaths.JSONFile(for: day).lastPathComponent, "2026-03-10.analysis.json")
            XCTAssertEqual(ActivityAnalysisPaths.agentMarkdownFile(for: day).lastPathComponent, "2026-03-10.agent.md")
            XCTAssertEqual(ActivityAnalysisPaths.JSONFile(for: day).deletingLastPathComponent().lastPathComponent, "analysis")
        }

        func testLoadStoredRoundTripsAnAnalysis() throws {
            let day = T045T2Fixtures.date(2031, 5, 17)
            let analysis = T045T2Fixtures.analysis(day: day, headline: "Journée test", activeSeconds: 1234, workSeconds: 567)
            try writeAnalysis(analysis, day: day)
            let loaded = try XCTUnwrap(store.loadStored(for: day))
            XCTAssertEqual(loaded.headline, "Journée test")
            XCTAssertEqual(loaded.activeSeconds, 1234)
            XCTAssertEqual(loaded.workSeconds, 567)
            XCTAssertEqual(loaded.dayStart, analysis.dayStart)
        }

        func testLoadStoredReturnsNilForMissingOrCorruptFile() throws {
            let day = T045T2Fixtures.date(2031, 5, 18)
            XCTAssertNil(store.loadStored(for: day))
            try touch(ActivityAnalysisPaths.JSONFile(for: day), "{ not json")
            XCTAssertNil(store.loadStored(for: day))
        }

        func testRemoveAnalysisDeletesBothFilesOfThatDayOnly() throws {
            let day = T045T2Fixtures.date(2031, 5, 19), other = T045T2Fixtures.date(2031, 5, 20)
            for d in [day, other] {
                try touch(ActivityAnalysisPaths.JSONFile(for: d))
                try touch(ActivityAnalysisPaths.agentMarkdownFile(for: d))
            }
            store.removeAnalysis(for: day)
            XCTAssertFalse(fm.fileExists(atPath: ActivityAnalysisPaths.JSONFile(for: day).path))
            XCTAssertFalse(fm.fileExists(atPath: ActivityAnalysisPaths.agentMarkdownFile(for: day).path))
            XCTAssertTrue(fm.fileExists(atPath: ActivityAnalysisPaths.JSONFile(for: other).path))
            XCTAssertTrue(fm.fileExists(atPath: ActivityAnalysisPaths.agentMarkdownFile(for: other).path))
            store.removeAnalysis(for: day)  // already gone: no crash
        }

        func testRemoveOrphanedAnalysesKeepsDaysWithEventsAndForeignFiles() throws {
            let analysis = ActivityAnalysisPaths.analysisDirectory, events = ActivityAnalysisPaths.eventsDirectory
            try touch(analysis.appendingPathComponent("2031-06-01.analysis.json"))
            try touch(analysis.appendingPathComponent("2031-06-01.agent.md"))
            try touch(analysis.appendingPathComponent("2031-06-02.analysis.json"))
            try touch(analysis.appendingPathComponent("2031-06-02.agent.md"))
            try touch(analysis.appendingPathComponent("notes.txt"))
            try touch(analysis.appendingPathComponent(".2031-06-03.analysis.json"))
            try touch(events.appendingPathComponent("2031-06-01.jsonl"))
            store.removeOrphanedAnalyses()
            func exists(_ name: String) -> Bool { fm.fileExists(atPath: analysis.appendingPathComponent(name).path) }
            XCTAssertTrue(exists("2031-06-01.analysis.json"))
            XCTAssertTrue(exists("2031-06-01.agent.md"))
            XCTAssertFalse(exists("2031-06-02.analysis.json"), "no event file for that day")
            XCTAssertFalse(exists("2031-06-02.agent.md"))
            XCTAssertTrue(exists("notes.txt"), "files that are not day files stay")
            XCTAssertTrue(exists(".2031-06-03.analysis.json"), "hidden files are skipped")
        }
    }
#endif
