import Foundation

/// Whole-number percentage for a stored confidence or ratio.
///
/// Values decoded from a day-memory file bypass the clamping initialisers, so a damaged
/// file can carry NaN, infinity or a huge number. `Int(_:)` traps on those; this does not.
public enum ConfidencePercent {
    public static func whole(_ value: Double) -> Int {
        guard value.isFinite else { return value > 0 ? 100 : 0 }
        return Int((min(1, max(0, value)) * 100).rounded())
    }
}
