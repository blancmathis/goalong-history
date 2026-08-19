import Foundation
import XCTest
@testable import AppleScreenTime

final class AppleBiomeFormatTests: XCTestCase {
    func testDecodesSEGBV1AndStitchesApplicationInterval() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let file = makeV1([
            makeFocusPayload(bundle: "com.example.focus", foreground: true, timestamp: start),
            makeFocusPayload(bundle: "com.example.focus", foreground: false, timestamp: start.addingTimeInterval(95)),
        ])

        let events = try AppleBiomeSEGBDecoder.decode(file)
        XCTAssertEqual(events.count, 2)
        let intervals = AppleBiomeIntervalBuilder.intervals(from: events)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].bundleIdentifier, "com.example.focus")
        XCTAssertEqual(intervals[0].duration, 95, accuracy: 0.001)
    }

    func testDecodesSEGBV2AndImplicitlyClosesOnApplicationSwitch() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let file = makeV2([
            makeFocusPayload(bundle: "com.example.one", foreground: true, timestamp: start),
            makeFocusPayload(bundle: "com.example.two", foreground: true, timestamp: start.addingTimeInterval(40)),
            makeFocusPayload(bundle: "com.example.two", foreground: false, timestamp: start.addingTimeInterval(100)),
        ])

        let events = try AppleBiomeSEGBDecoder.decode(file)
        let intervals = AppleBiomeIntervalBuilder.intervals(from: events)
        XCTAssertEqual(intervals.map(\.bundleIdentifier), ["com.example.one", "com.example.two"])
        XCTAssertEqual(intervals[0].duration, 40, accuracy: 0.001)
        XCTAssertEqual(intervals[1].duration, 60, accuracy: 0.001)
    }

    func testCanCloseFreshOpenAppleIntervalAtNow() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            AppleBiomeFocusEvent(
                bundleIdentifier: "com.example.live",
                isForeground: true,
                timestamp: start
            )
        ]

        XCTAssertTrue(AppleBiomeIntervalBuilder.intervals(from: events).isEmpty)
        let live = AppleBiomeIntervalBuilder.intervals(
            from: events,
            closeOpenIntervalAt: start.addingTimeInterval(120)
        )
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].duration, 120, accuracy: 0.001)
    }

    func testRejectsUnknownAndTruncatedSEGBFiles() {
        XCTAssertThrowsError(try AppleBiomeSEGBDecoder.decode(Data("not-segb".utf8)))

        var truncated = Data(repeating: 0, count: 56)
        truncated.replaceSubrange(52..<56, with: Data("SEGB".utf8))
        truncated.replaceSubrange(0..<4, with: uint32LE(120))
        XCTAssertThrowsError(try AppleBiomeSEGBDecoder.decode(truncated))
    }

    private func makeFocusPayload(bundle: String, foreground: Bool, timestamp: Date) -> Data {
        var output = Data()
        appendVarint(UInt64((3 << 3) | 0), to: &output)
        appendVarint(foreground ? 1 : 0, to: &output)
        appendVarint(UInt64((4 << 3) | 1), to: &output)
        output.append(uint64LE((timestamp.timeIntervalSince1970 - 978_307_200).bitPattern))
        let bundleData = Data(bundle.utf8)
        appendVarint(UInt64((6 << 3) | 2), to: &output)
        appendVarint(UInt64(bundleData.count), to: &output)
        output.append(bundleData)
        return output
    }

    private func makeV1(_ payloads: [Data]) -> Data {
        var output = Data(repeating: 0, count: 56)
        output.replaceSubrange(52..<56, with: Data("SEGB".utf8))
        for payload in payloads {
            output.append(int32LE(Int32(payload.count)))
            output.append(int32LE(1))
            output.append(Data(repeating: 0, count: 16))
            output.append(uint32LE(0))
            output.append(int32LE(0))
            output.append(payload)
            output.append(Data(repeating: 0, count: aligned(output.count, to: 8) - output.count))
        }
        output.replaceSubrange(0..<4, with: uint32LE(UInt32(output.count)))
        return output
    }

    private func makeV2(_ payloads: [Data]) -> Data {
        var output = Data("SEGB".utf8)
        output.append(int32LE(Int32(payloads.count)))
        output.append(Data(repeating: 0, count: 24))

        var relativeEnd = 0
        var trailer: [(Int32, Int32)] = []
        for payload in payloads {
            output.append(uint32LE(0))
            output.append(int32LE(0))
            output.append(payload)
            relativeEnd += 8 + payload.count
            trailer.append((Int32(relativeEnd), 1))
            let alignedEnd = aligned(relativeEnd, to: 4)
            output.append(Data(repeating: 0, count: alignedEnd - relativeEnd))
            relativeEnd = alignedEnd
        }

        for (endOffset, state) in trailer {
            output.append(int32LE(endOffset))
            output.append(int32LE(state))
            output.append(Data(repeating: 0, count: 8))
        }
        return output
    }

    private func appendVarint(_ rawValue: UInt64, to data: inout Data) {
        var value = rawValue
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private func uint32LE(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    private func int32LE(_ value: Int32) -> Data {
        uint32LE(UInt32(bitPattern: value))
    }

    private func uint64LE(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xff) })
    }

    private func aligned(_ value: Int, to boundary: Int) -> Int {
        let remainder = value % boundary
        return remainder == 0 ? value : value + boundary - remainder
    }
}
