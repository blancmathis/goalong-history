#if os(macOS)
import XCTest
import Foundation
import LocalHistoryCore
import AgentActivity
@testable import LocalHistoryApp

final class C044R9C2EdgeTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/" + relative), encoding: .utf8)
    }

    // C9-21: the UI says "1 Go" while the real low-space threshold is 2 Go.
    func testLowSpaceTextsMatchTheThreshold() throws {
        XCTAssertEqual(StorageHealth.lowSpaceThreshold, 2 * 1_024 * 1_024 * 1_024)
        for file in ["GoalongStorageSettings.swift", "GoalongAttentionBanner.swift", "SupportReport.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("1 Go"), "\(file) annonce 1 Go, le seuil réel est 2 Go")
        }
    }

    // C9-22: Développement recap prints "1 fichiers distincts".
    func testDeveloperRecapSingularFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/c9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let day = Calendar.current.startOfDay(for: Date())
        let p = GoalongDeveloperProject(root: root.appendingPathComponent("repo"), name: "repo")
        let buckets = [GoalongFileModificationBucket(projectID: p.id, start: day, modifiedFiles: 1, estimated: false, lastEventID: 1)]
        let value = GoalongDeveloperDay(day: day, t3: T3CodeMetadataReader.read(day: day, enabled: false, shouldContinue: { true }),
            agents: GoalongAgentProjectGrouping.group(.init(day: day), t3: nil, enabled: false), git: [],
            files: .init(status: .ready, buckets: buckets), selectedProjects: [p], suggestions: [], developerStatus: .ready)
        let text = try GoalongDeveloperRecap.render(value)
        XCTAssertFalse(text.contains("1 fichiers"), text)
    }

    // C9-23: percent and chart units use a plain space instead of U+00A0.
    func testPercentUsesNonBreakingSpace() throws {
        XCTAssertEqual(DashboardFormatters.percentage(1, 2), "50\u{00A0}%")
        XCTAssertEqual(DashboardFormatters.percentage(1, 0), "0\u{00A0}%")
    }
}
#endif
