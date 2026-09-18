#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class GoalongMotionPlacementTests: XCTestCase {
    func testVerificationOutlivesTheShortSnapshotLoadIncludingCacheHits() {
        XCTAssertEqual(ComputerHistoryDayLoadingPhase.resolve(preparing: true, loading: true, source: .checking), .preparing)
        XCTAssertEqual(ComputerHistoryDayLoadingPhase.resolve(preparing: false, loading: true, source: .checking), .verifying)
        XCTAssertEqual(ComputerHistoryDayLoadingPhase.resolve(preparing: false, loading: false, source: .checking), .verifying)
        XCTAssertEqual(ComputerHistoryDayLoadingPhase.resolve(preparing: false, loading: false, source: .available), .idle)
    }

    func testErrorsAbsentAndUnverifiedSourcesDoNotKeepAnimating() {
        let statuses: [ComputerHistorySourceStatus] = [.available, .absent, .unverified, .inaccessible("Fixture error")]
        for status in statuses {
            XCTAssertFalse(ComputerHistoryDayLoadingPhase.resolve(preparing: false, loading: false, source: status).isActive)
        }
    }

    func testPreparationToVerificationDoesNotRestartTheMotionClock() {
        var motion = GoalongMotion.State()
        let preparation = ComputerHistoryDayLoadingPhase.resolve(preparing: true, loading: true, source: .checking)
        let verification = ComputerHistoryDayLoadingPhase.resolve(preparing: false, loading: false, source: .checking)
        motion.setBusy(preparation.isActive, at: 10)
        motion.setBusy(verification.isActive, at: 10.5)
        motion.setBusy(verification.isActive, at: 13)
        XCTAssertEqual(motion.since, 10)
        XCTAssertTrue(motion.busy)
        motion.setBusy(false, at: 13.5)
        XCTAssertFalse(motion.busy)
    }

    func testOnlyTheTwoPrimaryLoadingAreasOptIn() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = repository.appendingPathComponent("Sources/LocalHistoryApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var placements: [String: Int] = [:]
        let marker = ".progressViewStyle(GoalongProgressViewStyle())"
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.components(separatedBy: marker).count - 1
            if count > 0 { placements[file.lastPathComponent] = count }
        }
        XCTAssertEqual(placements, ["ComputerHistoryPage.swift": 1, "GoalongAnalyticsPage.swift": 1])
        let root = try String(contentsOf: sources.appendingPathComponent("DashboardRootView.swift"), encoding: .utf8)
        XCTAssertTrue(root.contains("GoalongMark()"), "The sidebar keeps its original static mark")
        XCTAssertFalse(root.contains("GoalongActivityMark"))
        XCTAssertFalse(root.contains("GoalongProgressViewStyle"), "No inherited style on Today, headers, buttons or sheets")
        let history = try String(contentsOf: sources.appendingPathComponent("ComputerHistoryPage.swift"), encoding: .utf8)
        XCTAssertTrue(history.contains("if dayLoadingPhase.isActive"))
        XCTAssertTrue(history.contains("history-day-verification-motion"))
        let analytics = try String(contentsOf: sources.appendingPathComponent("GoalongAnalyticsPage.swift"), encoding: .utf8)
        XCTAssertTrue(analytics.contains("analytics-primary-loading-motion"))
    }
}
#endif
