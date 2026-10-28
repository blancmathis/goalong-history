#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-045 T1 (AGD-03): in-call presence (camera, microphone). Success path, bad data, and the French
/// status text the page shows when the read fails.
final class T045T1CallPresenceTests: XCTestCase {
    private let day = Calendar.current.startOfDay(for: Date())

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-t045t1-calls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func call(_ from: TimeInterval, _ to: TimeInterval, app: String? = "us.zoom.xos", mic: Bool = true, camera: Bool = true, interrupted: Bool = false) -> GoalongCallInterval {
        .init(start: day.addingTimeInterval(from), end: day.addingTimeInterval(to), bundleIdentifier: app, application: app,
              microphone: mic, camera: camera, interrupted: interrupted)
    }

    private func callsFile(_ root: URL) -> URL {
        root.appendingPathComponent("calls").appendingPathComponent(GoalongSystemSourceFiles.dayKey(day) + ".jsonl")
    }

    func testASavedCallComesBackReadyWithItsCameraAndMicrophoneFlags() throws {
        let root = try root()
        try GoalongCallStore.save(call(600, 1_500, mic: true, camera: false), root: root)
        let lane = GoalongCallStore.load(root: root, day: day, enabled: true)
        XCTAssertEqual(lane.status, .ready)
        XCTAssertEqual(lane.intervals.count, 1)
        XCTAssertTrue(lane.intervals[0].microphone)
        XCTAssertFalse(lane.intervals[0].camera)
        XCTAssertEqual(lane.unionSeconds, 900)
        XCTAssertEqual(lane.secondsPerApplication["us.zoom.xos"], 900)
    }

    func testADayWithoutAnyCallIsNoDataAndATurnedOffSourceIsDisabled() throws {
        let root = try root()
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: true).status, .noData)
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: false).status, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
    }

    func testAnInvertedOrOverlongCallIsRefusedAndNothingIsWritten() throws {
        let root = try root()
        XCTAssertThrowsError(try GoalongCallStore.save(call(900, 600), root: root))
        XCTAssertThrowsError(try GoalongCallStore.save(call(0, 32 * 86_400), root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
    }

    func testUnreadableExclusionsFailWithTheFrenchMessage() throws {
        let root = try root()
        try GoalongCallStore.save(call(600, 900), root: root)
        var privacy = GoalongPrivacyPolicy(); privacy.blocked = true
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: true, privacy: privacy).status, .failed("Exclusions illisibles."))
    }

    func testAFileWithNoReadableLineFailsWithTheFrenchMessage() throws {
        let root = try root()
        try GoalongSystemSourceFiles.write(Data("pas du json\n".utf8), root: root, folder: "calls",
                                          name: GoalongSystemSourceFiles.dayKey(day) + ".jsonl", maximumBytes: 1_000)
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: true).status, .failed("Lecture des usages micro/caméra incomplète."))
    }

    func testATornLastLineKeepsTheDayReadableButMarksItPartial() throws {
        let root = try root()
        try GoalongCallStore.save(call(600, 900), root: root)
        let handle = try FileHandle(forWritingTo: callsFile(root))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"start\":\"20".utf8)); try handle.close()
        let lane = GoalongCallStore.load(root: root, day: day, enabled: true)
        XCTAssertEqual(lane.status, .partial)
        XCTAssertEqual(lane.unionSeconds, 300)
    }

    func testAnInterruptedCallMarksTheDayPartial() throws {
        let root = try root()
        try GoalongCallStore.save(call(600, 900, interrupted: true), root: root)
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: true).status, .partial)
    }

    func testAnOverlongApplicationNameFailsTheRead() throws {
        let root = try root()
        let name = String(repeating: "a", count: 257)
        try GoalongCallStore.save(call(600, 900, app: name), root: root)
        XCTAssertEqual(GoalongCallStore.load(root: root, day: day, enabled: true).status, .failed("Lecture des usages micro/caméra incomplète."))
    }

    func testALiveCallIsCountedBeforeItIsSaved() throws {
        let root = try root()
        let lane = GoalongCallStore.load(root: root, day: day, enabled: true, live: [call(100, 400, camera: false)])
        XCTAssertEqual(lane.status, .ready)
        XCTAssertEqual(lane.unionSeconds, 300)
    }
}
#endif
