import Foundation
import XCTest
@testable import LocalHistoryQueryCLI

/// T-045 H7: a disk full during a multi-day Health import must leave every saved day as it was,
/// since the message says « vos données Santé n’ont pas été modifiées ».
final class T045H7HealthTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Paris")!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func xml(_ body: String) -> Data { Data("<?xml version=\"1.0\"?><HealthData locale=\"fr_FR\"><ExportDate value=\"2026-09-08 09:00:00 +0200\"/>\(body)</HealthData>".utf8) }
    private func steps(_ value: String, on day: String) -> String {
        "<Record type=\"HKQuantityTypeIdentifierStepCount\" sourceName=\"Watch\" unit=\"count\" value=\"\(value)\" startDate=\"\(day) 10:00:00 +0200\" endDate=\"\(day) 10:10:00 +0200\"/>"
    }
    private func read(_ data: Data, from: String) throws -> GoalongHealthImportResult {
        try GoalongHealthImport.read(data: data, options: .init(from: date(from), through: date("2026-09-07T21:59:59Z"), timezone: zone, groups: [.activity]))
    }

    func testDiskFullOnTheSecondDayLeavesTheFirstSavedDayUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try GoalongHealthArchive.save(read(xml(steps("50", on: "2026-09-06")), from: "2026-09-05T22:00:00Z"), root: root)
        let before = try GoalongHealthArchive.read(day: "2026-09-06", root: root)

        let twoDays = try read(xml(steps("100", on: "2026-09-06") + steps("200", on: "2026-09-07")), from: "2026-09-05T22:00:00Z")
        XCTAssertEqual(twoDays.dayCount, 2)
        var calls = 0
        XCTAssertThrowsError(try GoalongHealthArchive.save(twoDays, root: root, write: { descriptor, data in
            calls += 1
            guard calls == 1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        })) { XCTAssertTrue(goalongUserMessage($0).contains("n’ont pas été modifiées"), goalongUserMessage($0)) }

        XCTAssertEqual(try GoalongHealthArchive.read(day: "2026-09-06", root: root), before)
        XCTAssertThrowsError(try GoalongHealthArchive.read(day: "2026-09-07", root: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("health").path), ["2026-09-06.json"])
    }
}
