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

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t045h7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func names(_ root: URL, _ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path).sorted()
    }
    private func text(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// H9: a user already back on the Gregorian calendar keeps Buddhist or Japanese files of the app's lifetime;
    /// they get their Gregorian name too. Real Gregorian names and impossible legacy days are left alone.
    func testGregorianCalendarMigratesLeftoverLegacyFiles() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try write("{}\n", root, "calls", "2569-10-27.jsonl")
        try write("{}\n", root, "developer", "0008-10-26.jsonl")
        try write("{}\n", root, "calls", "2026-10-20.jsonl")
        try write("{}\n", root, "calls", "2500-01-01.jsonl") // Buddhist 1957: before Goalong, not a leftover
        try write("{}\n", root, "calls", "0043-09-17.jsonl") // Chinese-like year: Japanese Shōwa 43 is out of range
        GoalongLegacyDayFiles.migrate(root: root, calendar: calendar(.gregorian), now: noon)
        GoalongLegacyDayFiles.migrate(root: root, calendar: calendar(.gregorian), now: noon)
        XCTAssertEqual(try names(root, "calls"), ["0043-09-17.jsonl", "2026-10-20.jsonl", "2026-10-27.jsonl", "2500-01-01.jsonl"])
        XCTAssertEqual(try names(root, "developer"), ["2026-10-26.jsonl"])
    }

    /// H9: the old and the Gregorian file of the same day are merged, the old lines first; the Gregorian file is never lost
    /// and a second pass adds nothing. A note is merged when both fit in 280 characters, else the old one waits for a full clear.
    func testCollisionMergesOldDayIntoGregorianFile() throws {
        for (identifier, legacy) in [(Calendar.Identifier.buddhist, "2569-10-27"), (.gregorian, "2569-10-27"), (.japanese, "0008-10-27")] {
            let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
            try write("{\"old\":1}\n", root, "calls", legacy + ".jsonl")
            try write("{\"new\":1}\n", root, "calls", "2026-10-27.jsonl")
            try write("{\"old\":2}", root, "developer", legacy + ".jsonl") // torn last line
            try write("{\"new\":2}\n", root, "developer", "2026-10-27.jsonl")
            try write(#"{"day":"\#(legacy)","text":"Avant","version":1}"#, root, "notes", legacy + ".json")
            try write(#"{"day":"2026-10-27","text":"Après","version":1}"#, root, "notes", "2026-10-27.json")

            GoalongLegacyDayFiles.migrate(root: root, calendar: calendar(identifier), now: noon)
            GoalongLegacyDayFiles.migrate(root: root, calendar: calendar(identifier), now: noon)

            for folder in ["calls", "developer", "notes"] {
                let found = try names(root, folder)
                XCTAssertEqual(found.count, 1, "\(identifier) \(folder): \(found)")
            }
            XCTAssertEqual(try text(root, "calls/2026-10-27.jsonl"), "{\"old\":1}\n{\"new\":1}\n", "\(identifier)")
            XCTAssertEqual(try text(root, "developer/2026-10-27.jsonl"), "{\"old\":2}\n{\"new\":2}\n", "\(identifier)")
            XCTAssertEqual(try GoalongDayNoteStore.get(root: root, day: noon.addingTimeInterval(-86_400)), "Avant\nAprès", "\(identifier)")
        }
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let long = String(repeating: "a", count: 200), newer = String(repeating: "b", count: 200)
        try write(#"{"day":"2569-10-27","text":"\#(long)","version":1}"#, root, "notes", "2569-10-27.json")
        try write(#"{"day":"2026-10-27","text":"\#(newer)","version":1}"#, root, "notes", "2026-10-27.json")
        GoalongLegacyDayFiles.migrate(root: root, calendar: calendar(.buddhist), now: noon)
        XCTAssertEqual(try names(root, "notes"), ["2026-10-27.json", "2569-10-27.json"])
        XCTAssertEqual(try GoalongDayNoteStore.get(root: root, day: noon.addingTimeInterval(-86_400)), newer)
    }

    /// H7-04: the `seen` field of work corrections is a Gregorian day, whatever the system calendar.
    @MainActor func testWorkAgentDayStringIsGregorianUnderOtherCalendars() {
        for identifier in [Calendar.Identifier.buddhist, .japanese] {
            XCTAssertEqual(GoalongWorkAgent.dayString(noon, calendar: calendar(identifier)), "2026-10-28", "\(identifier)")
        }
    }

    func testStoredBuddhistSeenDayReadsAsGregorian() throws {
        let json = #"{"verdict":"work","task":null,"byOwner":false,"seen":"2569-10-27","attempts":1,"lastAskedDay":"2569-10-27"}"#
        let entry = try JSONDecoder().decode(GoalongWorkStore.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.seen, "2026-10-27")
        XCTAssertEqual(entry.lastAskedDay, "2026-10-27")
    }
}
