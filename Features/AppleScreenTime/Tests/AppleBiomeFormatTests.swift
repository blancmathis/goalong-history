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

    func testDecodesScreenTimeAppUsageV1AndCanonicalizesParentBundle() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let file = makeV1([
            makeScreenTimeAppUsagePayload(
                bundle: "com.example.helper",
                parentBundle: "com.example.parent",
                starting: true,
                usageTrusted: true,
                timestamp: timestamp
            ),
        ])

        let event = try XCTUnwrap(
            AppleBiomeSEGBDecoder.decodeScreenTimeAppUsage(file).first
        )
        XCTAssertEqual(event.bundleIdentifier, "com.example.helper")
        XCTAssertEqual(event.parentBundleIdentifier, "com.example.parent")
        XCTAssertEqual(event.canonicalBundleIdentifier, "com.example.parent")
        XCTAssertTrue(event.isStarting)
        XCTAssertEqual(event.isUsageTrusted, true)
        XCTAssertEqual(event.timestamp, timestamp)
    }

    func testDecodesScreenTimeAppUsageV2WithMissingOptionalFields() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_100)
        let file = makeV2([
            makeScreenTimeAppUsagePayload(
                bundle: "com.example.standalone",
                parentBundle: nil,
                starting: false,
                usageTrusted: nil,
                timestamp: timestamp
            ),
        ])

        let event = try XCTUnwrap(
            AppleBiomeSEGBDecoder.decodeScreenTimeAppUsage(file).first
        )
        XCTAssertEqual(event.parentBundleIdentifier, nil)
        XCTAssertEqual(event.canonicalBundleIdentifier, "com.example.standalone")
        XCTAssertFalse(event.isStarting)
        XCTAssertNil(event.isUsageTrusted)
        XCTAssertEqual(event.timestamp, timestamp)
    }

    func testRejectsStructurallyValidScreenTimeAppUsageWithUnknownPayload() {
        let file = makeV1([Data([0x08])])
        XCTAssertThrowsError(try AppleBiomeSEGBDecoder.decodeScreenTimeAppUsage(file)) { error in
            XCTAssertEqual(error as? AppleBiomeFormatError, .unsupportedPayload)
        }
    }

    func testScreenTimeAppUsageKeepsDistinctOverlappingApplications() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            makeScreenTimeEvent(bundle: "com.example.one", starting: true, timestamp: start),
            makeScreenTimeEvent(
                bundle: "com.example.two",
                starting: true,
                timestamp: start.addingTimeInterval(10)
            ),
            makeScreenTimeEvent(
                bundle: "com.example.one",
                starting: false,
                timestamp: start.addingTimeInterval(40)
            ),
            makeScreenTimeEvent(
                bundle: "com.example.two",
                starting: false,
                timestamp: start.addingTimeInterval(70)
            ),
        ]

        let intervals = AppleBiomeScreenTimeAppUsageIntervalBuilder.intervals(from: events)
        XCTAssertEqual(intervals.map(\.bundleIdentifier), ["com.example.one", "com.example.two"])
        XCTAssertEqual(intervals[0].duration, 40, accuracy: 0.001)
        XCTAssertEqual(intervals[1].duration, 60, accuracy: 0.001)
    }

    func testScreenTimeAppUsageDeduplicatesRepeatedTransitionsForSameCanonicalApp() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            makeScreenTimeEvent(
                bundle: "com.example.helper",
                parentBundle: "com.example.parent",
                starting: true,
                timestamp: start
            ),
            makeScreenTimeEvent(
                bundle: "com.example.parent",
                starting: true,
                timestamp: start.addingTimeInterval(5)
            ),
            makeScreenTimeEvent(
                bundle: "com.example.helper",
                parentBundle: "com.example.parent",
                starting: false,
                timestamp: start.addingTimeInterval(60)
            ),
            makeScreenTimeEvent(
                bundle: "com.example.parent",
                starting: false,
                timestamp: start.addingTimeInterval(60)
            ),
        ]

        let intervals = AppleBiomeScreenTimeAppUsageIntervalBuilder.intervals(from: events)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].bundleIdentifier, "com.example.parent")
        XCTAssertEqual(intervals[0].duration, 60, accuracy: 0.001)
    }

    func testScreenTimeAppUsageExcludesOnlyExplicitlyUntrustedEvents() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            makeScreenTimeEvent(
                bundle: "com.example.untrusted",
                starting: true,
                usageTrusted: false,
                timestamp: start
            ),
            makeScreenTimeEvent(
                bundle: "com.example.untrusted",
                starting: false,
                usageTrusted: false,
                timestamp: start.addingTimeInterval(30)
            ),
            makeScreenTimeEvent(
                bundle: "com.example.legacy",
                starting: true,
                usageTrusted: nil,
                timestamp: start.addingTimeInterval(40)
            ),
            makeScreenTimeEvent(
                bundle: "com.example.legacy",
                starting: false,
                usageTrusted: nil,
                timestamp: start.addingTimeInterval(80)
            ),
        ]

        let intervals = AppleBiomeScreenTimeAppUsageIntervalBuilder.intervals(from: events)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].bundleIdentifier, "com.example.legacy")
        XCTAssertEqual(intervals[0].duration, 40, accuracy: 0.001)
    }

    func testScreenTimeAppUsageClosesOpenIntervalOnlyAtExplicitBound() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = makeScreenTimeEvent(
            bundle: "com.example.live",
            starting: true,
            timestamp: start
        )

        XCTAssertTrue(
            AppleBiomeScreenTimeAppUsageIntervalBuilder.intervals(from: [event]).isEmpty
        )
        let bounded = AppleBiomeScreenTimeAppUsageIntervalBuilder.intervals(
            from: [event],
            closeOpenIntervalAt: start.addingTimeInterval(120),
            maximumInterval: 300
        )
        XCTAssertEqual(bounded.count, 1)
        XCTAssertEqual(bounded[0].duration, 120, accuracy: 0.001)
        XCTAssertTrue(
            AppleBiomeScreenTimeAppUsageIntervalBuilder.intervals(
                from: [event],
                closeOpenIntervalAt: start.addingTimeInterval(120),
                maximumInterval: 60
            ).isEmpty
        )
    }

    func testFreshEventForAnotherAppDoesNotExtendStaleOpenInterval() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            makeScreenTimeEvent(
                bundle: "com.example.stale",
                starting: true,
                timestamp: now.addingTimeInterval(-3_600)
            ),
            makeScreenTimeEvent(
                bundle: "com.example.fresh",
                starting: true,
                timestamp: now.addingTimeInterval(-60)
            ),
            makeScreenTimeEvent(
                bundle: "com.example.fresh",
                starting: false,
                timestamp: now.addingTimeInterval(-30)
            ),
        ]

        let intervals = AppleBiomeScreenTimeAppUsageIntervalBuilder.intervals(
            from: events,
            closeOpenIntervalAt: now,
            maximumOpenIntervalAge: 20 * 60
        )

        XCTAssertEqual(intervals.map(\.bundleIdentifier), ["com.example.fresh"])
        XCTAssertEqual(intervals[0].duration, 30, accuracy: 0.001)
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

    private func makeScreenTimeAppUsagePayload(
        bundle: String,
        parentBundle: String?,
        starting: Bool,
        usageTrusted: Bool?,
        timestamp: Date
    ) -> Data {
        var output = Data()
        appendVarint(UInt64((1 << 3) | 0), to: &output)
        appendVarint(starting ? 1 : 0, to: &output)
        appendVarint(UInt64((2 << 3) | 1), to: &output)
        output.append(uint64LE(timestamp.timeIntervalSince1970.bitPattern))
        appendString(bundle, field: 3, to: &output)
        if let parentBundle {
            appendString(parentBundle, field: 4, to: &output)
        }
        if let usageTrusted {
            appendVarint(UInt64((5 << 3) | 0), to: &output)
            appendVarint(usageTrusted ? 1 : 0, to: &output)
        }
        return output
    }

    private func makeScreenTimeEvent(
        bundle: String,
        parentBundle: String? = nil,
        starting: Bool,
        usageTrusted: Bool? = true,
        timestamp: Date
    ) -> AppleBiomeScreenTimeAppUsageEvent {
        AppleBiomeScreenTimeAppUsageEvent(
            bundleIdentifier: bundle,
            parentBundleIdentifier: parentBundle,
            isStarting: starting,
            isUsageTrusted: usageTrusted,
            timestamp: timestamp
        )
    }

    private func appendString(_ value: String, field: Int, to data: inout Data) {
        let valueData = Data(value.utf8)
        appendVarint(UInt64((field << 3) | 2), to: &data)
        appendVarint(UInt64(valueData.count), to: &data)
        data.append(valueData)
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
