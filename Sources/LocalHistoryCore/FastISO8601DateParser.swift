import Foundation

/// Allocation-light parser for the canonical UTC timestamps written by Goalong.
/// Older or non-canonical ISO-8601 values deliberately fall back to Foundation
/// at the caller, preserving compatibility while avoiding ICU work per JSONL row.
package enum FastISO8601DateParser {
    package static func parseCanonicalUTC(_ raw: String) -> Date? {
        let bytes = Array(raw.utf8)
        guard bytes.count >= 20,
            bytes[4] == 45, bytes[7] == 45,
            bytes[10] == 84 || bytes[10] == 116,
            bytes[13] == 58, bytes[16] == 58
        else { return nil }

        guard let year = digits(bytes, 0, 4),
            let month = digits(bytes, 5, 2),
            let day = digits(bytes, 8, 2),
            let hour = digits(bytes, 11, 2),
            let minute = digits(bytes, 14, 2),
            let second = digits(bytes, 17, 2),
            (1...12).contains(month),
            (1...daysInMonth(month, year: year)).contains(day),
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...59).contains(second)
        else { return nil }

        var fraction = 0.0
        var cursor = 19
        if bytes[cursor] == 46 {
            cursor += 1
            let fractionStart = cursor
            var scale = 0.1
            while cursor < bytes.count, bytes[cursor] >= 48, bytes[cursor] <= 57 {
                fraction += Double(bytes[cursor] - 48) * scale
                scale *= 0.1
                cursor += 1
            }
            guard cursor > fractionStart else { return nil }
        }
        guard cursor == bytes.count - 1, bytes[cursor] == 90 || bytes[cursor] == 122 else {
            return nil
        }

        let days = daysSinceUnixEpoch(year: year, month: month, day: day)
        let seconds = Int64(days) * 86_400
            + Int64(hour * 3_600 + minute * 60 + second)
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    private static func digits(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start >= 0, count > 0, start + count <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[start..<(start + count)] {
            guard byte >= 48, byte <= 57 else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = year.isMultiple(of: 4)
                && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Howard Hinnant's civil-date conversion, shifted to the Unix epoch.
    private static func daysSinceUnixEpoch(year: Int, month: Int, day: Int) -> Int {
        var adjustedYear = year
        if month <= 2 { adjustedYear -= 1 }
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
