import Foundation
import XCTest
@testable import LocalHistoryCore

final class JevObservationPayloadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_300_000)
    private func sample(_ site: String = "x.com", mode: String = "social-feed", title: String = "Home",
                        action: String = "scroll", excerpt: String = "", offset: Double = 0,
                        active: Bool = true) -> JevSample {
        .init(date: now.addingTimeInterval(offset), resource: site, title: title,
              action: action, surface: mode, isActivity: active, excerpt: excerpt)
    }
    private func rows(_ samples: [JevSample], work: JevWorkContext = .empty) throws -> [[String]] {
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: samples)
        let data = try JevPayload.build(window, work: work)
        XCTAssertLessThanOrEqual(data.count, 1600)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        return try XCTUnwrap(state["rows"] as? [[String]])
    }
    func testActionsAreRetainedWithoutDuplicatingAnUnchangedTopic() throws {
        let values = try rows([sample(action: "click"), sample(action: "scroll", offset: 1),
                              sample(action: "scroll", offset: 3), sample(action: "foreground", offset: 5)])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0][3], "click+scroll")
    }
    func testLongTitleCannotEraseVisibleContent() throws {
        let excerpt = "A visible post discussing unrelated holiday shopping rather than app development"
        let values = try rows([sample(title: String(repeating: "Long title ", count: 30), excerpt: excerpt)])
        XCTAssertEqual(values[0].count, 5)
        XCTAssertEqual(values[0][4], excerpt)
        XCTAssertLessThanOrEqual(values[0][2].utf8.count, 160)
    }
    func testChangingPostsWithTheSameTitleKeepDistinctTopics() throws {
        let values = try rows([sample(), sample(excerpt: "SwiftUI release notes for our app", offset: 2, active: false),
                              sample(excerpt: "Holiday sneaker deals and football highlights", offset: 8, active: false)])
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.contains { $0[4].contains("SwiftUI") })
        XCTAssertTrue(values.contains { $0[4].contains("sneaker") })
        XCTAssertTrue(values.allSatisfy { $0[3] == "scroll" })
    }
    func testBriefConsumptionCannotDisappearBehindLaterWork() throws {
        let values = try rows([sample(excerpt: "Entertainment from the For you feed", offset: 1),
                              sample("Xcode", mode: "other", title: "Goalong - JevMonitor.swift", action: "typing", offset: 12)])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0][0], "x.com")
        XCTAssertEqual(values[1][0], "Xcode")
    }
    func testTextAloneDoesNotManufactureActivity() {
        XCTAssertThrowsError(try rows([sample(excerpt: "Freshly read visible text", active: false)])) {
            XCTAssertEqual($0 as? JevError, .noActivity)
        }
    }
    func testFutureAndOldExcerptsDoNotCrossWindowBoundaries() throws {
        let values = try rows([sample(), sample(excerpt: "Old content must not be sent", offset: -1),
                              sample(excerpt: "Next window content must wait", offset: 15)])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].count, 4)
    }
    func testVisibleTopicCanSupportReviewWithoutAUsefulWindowTitle() throws {
        let work = try JevWorkContext(summary: "Goalong SwiftUI development")
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            sample("developer.apple.com", mode: "other", title: "", excerpt: "SwiftUI NSWindow documentation")
        ])
        XCTAssertEqual(JevEvidencePolicy.reviewed(.productive, work: work, window: window), .productive)
    }
    func testKnownFeedWithNoTitleRemainsReviewableWithoutInventingWork() {
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [
            sample("youtube.com", mode: "video-feed", title: "", action: "foreground")
        ])
        XCTAssertEqual(JevEvidencePolicy.reviewed(.procrastination, work: .empty, window: window), .procrastination)
        XCTAssertEqual(JevEvidencePolicy.reviewed(.productive, work: .empty, window: window), .unknown)
    }
    func testUnicodeFieldsRemainValidAndBothTopicsSurviveBudgetReduction() throws {
        let work = try JevWorkContext(summary: String(repeating: "é", count: 250))
        let values = try rows([sample(title: String(repeating: "漢字", count: 40), excerpt: String(repeating: "🧪 sujet ", count: 24)),
                              sample("youtube.com", mode: "video", title: "Swift course", excerpt: "Course chapter about window ordering")], work: work)
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.allSatisfy { $0.count == 5 && !$0[4].isEmpty })
    }
}
