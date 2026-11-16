#if os(macOS)
import XCTest
import Foundation
import GoalongGuardCore
@testable import LocalHistoryApp

/// T-064 lot 15: the update lease belongs to its issuer, the recap agenda wait does not hold a pool thread.
final class T064CaptureUpdateTests: XCTestCase {
    private func guardFiles() -> GuardFiles {
        let directory = GuardSystem.realPath(FileManager.default.temporaryDirectory).appendingPathComponent("t064-guard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return GuardFiles(directory: directory)
    }

    func testSparkleAbortRemovesOnlyItsOwnUpdateLease() {
        let files = guardFiles()
        let until = Date().timeIntervalSince1970 + 600
        // Another issuer (permission restart) holds the lease: our abort must leave it.
        files.writeLease(GuardLease(pid: 1, reason: GuardLease.permissionRestart, until: until))
        SoftwareUpdateManager.releaseUpdateLease(ownedRelaunch: true, files: files)
        XCTAssertEqual(files.readLease()?.reason, GuardLease.permissionRestart)
        // No relaunch of ours: even an update lease stays.
        files.writeLease(GuardLease(pid: 1, reason: GuardLease.update, until: until))
        SoftwareUpdateManager.releaseUpdateLease(ownedRelaunch: false, files: files)
        XCTAssertNotNil(files.readLease())
        // Our own relaunch lease goes.
        SoftwareUpdateManager.releaseUpdateLease(ownedRelaunch: true, files: files)
        XCTAssertNil(files.readLease())
    }

    func testCalendarLaneTimeoutDoesNotBlockAndReturnsPartial() async {
        let started = Date()
        let lane = await GoalongSystemRecapSections.calendarLane(day: Date(), timeout: 0.2, read: { _ in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return .disabled
        })
        XCTAssertEqual(lane.status, .partial)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "The wait gives up at its bound")
    }

    func testCalendarLaneReturnsTheReadWhenItIsFast() async {
        let lane = await GoalongSystemRecapSections.calendarLane(day: Date(), timeout: 30, read: { _ in
            .init(status: .noData, calendarStatus: .noData, remindersStatus: .noData)
        })
        XCTAssertEqual(lane.status, .noData)
    }

    /// Many concurrent waits on a small cooperative pool all finish: none of them parks a pool thread.
    func testManyCalendarWaitsDoNotStarveThePool() async {
        let lanes = await withTaskGroup(of: GoalongCalendarLane.self) { group -> [GoalongCalendarLane] in
            for _ in 0..<(ProcessInfo.processInfo.activeProcessorCount * 4) {
                group.addTask { await GoalongSystemRecapSections.calendarLane(day: Date(), timeout: 0.2, read: { _ in
                    try? await Task.sleep(nanoseconds: 30_000_000_000); return .disabled }) }
            }
            var out: [GoalongCalendarLane] = []
            for await lane in group { out.append(lane) }
            return out
        }
        XCTAssertTrue(lanes.allSatisfy { $0.status == .partial })
    }
}
#endif
