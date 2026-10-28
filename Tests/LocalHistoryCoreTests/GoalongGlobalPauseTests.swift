import Foundation
import XCTest
@testable import LocalHistoryCore

final class GoalongGlobalPauseTests: XCTestCase {
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-pause-test-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    func testMissingPauseIsInactiveAndDoesNotCreateAFile() throws {
        let root = try root()
        XCTAssertFalse(GoalongGlobalPause.isPaused(in: root))
        XCTAssertEqual(try GoalongGlobalPause.admit(in: root), "initial")
        XCTAssertFalse(FileManager.default.fileExists(atPath: GoalongGlobalPause.file(in: root).path))
    }
    func testPausePersistsAndDoesNotChangeSourceOrSharingChoices() throws {
        let root = try root()
        let preferences = root.appendingPathComponent("capability-consent.json")
        let original = Data("synthetic preferences must remain unchanged".utf8)
        try original.write(to: preferences)
        let pause = try GoalongGlobalPause.setPaused(true, in: root, recordingWasPaused: true)
        XCTAssertTrue(pause.paused)
        XCTAssertTrue(GoalongGlobalPause.load(in: root).recordingWasPaused)
        XCTAssertThrowsError(try GoalongGlobalPause.admit(in: root))
        XCTAssertEqual(try Data(contentsOf: preferences), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: GoalongGlobalPause.file(in: root).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try GoalongGlobalPause.setPaused(false, in: root)
        XCTAssertFalse(GoalongGlobalPause.isPaused(in: root))
        XCTAssertEqual(try Data(contentsOf: preferences), original)
    }
    func testPauseResumeInvalidatesWorkAdmittedBeforePause() throws {
        let root = try root()
        let old = try GoalongGlobalPause.admit(in: root)
        try GoalongGlobalPause.setPaused(true, in: root)
        try GoalongGlobalPause.setPaused(false, in: root)
        XCTAssertThrowsError(try GoalongGlobalPause.revalidate(old, in: root))
        let current = try GoalongGlobalPause.admit(in: root)
        XCTAssertNoThrow(try GoalongGlobalPause.revalidate(current, in: root))
        XCTAssertEqual(try GoalongGlobalPause.setPaused(false, in: root).revision, current)
    }
    func testRepairSetsDamagedFileAsideAndResumes() throws {
        let root = try root(), file = GoalongGlobalPause.file(in: root)
        try Data("bad json".utf8).write(to: file)
        XCTAssertTrue(GoalongGlobalPause.isPaused(in: root), "Damaged file keeps tracking paused until repair")
        let repaired = try GoalongGlobalPause.repairAndResume(in: root)
        XCTAssertFalse(repaired.blocksActivity)
        XCTAssertFalse(GoalongGlobalPause.isPaused(in: root))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let aside = names.filter { $0.hasPrefix("global-pause.damaged-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(aside[0])), Data("bad json".utf8))
        XCTAssertFalse(names.contains { $0.hasPrefix(".pause-") })
    }
    func testRepairHandlesOversizedAndNonRegularFilesAndLeavesHealthyOnesAlone() throws {
        let root = try root(), file = GoalongGlobalPause.file(in: root)
        try Data(repeating: 65, count: 9000).write(to: file)
        XCTAssertFalse(try GoalongGlobalPause.repairAndResume(in: root).blocksActivity)
        try GoalongGlobalPause.setPaused(true, in: root)
        let healthy = try Data(contentsOf: file)
        XCTAssertThrowsError(try GoalongGlobalPause.repairAndResume(in: root), "A readable pause is never overwritten by repair")
        XCTAssertEqual(try Data(contentsOf: file), healthy)
        XCTAssertTrue(GoalongGlobalPause.isPaused(in: root))
    }
    func testUnreadableAndOversizedPauseFailClosed() throws {
        let root = try root(), file = GoalongGlobalPause.file(in: root)
        try Data("bad json".utf8).write(to: file)
        XCTAssertTrue(GoalongGlobalPause.load(in: root).invalid)
        XCTAssertThrowsError(try GoalongGlobalPause.setPaused(false, in: root))
        try Data(repeating: 65, count: 9000).write(to: file)
        XCTAssertTrue(GoalongGlobalPause.isPaused(in: root))
    }
    func testLinkedMissingPauseCannotBeMistakenForNoPause() throws {
        let root = try root(), file = GoalongGlobalPause.file(in: root)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertTrue(GoalongGlobalPause.isPaused(in: root))
    }
}
