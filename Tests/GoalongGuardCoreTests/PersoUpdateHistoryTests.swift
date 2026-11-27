import Foundation
@testable import GoalongGuardCore
import XCTest

/// T-057 idées 5 et 6: the bounded `make perso` history (status only; no install decision reads it).
final class PersoUpdateHistoryTests: XCTestCase {
    private var temp: URL!
    private var history: PersoUpdateHistory { PersoUpdateHistory(root: temp) }
    private let commit = String(repeating: "c", count: 40)

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("perso-history-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    func testRecordsTheSuccessPathInOrderWithItsCommit() throws {
        for (offset, phase) in [PersoUpdateHistory.Phase.received, .verified, .closing, .relaunching, .done].enumerated() {
            history.record("20261127-100000-1", phase, commit: phase == .received ? commit : nil, now: 1000 + Double(offset * 3))
        }
        let entry = try XCTUnwrap(history.entries().first)
        XCTAssertEqual(entry.steps.map(\.phase), [.received, .verified, .closing, .relaunching, .done])
        XCTAssertEqual(entry.commit, commit)
        XCTAssertEqual(entry.shortCommit, "cccccccc")
        XCTAssertTrue(entry.isFinal)
        XCTAssertEqual(entry.duration, 12)
    }

    func testAFinalEntryNeverChangesAndAPhaseIsRecordedOnce() throws {
        history.record("a-1", .received, now: 10)
        history.record("a-1", .received, now: 11)
        history.record("a-1", .refused, reason: "numéro de build plus ancien", now: 12)
        history.record("a-1", .closing, now: 13)
        history.record("a-1", .done, now: 14)
        let entry = try XCTUnwrap(history.entries().first)
        XCTAssertEqual(entry.steps, [.init(phase: .received, at: 10), .init(phase: .refused, at: 12)])
        XCTAssertEqual(entry.reason, "numéro de build plus ancien")
    }

    func testKeepsOnlyTheNewestEntriesNewestFirst() {
        for index in 0..<(PersoUpdateHistory.maximumEntries + 5) {
            history.record("r-\(index)", .received, now: Double(index))
        }
        let ids = history.entries().map(\.id)
        XCTAssertEqual(ids.count, PersoUpdateHistory.maximumEntries)
        XCTAssertEqual(ids.first, "r-\(PersoUpdateHistory.maximumEntries + 4)")
        XCTAssertFalse(ids.contains("r-0"))
    }

    func testStaleOnlyWhenNotFinalAndSilentForFiveMinutesEitherWay() throws {
        history.record("s-1", .closing, now: 1000)
        let entry = try XCTUnwrap(history.entries().first)
        XCTAssertFalse(entry.isStale(now: 1200))
        XCTAssertTrue(entry.isStale(now: 1301))
        XCTAssertTrue(entry.isStale(now: 600), "a clock set back does not make it run forever")
        history.record("s-1", .restored, reason: "Goalong n’a pas quitté", now: 1400)
        XCTAssertFalse(try XCTUnwrap(history.entries().first).isStale(now: 99_999))
    }

    func testIgnoresInvalidIDsAndReadsADamagedFileAsEmpty() throws {
        history.record("../evil", .received)
        XCTAssertEqual(history.entries(), [])
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: history.file)
        XCTAssertEqual(history.entries(), [])
        history.record("ok-1", .received, now: 1)
        XCTAssertEqual(history.entries().map(\.id), ["ok-1"])
    }

    func testDurationHidesAClockJump() {
        let entry = PersoUpdateHistory.Entry(id: "j", steps: [.init(phase: .received, at: 100), .init(phase: .done, at: 50)])
        XCTAssertNil(entry.duration)
    }
}
