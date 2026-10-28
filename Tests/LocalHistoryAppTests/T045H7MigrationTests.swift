import Foundation
import XCTest
@testable import LocalHistoryApp
import LocalHistoryCore

/// T-045 H7: files named under a Buddhist or Japanese calendar get their Gregorian name once.
final class T045H7MigrationTests: XCTestCase {
    private func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var value = Calendar(identifier: identifier); value.timeZone = TimeZone(identifier: "Europe/Paris")!; return value
    }
    private let noon = ISO8601DateFormatter().date(from: "2026-10-28T11:00:00Z")!

    private func write(_ text: String, _ root: URL, _ folder: String, _ name: String) throws {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func testLegacyBuddhistAndJapaneseDayFilesAreRenamedOnce() throws {
        for (identifier, legacy) in [(Calendar.Identifier.buddhist, "2569-10-27"), (.japanese, "0008-10-27")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("t045h7-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try write(#"{"day":"\#(legacy)","text":"Bonne journée","version":1}"#, root, "notes", legacy + ".json")
            try write("{}\n", root, "calls", legacy + ".jsonl")
            try write("{}\n", root, "developer", legacy + ".jsonl")
            try write("garde\n", root, "developer", "2026-10-28.jsonl")

            GoalongLegacyDayFiles.migrate(root: root, calendar: calendar(identifier), now: noon)
            GoalongLegacyDayFiles.migrate(root: root, calendar: calendar(identifier), now: noon)

            for folder in ["notes", "calls", "developer"] {
                let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)
                XCTAssertFalse(names.contains { $0.hasPrefix(legacy) }, "\(identifier) \(folder): \(names)")
                XCTAssertTrue(names.contains { $0.hasPrefix("2026-10-27") }, "\(identifier) \(folder): \(names)")
            }
            let yesterday = noon.addingTimeInterval(-86_400)
            XCTAssertEqual(try GoalongDayNoteStore.get(root: root, day: yesterday), "Bonne journée")
            let kept = try String(contentsOf: root.appendingPathComponent("developer/2026-10-28.jsonl"), encoding: .utf8)
            XCTAssertEqual(kept, "garde\n")
        }
    }

    func testGregorianCalendarLeavesFilesAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t045h7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write("{}\n", root, "calls", "2569-10-27.jsonl")
        GoalongLegacyDayFiles.migrate(root: root, calendar: calendar(.gregorian), now: noon)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("calls").path), ["2569-10-27.jsonl"])
    }
}
