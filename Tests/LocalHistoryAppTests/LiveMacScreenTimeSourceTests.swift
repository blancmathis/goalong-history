#if os(macOS)
    import AppleScreenTime
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class LiveMacScreenTimeSourceTests: XCTestCase {
        func testTracksForegroundAppsAcrossSleepAndWake() throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let day = try fixture.dayStart()
            let appA = fixture.app("Editor", "com.example.editor", pid: 101)
            let appB = fixture.app("Browser", "com.example.browser", pid: 202)

            try fixture.write([
                fixture.event(.recorderStarted, at: day),
                fixture.event(.applicationActivated, at: day.addingTimeInterval(10), app: appA),
                fixture.event(.heartbeat, at: day.addingTimeInterval(70), app: appA),
                fixture.event(.applicationActivated, at: day.addingTimeInterval(130), app: appB),
                fixture.event(.systemSleep, at: day.addingTimeInterval(190)),
                fixture.event(.systemWake, at: day.addingTimeInterval(250)),
                fixture.event(.applicationActivated, at: day.addingTimeInterval(260), app: appB),
                fixture.event(.heartbeat, at: day.addingTimeInterval(320), app: appB),
            ], for: day)

            let report = try fixture.report(for: day, now: day.addingTimeInterval(350))
            XCTAssertEqual(fixture.totalDuration(report), 270, accuracy: 0.001)
            XCTAssertEqual(
                fixture.applicationDuration("com.example.editor", in: report),
                120,
                accuracy: 0.001
            )
            XCTAssertEqual(
                fixture.applicationDuration("com.example.browser", in: report),
                150,
                accuracy: 0.001
            )
        }

        func testCountsPrivateCoverageWithoutRevealingItsApplication() throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let day = try fixture.dayStart()
            let browser = fixture.app("Browser", "com.example.browser", pid: 303)

            try fixture.write([
                fixture.event(.recorderStarted, at: day),
                fixture.event(.applicationActivated, at: day.addingTimeInterval(10), app: browser),
                fixture.event(
                    .captureSuppressed,
                    at: day.addingTimeInterval(70),
                    app: browser,
                    suppression: .privateBrowserWindow
                ),
                fixture.event(.captureResumed, at: day.addingTimeInterval(130), app: browser),
                fixture.event(.heartbeat, at: day.addingTimeInterval(190), app: browser),
            ], for: day)

            let report = try fixture.report(for: day, now: day.addingTimeInterval(200))
            XCTAssertEqual(fixture.totalDuration(report), 190, accuracy: 0.001)
            XCTAssertEqual(
                fixture.applicationDuration("com.example.browser", in: report),
                130,
                accuracy: 0.001
            )
            XCTAssertEqual(
                fixture.totalDuration(report)
                    - fixture.applicationDuration("com.example.browser", in: report),
                60,
                accuracy: 0.001
            )
        }

        func testCapsAnUnconfirmedTrailingForegroundInterval() throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let day = try fixture.dayStart()
            let editor = fixture.app("Editor", "com.example.editor", pid: 404)

            try fixture.write([
                fixture.event(.recorderStarted, at: day),
                fixture.event(.applicationActivated, at: day.addingTimeInterval(10), app: editor),
            ], for: day)

            let report = try fixture.report(for: day, now: day.addingTimeInterval(1_000))
            XCTAssertEqual(fixture.totalDuration(report), 90, accuracy: 0.001)
            XCTAssertEqual(
                fixture.applicationDuration("com.example.editor", in: report),
                90,
                accuracy: 0.001
            )
        }

        func testTailsOnlyNewJSONLLinesAndRecalculatesTheCurrentDay() throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let day = try fixture.dayStart()
            let editor = fixture.app("Editor", "com.example.editor", pid: 505)
            let browser = fixture.app("Browser", "com.example.browser", pid: 606)

            try fixture.write([
                fixture.event(.recorderStarted, at: day),
                fixture.event(.applicationActivated, at: day.addingTimeInterval(10), app: editor),
                fixture.event(.heartbeat, at: day.addingTimeInterval(70), app: editor),
            ], for: day)

            let source = fixture.source()
            let first = try fixture.report(
                from: source,
                for: day,
                now: day.addingTimeInterval(100)
            )
            XCTAssertEqual(fixture.totalDuration(first), 90, accuracy: 0.001)

            try fixture.append([
                fixture.event(.applicationActivated, at: day.addingTimeInterval(130), app: browser),
                fixture.event(.heartbeat, at: day.addingTimeInterval(190), app: browser),
            ], for: day)

            let second = try fixture.report(
                from: source,
                for: day,
                now: day.addingTimeInterval(220)
            )
            XCTAssertEqual(fixture.totalDuration(second), 210, accuracy: 0.001)
            XCTAssertEqual(
                fixture.applicationDuration("com.example.editor", in: second),
                120,
                accuracy: 0.001
            )
            XCTAssertEqual(
                fixture.applicationDuration("com.example.browser", in: second),
                90,
                accuracy: 0.001
            )
        }
    }

    private final class Fixture {
        let root: URL
        let eventsDirectory: URL
        let calendar: Calendar

        private let fileManager = FileManager.default
        private let encoder: JSONEncoder
        private let formatter: DateFormatter

        init() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            self.calendar = calendar

            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LiveMacScreenTimeTests-\(UUID().uuidString)", isDirectory: true)
            eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
            try fileManager.createDirectory(
                at: eventsDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            self.encoder = encoder

            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            self.formatter = formatter
        }

        func remove() {
            try? fileManager.removeItem(at: root)
        }

        func dayStart() throws -> Date {
            try XCTUnwrap(
                calendar.date(
                    from: DateComponents(
                        calendar: calendar,
                        timeZone: calendar.timeZone,
                        year: 2026,
                        month: 8,
                        day: 19
                    )
                )
            )
        }

        func source() -> LiveMacScreenTimeSource {
            LiveMacScreenTimeSource(
                deviceID: "test-device",
                deviceName: "Test Mac",
                fileManager: fileManager,
                calendar: calendar,
                eventsDirectory: eventsDirectory
            )
        }

        func app(_ name: String, _ bundleIdentifier: String, pid: Int32) -> AppSnapshot {
            AppSnapshot(
                name: name,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: pid
            )
        }

        func event(
            _ kind: EventKind,
            at timestamp: Date,
            app: AppSnapshot? = nil,
            suppression: SuppressionReason? = nil
        ) -> HistoryEvent {
            HistoryEvent(
                sessionID: "test-session",
                timestamp: timestamp,
                kind: kind,
                app: app,
                suppressionReason: suppression
            )
        }

        func write(_ events: [HistoryEvent], for day: Date) throws {
            var data = Data()
            for event in events {
                data.append(try encoder.encode(event))
                data.append(0x0A)
            }
            try data.write(to: fileURL(for: day), options: [.atomic])
        }

        func append(_ events: [HistoryEvent], for day: Date) throws {
            let file = fileURL(for: day)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            for event in events {
                var data = try encoder.encode(event)
                data.append(0x0A)
                try handle.write(contentsOf: data)
            }
            try handle.close()
        }

        func report(for day: Date, now: Date) throws -> AppleScreenTimeDeviceReport {
            try report(from: source(), for: day, now: now)
        }

        func report(
            from source: LiveMacScreenTimeSource,
            for day: Date,
            now: Date
        ) throws -> AppleScreenTimeDeviceReport {
            let stored = try XCTUnwrap(source.storedExport(for: day, now: now))
            return try XCTUnwrap(stored.envelope.reports.first)
        }

        func totalDuration(_ report: AppleScreenTimeDeviceReport) -> TimeInterval {
            report.segments.reduce(0) { $0 + $1.totalScreenOnDuration }
        }

        func applicationDuration(
            _ bundleIdentifier: String,
            in report: AppleScreenTimeDeviceReport
        ) -> TimeInterval {
            report.segments
                .flatMap(\.applications)
                .filter { $0.bundleIdentifier == bundleIdentifier }
                .reduce(0) { $0 + $1.duration }
        }

        private func fileURL(for day: Date) -> URL {
            eventsDirectory.appendingPathComponent(formatter.string(from: day) + ".jsonl")
        }
    }
#endif
