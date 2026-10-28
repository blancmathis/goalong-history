import Foundation
import XCTest
@testable import LocalHistoryCore

/// T-045 H7: day files are named with Gregorian keys, whatever the system calendar.
/// Retention and « Effacer l’historique » compare Gregorian keys (R1-231).
final class T045H7Tests: XCTestCase {
    private func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var value = Calendar(identifier: identifier); value.timeZone = TimeZone(identifier: "Europe/Paris")!; return value
    }
    private let noon = ISO8601DateFormatter().date(from: "2026-10-28T11:00:00Z")!

    func testSystemSourceDayKeyIsGregorianUnderBuddhistAndJapaneseCalendars() {
        XCTAssertEqual(GoalongSystemSourceFiles.dayKey(noon, calendar: calendar(.buddhist)), "2026-10-28")
        XCTAssertEqual(GoalongSystemSourceFiles.dayKey(noon, calendar: calendar(.japanese)), "2026-10-28")
    }

    func testDeveloperDayFileIsGregorianUnderABuddhistCalendar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t045h7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GoalongDeveloperStore(root: root)
        let bucket = GoalongFileModificationBucket(projectID: String(repeating: "a", count: 64), start: noon,
                                                   modifiedFiles: 3, estimated: false, lastEventID: 1)
        try store.append([bucket], day: noon, calendar: calendar(.buddhist))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("developer").path)
        XCTAssertEqual(names, ["2026-10-28.jsonl"])
        XCTAssertEqual(store.read(day: noon, calendar: calendar(.buddhist)).fileChanges, 3)
    }

    /// A write cut short (disk full, crash) leaves a torn last line. The other calls of the day stay readable,
    /// and the next call starts on its own line instead of being glued to the fragment.
    func testTornCallLineKeepsTheDayReadableAndTheNextCallIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t045h7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let first = GoalongCallInterval(start: noon, end: noon.addingTimeInterval(600), bundleIdentifier: "us.zoom.xos",
                                        application: "Zoom", microphone: true, camera: true)
        try GoalongCallStore.save(first, root: root)
        let file = root.appendingPathComponent("calls/" + GoalongSystemSourceFiles.dayKey(noon) + ".jsonl")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"start":"2026-10-28T11:2"#.utf8)); try handle.close()

        let second = GoalongCallInterval(start: noon.addingTimeInterval(3600), end: noon.addingTimeInterval(4200), bundleIdentifier: "com.apple.FaceTime",
                                         application: "FaceTime", microphone: true, camera: false)
        try GoalongCallStore.save(second, root: root)

        let lane = GoalongCallStore.load(root: root, day: noon, enabled: true)
        XCTAssertEqual(lane.status, .partial)
        XCTAssertEqual(lane.intervals.map(\.application), ["Zoom", "FaceTime"])
    }

    func testTornDeveloperLineDoesNotSwallowTheNextBucket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t045h7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GoalongDeveloperStore(root: root)
        func bucket(_ files: Int) -> GoalongFileModificationBucket {
            GoalongFileModificationBucket(projectID: String(repeating: "b", count: 64), start: noon, modifiedFiles: files, estimated: false, lastEventID: 1)
        }
        try store.append([bucket(2)], day: noon)
        let file = root.appendingPathComponent("developer/" + GoalongSystemSourceFiles.dayKey(noon) + ".jsonl")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"projectID":"bb"#.utf8)); try handle.close()
        try store.append([bucket(5)], day: noon)
        XCTAssertEqual(store.read(day: noon).fileChanges, 5)
    }
}
