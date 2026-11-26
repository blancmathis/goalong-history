#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    /// T-057 D1 §2: the 10-minute background timer rewrote ~16 MB of today's derived views on
    /// every tick (~2.1 GB/day). Today's background pass now runs at most every 30 minutes.
    final class ActivityAnalysisBackgroundCadenceTests: XCTestCase {
        func testBackgroundTimerRefreshesTodayAtMostFortyEightTimesPerDay() {
            var cadence = ActivityAnalysisBackgroundCadence()
            let calendar = Calendar(identifier: .gregorian)
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
            var passes: [Date] = []
            // 144 ticks of the 10-minute timer, each firing up to 30 s early or late (its tolerance).
            for tick in 1...144 {
                let jitter = Double((tick * 37) % 61) - 30
                let now = day.addingTimeInterval(Double(tick) * 600 + jitter)
                guard calendar.isDate(now, inSameDayAs: day) else { continue }
                if cadence.shouldRefreshToday(day, at: now) { passes.append(now) }
            }

            XCTAssertLessThanOrEqual(passes.count, 48, "today rewritten \(passes.count) times by the timer")
            XCTAssertGreaterThanOrEqual(passes.count, 46)
            // Freshness bound for files read outside the app (CLI, Codex mirror): ≤ 30 min + one tick.
            for (previous, next) in zip(passes, passes.dropFirst()) {
                XCTAssertLessThanOrEqual(next.timeIntervalSince(previous), 30 * 60 + 10 * 60 + 60)
            }
            // ~16 MB per pass of a full day (D1 measure): the background writes stay under 1 GB/day.
            XCTAssertLessThan(Double(passes.count) * 16 * 1_024 * 1_024, 1_000_000_000)
        }

        func testNewDayIsRefreshedOnTheFirstTick() {
            var cadence = ActivityAnalysisBackgroundCadence()
            let day = Date(timeIntervalSince1970: 1_790_000_000)
            let next = day.addingTimeInterval(24 * 60 * 60)
            XCTAssertTrue(cadence.shouldRefreshToday(day, at: day.addingTimeInterval(100)))
            XCTAssertFalse(cadence.shouldRefreshToday(day, at: day.addingTimeInterval(700)))
            XCTAssertTrue(cadence.shouldRefreshToday(next, at: day.addingTimeInterval(1_300)))
        }
    }
#endif
