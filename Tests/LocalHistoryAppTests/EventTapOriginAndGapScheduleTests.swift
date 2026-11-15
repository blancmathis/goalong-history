#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    /// T-064: the gap marker is not postponed forever, and the source app is not looked up on every event.
    final class EventTapOriginAndGapScheduleTests: XCTestCase {
        func testGapMarkerWaitsHalfASecondButNeverPastFiveSeconds() {
            let start = Date(timeIntervalSinceReferenceDate: 1_000)
            XCTAssertEqual(EventTapObservationGapSchedule.delay(pendingSince: start, now: start), 0.5)
            XCTAssertEqual(
                EventTapObservationGapSchedule.delay(pendingSince: start, now: start.addingTimeInterval(4.8)),
                0.2, accuracy: 0.0001)
            XCTAssertEqual(
                EventTapObservationGapSchedule.delay(pendingSince: start, now: start.addingTimeInterval(30)), 0)
        }

        func testProcessNameLookupIsCachedPerProcessForTenSeconds() {
            var cache = InputOriginProcessNameCache()
            let now = Date(timeIntervalSinceReferenceDate: 1_000)
            let entry = InputOriginProcessNameCache.Entry(localizedName: "App", bundleIdentifier: "a.b")
            for _ in 0..<100 {
                XCTAssertEqual(cache.entry(for: 42, now: now) { _ in entry }, entry)
            }
            XCTAssertEqual(cache.lookupCount, 1)
            _ = cache.entry(for: 42, now: now.addingTimeInterval(11)) { _ in entry }
            XCTAssertEqual(cache.lookupCount, 2)
        }

        func testProcessNameCacheStaysBounded() {
            var cache = InputOriginProcessNameCache()
            let now = Date(timeIntervalSinceReferenceDate: 1_000)
            for pid in 1...40 {
                _ = cache.entry(for: pid_t(pid), now: now.addingTimeInterval(Double(pid) * 0.01)) { _ in nil }
            }
            XCTAssertEqual(cache.lookupCount, 40)
            // The newest process is still cached; the bound evicted older ones.
            _ = cache.entry(for: 40, now: now.addingTimeInterval(0.5)) { _ in nil }
            XCTAssertEqual(cache.lookupCount, 40)
            _ = cache.entry(for: 1, now: now.addingTimeInterval(0.5)) { _ in nil }
            XCTAssertEqual(cache.lookupCount, 41)
        }
    }
#endif
