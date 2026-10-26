import Foundation

extension Date {
    /// Time since `last` for throttles keyed on the wall clock (T-044 C3-01, C3-02). The user can set the
    /// Mac clock back: `now.throttleElapsed(since: last) >= n` then stays negative until the clock catches up,
    /// and the throttled work (address re-read, measurement, save) freezes. A gap either way counts.
    func throttleElapsed(since last: Date) -> TimeInterval { abs(timeIntervalSince(last)) }
}
