#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// T-057 U1: capture losses are readable (idea 7); an unreadable day offers « Réessayer » and never reads as empty (idea 10).
final class T057U1Tests: XCTestCase {
    private typealias Empty = GoalongActivityEmptyCopy

    func testLossLineNamesCountAndTimes() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let t = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC
        XCTAssertNil(CaptureStorageLoss(count: 0, first: t, last: t).line(timeZone: utc))
        XCTAssertEqual(CaptureStorageLoss(count: 12, first: t, last: t.addingTimeInterval(420)).line(timeZone: utc),
                       "12 interactions non enregistrées entre 08:00 et 08:07")
        XCTAssertEqual(CaptureStorageLoss(count: 1, first: t, last: t.addingTimeInterval(20)).line(timeZone: utc),
                       "1 interaction non enregistrée à 08:00")
    }

    func testStorageStopCopyCarriesTheLossLine() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let loss = CaptureStorageLoss(count: 3, first: t, last: t.addingTimeInterval(120))
        let copy = Empty.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0, purged: false, recording: nil,
                              storage: .init(kind: .diskFull, since: t, loss: loss))
        XCTAssertTrue(copy.message.contains("3 interactions non enregistrées entre"), copy.message)
        XCTAssertTrue(copy.message.contains("pas une journée à zéro"))
        let none = Empty.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0, purged: false, recording: nil,
                              storage: .init(kind: .diskFull, since: t))
        XCTAssertFalse(none.message.contains("non enregistrée"))
    }

    func testUnreadableDayOffersRetryAndEmptyDayDoesNot() {
        let unread = Empty.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 1, purged: false, recording: nil)
        XCTAssertEqual(unread.kind, .unavailable); XCTAssertTrue(unread.offersRetry)
        XCTAssertTrue(unread.message.contains("ne signifie pas une absence d’activité"))
        let empty = Empty.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 0, purged: false, recording: nil)
        XCTAssertFalse(empty.offersRetry); XCTAssertEqual(empty.kind, .notYet)
    }
}
#endif
