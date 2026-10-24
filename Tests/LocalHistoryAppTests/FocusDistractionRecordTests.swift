#if os(macOS) && DEBUG
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class FocusDistractionRecordTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ index: Int, targets: [JevDistractionTarget?]) -> JevWindow {
        let start = t0.addingTimeInterval(Double(index) * 15)
        let samples = targets.enumerated().map { offset, target in
            JevSample(date: start.addingTimeInterval(Double(offset)), resource: "r", title: "t",
                      action: "a", surface: "s", isActivity: true, distractionTarget: target)
        }
        return JevWindow(start: start, end: start.addingTimeInterval(15), samples: samples)
    }

    private func record(_ record: inout FocusDistractionRecord, _ w: JevWindow,
                        verdict: JevVerdict = .procrastination) -> Bool {
        record.record(w, verdict: verdict, sessionStart: t0, now: w.end.addingTimeInterval(1))
    }

    func testRecordsOnlySingleTargetProcrastinationWindows() throws {
        let site = try XCTUnwrap(JevDistractionTarget.site(host: "www.example.com"))
        let other = try XCTUnwrap(JevDistractionTarget.site(host: "other.org"))
        var r = FocusDistractionRecord()
        XCTAssertFalse(record(&r, window(0, targets: [site, other])), "mixed window is ambiguous")
        XCTAssertFalse(record(&r, window(0, targets: [site]), verdict: .productive))
        XCTAssertFalse(record(&r, window(0, targets: [site, nil])), "sample without target")
        XCTAssertTrue(record(&r, window(0, targets: [site, site])))
        XCTAssertFalse(record(&r, window(0, targets: [site])), "window overlapping the last one")
        XCTAssertTrue(record(&r, window(1, targets: [site])))
        XCTAssertEqual(r.counts.map(\.confirmedSeconds), [30])
        XCTAssertTrue(r.valid)
    }

    func testStaleWindowIsRejected() throws {
        let site = try XCTUnwrap(JevDistractionTarget.site(host: "example.com"))
        var r = FocusDistractionRecord()
        let w = window(0, targets: [site])
        XCTAssertFalse(r.record(w, verdict: .procrastination, sessionStart: t0, now: w.end.addingTimeInterval(15)))
        XCTAssertFalse(r.record(w, verdict: .procrastination, sessionStart: w.start.addingTimeInterval(1), now: w.end))
    }

    func testFinishKeepsTopThreeOverTwoMinutesWithStableTies() throws {
        let hosts = ["d.com", "c.com", "b.com", "a.com", "e.com"]
        var r = FocusDistractionRecord()
        var index = 0
        for (n, host) in hosts.enumerated() {
            let target = try XCTUnwrap(JevDistractionTarget.site(host: host))
            // e.com stays under 120 s; the others reach 120 s.
            for _ in 0..<(host == "e.com" ? 4 : 8 + (n == 0 ? 1 : 0)) {
                XCTAssertTrue(record(&r, window(index, targets: [target]))); index += 1
            }
        }
        r.finish(lists: [], ignored: [])
        XCTAssertEqual(r.suggestedTargetIDs, ["site:d.com", "site:a.com", "site:b.com"])
        XCTAssertTrue(r.valid)
        // Frozen: a finished record takes no more windows.
        XCTAssertFalse(record(&r, window(index, targets: [try XCTUnwrap(JevDistractionTarget.site(host: "d.com"))])))
    }

    func testFinishAndSuggestionsSkipIgnoredAndBlockedTargets() throws {
        let blocked = try XCTUnwrap(JevDistractionTarget.site(host: "blocked.com"))
        let ignored = try XCTUnwrap(JevDistractionTarget.site(host: "ignored.com"))
        let shown = try XCTUnwrap(JevDistractionTarget.site(host: "shown.com"))
        var r = FocusDistractionRecord()
        var index = 0
        for target in [blocked, ignored, shown] {
            for _ in 0..<8 { XCTAssertTrue(record(&r, window(index, targets: [target]))); index += 1 }
        }
        let list = BlockList(name: "L", sites: [BlockSiteRule(pattern: "www.blocked.com")])
        r.finish(lists: [list], ignored: [ignored.id])
        XCTAssertEqual(r.suggestedTargetIDs, [shown.id])
        XCTAssertEqual(r.suggestions(lists: [list], ignored: [ignored.id]).map(\.confirmedSeconds), [120])
        XCTAssertTrue(r.suggestions(lists: [list], ignored: [ignored.id, shown.id]).isEmpty)
        XCTAssertTrue(FocusDistractionRules.contains(blocked, lists: [list]))
        XCTAssertFalse(FocusDistractionRules.contains(shown, lists: [list]))
    }
}
#endif
