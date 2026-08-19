import Foundation

/// A foreground transition emitted by Apple's private Biome `App.InFocus` stream.
///
/// This type intentionally contains only the fields LocalHistory needs. Unknown protobuf
/// fields are skipped so newer Apple records remain readable when their schema grows.
public struct AppleBiomeFocusEvent: Equatable, Sendable {
    public let bundleIdentifier: String
    public let isForeground: Bool
    public let timestamp: Date

    public init(bundleIdentifier: String, isForeground: Bool, timestamp: Date) {
        self.bundleIdentifier = bundleIdentifier
        self.isForeground = isForeground
        self.timestamp = timestamp
    }
}

/// A non-overlapping application interval reconstructed from Apple focus transitions.
public struct AppleBiomeApplicationInterval: Equatable, Sendable {
    public let bundleIdentifier: String
    public let start: Date
    public let end: Date

    public init(bundleIdentifier: String, start: Date, end: Date) {
        self.bundleIdentifier = bundleIdentifier
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public enum AppleBiomeFormatError: Error, CustomStringConvertible, Equatable {
    case unsupportedFormat
    case malformedHeader
    case unreasonableRecordCount
    case unreasonableRecordLength
    case truncatedRecord

    public var description: String {
        switch self {
        case .unsupportedFormat: return "The Apple Biome file is not a supported SEGB stream."
        case .malformedHeader: return "The Apple Biome SEGB header is malformed."
        case .unreasonableRecordCount: return "The Apple Biome file declares an unreasonable record count."
        case .unreasonableRecordLength: return "The Apple Biome file declares an unreasonable record length."
        case .truncatedRecord: return "The Apple Biome file ends inside a declared record."
        }
    }
}

/// Native decoder for the two SEGB container versions currently used by Apple Biome.
///
/// The implementation is deliberately dependency-free. It follows the public reverse-engineering
/// work from CCL Forensics and decodes only the protobuf fields documented by the App.InFocus
/// community tooling. A format change fails closed for the affected file rather than corrupting
/// another device's Screen Time view.
public enum AppleBiomeSEGBDecoder {
    private static let appleEpochOffset: TimeInterval = 978_307_200
    private static let maximumRecordLength = 16 * 1_024 * 1_024
    private static let maximumRecordCount = 250_000

    public static func decode(_ data: Data) throws -> [AppleBiomeFocusEvent] {
        if data.count >= 32, data.prefix(4) == Data("SEGB".utf8) {
            return try decodeV2(data)
        }
        if data.count >= 56, data.subdata(in: 52..<56) == Data("SEGB".utf8) {
            return try decodeV1(data)
        }
        throw AppleBiomeFormatError.unsupportedFormat
    }

    private static func decodeV1(_ data: Data) throws -> [AppleBiomeFocusEvent] {
        guard let declaredEnd = data.uint32LE(at: 0) else {
            throw AppleBiomeFormatError.malformedHeader
        }
        let endOfData = Int(declaredEnd)
        guard endOfData >= 56, endOfData <= data.count else {
            throw AppleBiomeFormatError.malformedHeader
        }

        var cursor = 56
        var events: [AppleBiomeFocusEvent] = []
        while cursor < endOfData {
            guard cursor + 32 <= endOfData,
                  let rawLength = data.int32LE(at: cursor),
                  let state = data.int32LE(at: cursor + 4),
                  let storedCRC = data.uint32LE(at: cursor + 24)
            else {
                throw AppleBiomeFormatError.truncatedRecord
            }

            let length = Int(rawLength)
            guard length > 0, length <= maximumRecordLength else {
                throw AppleBiomeFormatError.unreasonableRecordLength
            }

            let payloadStart = cursor + 32
            let payloadEnd = payloadStart + length
            guard payloadEnd <= endOfData else {
                throw AppleBiomeFormatError.truncatedRecord
            }

            if state == 1 {
                let payload = data.subdata(in: payloadStart..<payloadEnd)
                if !payload.allSatisfy({ $0 == 0 }),
                   (storedCRC == 0 || crc32(payload) == storedCRC),
                   let event = decodeAppInFocusProtobuf(payload)
                {
                    events.append(event)
                }
            }

            cursor = align(payloadEnd, to: 8)
        }
        return events
    }

    private struct V2TrailerEntry {
        let originalIndex: Int
        let endOffset: Int
        let state: Int32
    }

    private static func decodeV2(_ data: Data) throws -> [AppleBiomeFocusEvent] {
        guard let rawCount = data.int32LE(at: 4) else {
            throw AppleBiomeFormatError.malformedHeader
        }
        let count = Int(rawCount)
        guard count >= 0, count <= maximumRecordCount else {
            throw AppleBiomeFormatError.unreasonableRecordCount
        }
        if count == 0 { return [] }

        let trailerLength = count * 16
        let trailerStart = data.count - trailerLength
        guard trailerStart >= 32 else {
            throw AppleBiomeFormatError.malformedHeader
        }

        var trailer: [V2TrailerEntry] = []
        trailer.reserveCapacity(count)
        for index in 0..<count {
            let offset = trailerStart + index * 16
            guard let rawEnd = data.int32LE(at: offset),
                  let state = data.int32LE(at: offset + 4)
            else {
                throw AppleBiomeFormatError.truncatedRecord
            }
            let endOffset = Int(rawEnd)
            guard endOffset >= 0 else { continue }
            trailer.append(V2TrailerEntry(originalIndex: index, endOffset: endOffset, state: state))
        }

        // Multiple trailer entries can refer to the same payload after Apple changes its state.
        // The last metadata row is the current state for that payload.
        var latestByEndOffset: [Int: V2TrailerEntry] = [:]
        for entry in trailer {
            if let existing = latestByEndOffset[entry.endOffset],
               existing.originalIndex > entry.originalIndex
            {
                continue
            }
            latestByEndOffset[entry.endOffset] = entry
        }
        let currentEntries = latestByEndOffset.values.sorted { $0.endOffset < $1.endOffset }

        var relativeCursor = 0
        var events: [AppleBiomeFocusEvent] = []
        for entry in currentEntries {
            guard entry.endOffset >= relativeCursor else { continue }
            let entryLength = entry.endOffset - relativeCursor
            let absoluteStart = 32 + relativeCursor
            let absoluteEnd = 32 + entry.endOffset
            guard absoluteStart >= 32, absoluteEnd <= trailerStart else {
                throw AppleBiomeFormatError.truncatedRecord
            }

            defer { relativeCursor = align(entry.endOffset, to: 4) }
            guard entry.state == 1, entryLength >= 8 else { continue }
            guard entryLength <= maximumRecordLength else {
                throw AppleBiomeFormatError.unreasonableRecordLength
            }

            guard let storedCRC = data.uint32LE(at: absoluteStart) else {
                throw AppleBiomeFormatError.truncatedRecord
            }
            let payloadStart = absoluteStart + 8
            guard payloadStart <= absoluteEnd else { continue }
            let payload = data.subdata(in: payloadStart..<absoluteEnd)
            if payload.isEmpty || payload.allSatisfy({ $0 == 0 }) { continue }
            if storedCRC != 0, crc32(payload) != storedCRC { continue }
            if let event = decodeAppInFocusProtobuf(payload) {
                events.append(event)
            }
        }
        return events
    }

    private static func decodeAppInFocusProtobuf(_ data: Data) -> AppleBiomeFocusEvent? {
        var cursor = 0
        var bundleIdentifier: String?
        var foreground: Bool?
        var cocoaTime: Double?

        while cursor < data.count {
            guard let tag = readVarint(data, cursor: &cursor) else { return nil }
            let field = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch (field, wireType) {
            case (3, 0):
                guard let value = readVarint(data, cursor: &cursor) else { return nil }
                foreground = value != 0
            case (4, 1):
                guard let bits = data.uint64LE(at: cursor) else { return nil }
                cocoaTime = Double(bitPattern: bits)
                cursor += 8
            case (6, 2):
                guard let rawLength = readVarint(data, cursor: &cursor),
                      rawLength <= UInt64(Int.max)
                else { return nil }
                let length = Int(rawLength)
                guard length >= 0, cursor + length <= data.count else { return nil }
                bundleIdentifier = String(data: data.subdata(in: cursor..<(cursor + length)), encoding: .utf8)
                cursor += length
            default:
                guard skipField(wireType: wireType, data: data, cursor: &cursor) else { return nil }
            }
        }

        guard let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundle.isEmpty,
              let cocoaTime,
              cocoaTime.isFinite
        else { return nil }

        let unixTime = cocoaTime + appleEpochOffset
        guard unixTime.isFinite,
              unixTime > 0,
              unixTime < 32_503_680_000 // year 3000 sanity bound
        else { return nil }

        return AppleBiomeFocusEvent(
            bundleIdentifier: bundle,
            isForeground: foreground ?? false,
            timestamp: Date(timeIntervalSince1970: unixTime)
        )
    }

    private static func skipField(wireType: Int, data: Data, cursor: inout Int) -> Bool {
        switch wireType {
        case 0:
            return readVarint(data, cursor: &cursor) != nil
        case 1:
            guard cursor + 8 <= data.count else { return false }
            cursor += 8
            return true
        case 2:
            guard let rawLength = readVarint(data, cursor: &cursor),
                  rawLength <= UInt64(Int.max)
            else { return false }
            let length = Int(rawLength)
            guard cursor + length <= data.count else { return false }
            cursor += length
            return true
        case 5:
            guard cursor + 4 <= data.count else { return false }
            cursor += 4
            return true
        default:
            return false
        }
    }

    private static func readVarint(_ data: Data, cursor: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < data.count, shift < 64 {
            let byte = data[cursor]
            cursor += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func align(_ value: Int, to boundary: Int) -> Int {
        guard boundary > 1 else { return value }
        let remainder = value % boundary
        return remainder == 0 ? value : value + boundary - remainder
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return crc ^ 0xffff_ffff
    }
}

public enum AppleBiomeIntervalBuilder {
    /// Stitches focus transitions into non-overlapping application intervals.
    ///
    /// - Parameters:
    ///   - events: Events from every relevant SEGB file for one physical device.
    ///   - closeOpenIntervalAt: When the latest Apple event is fresh, callers may close the
    ///     currently foreground app at `now` to make today's view live. Historical or stale
    ///     streams should pass `nil` so an unconfirmed interval is never invented.
    ///   - maximumInterval: Defensive cap for malformed or incomplete transition sequences.
    public static func intervals(
        from events: [AppleBiomeFocusEvent],
        closeOpenIntervalAt: Date? = nil,
        maximumInterval: TimeInterval = 86_400
    ) -> [AppleBiomeApplicationInterval] {
        let ordered = deduplicated(events)
        var output: [AppleBiomeApplicationInterval] = []
        var openBundle: String?
        var openStart: Date?

        func close(at end: Date) {
            guard let bundle = openBundle, let start = openStart else { return }
            let duration = end.timeIntervalSince(start)
            if duration > 0, duration <= maximumInterval {
                output.append(
                    AppleBiomeApplicationInterval(
                        bundleIdentifier: bundle,
                        start: start,
                        end: end
                    )
                )
            }
            openBundle = nil
            openStart = nil
        }

        for event in ordered {
            if event.isForeground {
                if openBundle == event.bundleIdentifier {
                    continue
                }
                if openBundle != nil {
                    close(at: event.timestamp)
                }
                openBundle = event.bundleIdentifier
                openStart = event.timestamp
            } else if openBundle == event.bundleIdentifier {
                close(at: event.timestamp)
            }
        }

        if let closeOpenIntervalAt,
           let start = openStart,
           closeOpenIntervalAt > start
        {
            close(at: closeOpenIntervalAt)
        }

        return output
    }

    private static func deduplicated(_ events: [AppleBiomeFocusEvent]) -> [AppleBiomeFocusEvent] {
        struct Key: Hashable {
            let bundle: String
            let foreground: Bool
            let milliseconds: Int64
        }

        var seen = Set<Key>()
        return events
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.bundleIdentifier != $1.bundleIdentifier {
                    return $0.bundleIdentifier < $1.bundleIdentifier
                }
                return !$0.isForeground && $1.isForeground
            }
            .filter { event in
                let key = Key(
                    bundle: event.bundleIdentifier,
                    foreground: event.isForeground,
                    milliseconds: Int64((event.timestamp.timeIntervalSince1970 * 1_000).rounded())
                )
                return seen.insert(key).inserted
            }
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func int32LE(at offset: Int) -> Int32? {
        guard let value = uint32LE(at: offset) else { return nil }
        return Int32(bitPattern: value)
    }

    func uint64LE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}
