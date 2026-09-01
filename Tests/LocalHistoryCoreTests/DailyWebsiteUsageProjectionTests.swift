import Foundation
import XCTest

@testable import LocalHistoryCore

final class DailyWebsiteUsageProjectionTests: XCTestCase {
    func testProjectionRanksDomainsMergesBrowsersAndRejectsInternalOrIdleRows() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixtureStart)
        var projection = DailyWebsiteUsageAccumulator(
            day: day,
            currentTime: day.addingTimeInterval(600),
            calendar: calendar
        )
        let events = [
            websiteEvent(
                at: day,
                app: "Aside",
                bundleIdentifier: "at.studio.AsideBrowser",
                URL: "https://x.com/home",
                host: "x.com",
                pointer: true
            ),
            websiteEvent(
                at: day.addingTimeInterval(30),
                app: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                URL: "https://www.x.com/search",
                host: "www.x.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(90),
                app: "ChatGPT",
                bundleIdentifier: "com.openai.codex",
                URL: "app://conversation/123",
                host: "-"
            ),
            websiteEvent(
                at: day.addingTimeInterval(100),
                app: "Aside",
                bundleIdentifier: "at.studio.AsideBrowser",
                URL: "https://chatgpt.com/",
                host: "chatgpt.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(120),
                kind: .heartbeat,
                app: "Aside",
                bundleIdentifier: "at.studio.AsideBrowser",
                URL: "https://chatgpt.com/",
                host: "chatgpt.com",
                metadata: ["idle_seconds": "120"]
            ),
            websiteEvent(
                at: day.addingTimeInterval(180),
                app: "Finder",
                bundleIdentifier: "com.apple.finder",
                URL: nil,
                host: nil
            ),
            websiteEvent(
                at: day.addingTimeInterval(200),
                app: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                URL: "chrome://newtab/",
                host: "newtab"
            ),
            websiteEvent(
                at: day.addingTimeInterval(220),
                app: "Finder",
                bundleIdentifier: "com.apple.finder",
                URL: nil,
                host: nil
            ),
        ]

        for event in events { projection.ingest(event) }
        let result = projection.finish()

        XCTAssertEqual(result.map(\.host), ["x.com", "chatgpt.com"])
        XCTAssertEqual(result[0].foregroundSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(result[0].sourceApplications, ["Google Chrome", "Aside"])
        XCTAssertEqual(result[0].sourceUsage.map(\.applicationName), ["Google Chrome", "Aside"])
        XCTAssertEqual(result[0].sourceUsage.map(\.foregroundSeconds), [60, 30])
        XCTAssertEqual(result[0].sourceUsage.map(\.eventCount), [1, 1])
        XCTAssertEqual(result[0].foregroundSeconds, result[0].sourceUsage.reduce(0) {
            $0 + $1.foregroundSeconds
        }, accuracy: 0.001)
        XCTAssertEqual(result[0].activeMinuteCount, 1)
        XCTAssertEqual(result[1].foregroundSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(result[1].sourceApplications, ["Aside"])
        XCTAssertEqual(result[1].sourceUsage.first?.foregroundSeconds, 20)
        XCTAssertFalse(result.contains { ["-", "newtab"].contains($0.host) })
        XCTAssertFalse(projection.wasTruncated)
    }

    func testHistoricalTailStopsAtTheCivilDayBoundary() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixtureStart)
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        var projection = DailyWebsiteUsageAccumulator(
            day: day,
            currentTime: dayEnd.addingTimeInterval(3_600),
            calendar: calendar
        )
        projection.ingest(
            websiteEvent(
                at: dayEnd.addingTimeInterval(-10),
                app: "Safari",
                bundleIdentifier: "com.apple.Safari",
                URL: "https://example.com/",
                host: "example.com"
            )
        )

        let result = projection.finish()

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].foregroundSeconds, 10, accuracy: 0.001)
    }

    func testLegacyCodableRowDefaultsPerBrowserBreakdownToEmpty() throws {
        let data = Data(
            #"{"host":"example.com","foregroundSeconds":30,"activeMinuteCount":1,"eventCount":1,"sourceApplications":["Safari"],"primaryBundleIdentifier":"com.apple.Safari","category":"web","identityProofAvailable":true}"#.utf8
        )

        let decoded = try JSONDecoder().decode(DailyWebsiteUsage.self, from: data)

        XCTAssertEqual(decoded.host, "example.com")
        XCTAssertEqual(decoded.sourceApplications, ["Safari"])
        XCTAssertEqual(decoded.sourceUsage, [])
    }

    func testSourceIdentityUsesBundleAndKeepsDifferentBundlesSeparate() {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixtureStart)
        var projection = DailyWebsiteUsageAccumulator(
            day: day,
            currentTime: day.addingTimeInterval(180),
            calendar: calendar
        )
        let events = [
            websiteEvent(
                at: day,
                app: "Chrome",
                bundleIdentifier: "com.google.Chrome",
                URL: "https://example.com/one",
                host: "example.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(30),
                app: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                URL: "https://example.com/two",
                host: "example.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(60),
                app: "Chrome",
                bundleIdentifier: "com.example.second-browser",
                URL: "https://example.com/three",
                host: "example.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(90),
                app: "Finder",
                bundleIdentifier: "com.apple.finder",
                URL: nil,
                host: nil
            ),
        ]
        for event in events { projection.ingest(event) }

        let sources = projection.finish().first?.sourceUsage ?? []

        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(
            sources.first { $0.bundleIdentifier == "com.google.Chrome" }?.foregroundSeconds,
            60
        )
        XCTAssertEqual(
            sources.first { $0.bundleIdentifier == "com.google.Chrome" }?.eventCount,
            2
        )
        XCTAssertEqual(
            sources.first { $0.bundleIdentifier == "com.example.second-browser" }?
                .foregroundSeconds,
            30
        )
    }

    func testReaderStreamsOnlyTheOriginalDayJournalAndReportsMissingSourceClearly() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("goalong-websites-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try fileManager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)

        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixtureStart)
        let events = [
            websiteEvent(
                at: day,
                app: "Aside",
                bundleIdentifier: "at.studio.AsideBrowser",
                URL: "https://x.com/home",
                host: "x.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(30),
                app: "Finder",
                bundleIdentifier: "com.apple.finder",
                URL: nil,
                host: nil
            ),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var journal = Data()
        for event in events {
            journal.append(try encoder.encode(event))
            journal.append(0x0A)
        }
        let fileName = Self.dayFormatter.string(from: day) + ".jsonl"
        let journalURL = eventsDirectory.appendingPathComponent(fileName)
        try journal.write(to: journalURL)
        let before = try Data(contentsOf: journalURL)

        let reader = HistoryLocalStoreReader(rootDirectory: root)
        let loaded = reader.loadDailyWebsiteUsage(
            day: day,
            currentTime: day.addingTimeInterval(300)
        )

        XCTAssertEqual(loaded.state, .ready)
        XCTAssertEqual(loaded.sourceRowCount, 2)
        XCTAssertEqual(loaded.sourceEventCount, 2)
        XCTAssertEqual(loaded.websites.map(\.host), ["x.com"])
        XCTAssertEqual(loaded.websites[0].foregroundSeconds, 30, accuracy: 0.001)
        XCTAssertGreaterThan(loaded.sourceBytesRead, 0)
        XCTAssertEqual(try Data(contentsOf: journalURL), before)

        let missingDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: day))
        XCTAssertEqual(reader.loadDailyWebsiteUsage(day: missingDay).state, .noSourceForDay)

        let missingRoot = root.appendingPathComponent("absent", isDirectory: true)
        XCTAssertEqual(
            HistoryLocalStoreReader(rootDirectory: missingRoot)
                .loadDailyWebsiteUsage(day: day).state,
            .sourceUnavailable
        )
    }

    func testReaderAndDashboardProjectionIgnoreHealthyMaintenanceBoundariesEqually() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("goalong-websites-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try fileManager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)

        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixtureStart)
        let events = [
            websiteEvent(
                at: day,
                app: "Aside",
                bundleIdentifier: "at.studio.AsideBrowser",
                URL: "https://x.com/home",
                host: "x.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(10),
                kind: .recorderHealth,
                app: "Goalong History",
                bundleIdentifier: "ai.goalong.localhistory",
                URL: nil,
                host: nil,
                metadata: ["observation_gap": "false"]
            ),
            websiteEvent(
                at: day.addingTimeInterval(20),
                kind: .permissionStatus,
                app: "Goalong History",
                bundleIdentifier: "ai.goalong.localhistory",
                URL: nil,
                host: nil,
                metadata: ["accessibility": "true", "input_monitoring": "true"]
            ),
            websiteEvent(
                at: day.addingTimeInterval(60),
                app: "Finder",
                bundleIdentifier: "com.apple.finder",
                URL: nil,
                host: nil
            ),
        ]
        let journalURL = eventsDirectory.appendingPathComponent(
            Self.dayFormatter.string(from: day) + ".jsonl"
        )
        try writeJournal(events, to: journalURL)

        var dashboardProjection = DailyWebsiteUsageAccumulator(
            day: day,
            currentTime: day.addingTimeInterval(300),
            calendar: calendar
        )
        for event in events where event.isDerivedAnalysisEvidence {
            dashboardProjection.ingest(event)
        }
        let dashboardWebsites = dashboardProjection.finish()
        let loaded = HistoryLocalStoreReader(rootDirectory: root).loadDailyWebsiteUsage(
            day: day,
            currentTime: day.addingTimeInterval(300)
        )

        XCTAssertEqual(loaded.state, .ready)
        XCTAssertEqual(loaded.sourceRowCount, 4)
        XCTAssertEqual(loaded.sourceEventCount, 2)
        XCTAssertEqual(loaded.websites, dashboardWebsites)
        XCTAssertEqual(
            try XCTUnwrap(loaded.websites.first).foregroundSeconds,
            60,
            accuracy: 0.001
        )
    }

    func testProjectionBoundsHostsStringsCategoriesAndActiveMinutes() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixtureStart)
        let tightLimits = DailyWebsiteUsageLimits(
            maximumHosts: 1,
            maximumSourceApplicationsPerHost: 1,
            maximumCategoriesPerHost: 1,
            maximumSourceRows: 10,
            maximumSourceBytes: 1 * 1_024 * 1_024,
            maximumRetainedBytes: 1_024,
            maximumReadSeconds: 1
        )
        var hostBound = DailyWebsiteUsageAccumulator(
            day: day,
            currentTime: day.addingTimeInterval(300),
            calendar: calendar,
            limits: tightLimits
        )
        hostBound.ingest(
            websiteEvent(
                at: day,
                app: "Aside",
                bundleIdentifier: "at.studio.AsideBrowser",
                URL: "https://one.example/",
                host: "one.example"
            )
        )
        hostBound.ingest(
            websiteEvent(
                at: day.addingTimeInterval(60),
                app: "Safari",
                bundleIdentifier: "com.apple.Safari",
                URL: "https://two.example/",
                host: "two.example"
            )
        )
        hostBound.ingest(
            websiteEvent(
                at: day.addingTimeInterval(120),
                app: "Finder",
                bundleIdentifier: "com.apple.finder",
                URL: nil,
                host: nil
            )
        )
        XCTAssertEqual(hostBound.finish().map(\.host), ["one.example"])
        XCTAssertTrue(hostBound.wasTruncated)
        XCTAssertLessThanOrEqual(hostBound.peakEstimatedRetainedBytes, 1_024)

        var stringBound = DailyWebsiteUsageAccumulator(
            day: day,
            currentTime: day.addingTimeInterval(300),
            calendar: calendar
        )
        stringBound.ingest(
            websiteEvent(
                at: day,
                app: String(repeating: "a", count: 129),
                bundleIdentifier: String(repeating: "b", count: 256),
                URL: "https://bounded.example/",
                host: "bounded.example",
                category: String(repeating: "c", count: 65)
            )
        )
        stringBound.ingest(
            websiteEvent(
                at: day.addingTimeInterval(60),
                app: "Finder",
                bundleIdentifier: "com.apple.finder",
                URL: nil,
                host: nil
            )
        )
        let stringResult = stringBound.finish()
        XCTAssertTrue(stringBound.wasTruncated)
        XCTAssertEqual(stringResult.first?.sourceApplications, [])
        XCTAssertEqual(stringResult.first?.sourceUsage, [])
        XCTAssertNil(stringResult.first?.primaryBundleIdentifier)
        XCTAssertNil(stringResult.first?.category)
        XCTAssertNil(
            DailyWebsiteUsageAccumulator.displayableHost(
                String(repeating: "a", count: 250) + ".com"
            )
        )

        let minuteLimits = DailyWebsiteUsageLimits(
            maximumHosts: 1,
            maximumSourceApplicationsPerHost: 1,
            maximumCategoriesPerHost: 1,
            maximumSourceRows: 2_000,
            maximumSourceBytes: 1 * 1_024 * 1_024,
            maximumRetainedBytes: 1_024,
            maximumReadSeconds: 1
        )
        var minuteProjection = DailyWebsiteUsageAccumulator(
            day: day,
            currentTime: day.addingTimeInterval(90_000),
            calendar: calendar,
            limits: minuteLimits
        )
        for minute in 0..<1_440 {
            minuteProjection.ingest(
                websiteEvent(
                    at: day.addingTimeInterval(TimeInterval(minute * 60)),
                    app: "Aside",
                    bundleIdentifier: "at.studio.AsideBrowser",
                    URL: "https://x.com/home",
                    host: "x.com",
                    pointer: true
                )
            )
        }
        let minuteResult = minuteProjection.finish()
        XCTAssertEqual(minuteResult.first?.activeMinuteCount, 1_440)
        XCTAssertFalse(minuteProjection.wasTruncated)
        XCTAssertLessThanOrEqual(minuteProjection.peakEstimatedRetainedBytes, 1_024)
    }

    func testReaderRejectsPartialResultsAtRowByteAndTimeBounds() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("goalong-websites-bounds-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let eventsDirectory = root.appendingPathComponent("events", isDirectory: true)
        try fileManager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: fixtureStart)
        let events = [
            websiteEvent(
                at: day,
                app: "Aside",
                bundleIdentifier: "at.studio.AsideBrowser",
                URL: "https://x.com/home",
                host: "x.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(30),
                app: "Aside",
                bundleIdentifier: "at.studio.AsideBrowser",
                URL: "https://chatgpt.com/",
                host: "chatgpt.com"
            ),
            websiteEvent(
                at: day.addingTimeInterval(60),
                app: "Finder",
                bundleIdentifier: "com.apple.finder",
                URL: nil,
                host: nil
            ),
        ]
        let journalURL = eventsDirectory.appendingPathComponent(
            Self.dayFormatter.string(from: day) + ".jsonl"
        )
        try writeJournal(events, to: journalURL)
        let sourceBytes = Int64(try Data(contentsOf: journalURL).count)
        let reader = HistoryLocalStoreReader(rootDirectory: root)

        let rowBound = reader.loadDailyWebsiteUsage(
            day: day,
            limits: testLimits(maximumSourceRows: 1, maximumSourceBytes: sourceBytes + 1)
        )
        XCTAssertEqual(rowBound.state, .bounded)
        XCTAssertTrue(rowBound.websites.isEmpty)
        XCTAssertTrue(rowBound.issues.contains { $0.message.contains("row safety limit") })

        let byteBound = reader.loadDailyWebsiteUsage(
            day: day,
            limits: testLimits(
                maximumSourceRows: 100,
                maximumSourceBytes: max(1, sourceBytes / 2)
            )
        )
        XCTAssertEqual(byteBound.state, .bounded)
        XCTAssertTrue(byteBound.websites.isEmpty)
        XCTAssertTrue(byteBound.issues.contains { $0.message.contains("byte safety limit") })

        let timeBound = reader.loadDailyWebsiteUsage(
            day: day,
            limits: DailyWebsiteUsageLimits(
                maximumHosts: 8,
                maximumSourceApplicationsPerHost: 2,
                maximumCategoriesPerHost: 2,
                maximumSourceRows: 100,
                maximumSourceBytes: sourceBytes + 1,
                maximumRetainedBytes: 8 * 1_024,
                maximumReadSeconds: 0
            )
        )
        XCTAssertEqual(timeBound.state, .cancelled)
        XCTAssertTrue(timeBound.websites.isEmpty)
    }

    private func websiteEvent(
        at timestamp: Date,
        kind: EventKind = .windowChanged,
        app: String,
        bundleIdentifier: String,
        URL: String?,
        host: String?,
        pointer: Bool = false,
        category: String = "web",
        metadata: [String: String]? = nil
    ) -> HistoryEvent {
        HistoryEvent(
            schemaVersion: 4,
            id: UUID().uuidString,
            sessionID: "website-test",
            timestamp: timestamp,
            kind: kind,
            app: AppSnapshot(
                name: app,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: 42
            ),
            window: nil,
            element: nil,
            url: URL.map { URLSnapshot(value: $0, host: host, redactionApplied: true) },
            pointer: pointer
                ? PointerSnapshot(button: "left", x: 1, y: 1, clickCount: 1)
                : nil,
            keyboard: nil,
            scroll: nil,
            inputOrigin: nil,
            semanticContext: nil,
            classification: LocalClassification(
                category: category,
                isWork: true,
                confidence: 0.8,
                classifierVersion: "test"
            ),
            suppressionReason: nil,
            message: nil,
            metadata: metadata,
            integrity: nil
        )
    }

    private func writeJournal(_ events: [HistoryEvent], to URL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var journal = Data()
        for event in events {
            journal.append(try encoder.encode(event))
            journal.append(0x0A)
        }
        try journal.write(to: URL)
    }

    private func testLimits(
        maximumSourceRows: Int,
        maximumSourceBytes: Int64
    ) -> DailyWebsiteUsageLimits {
        DailyWebsiteUsageLimits(
            maximumHosts: 8,
            maximumSourceApplicationsPerHost: 2,
            maximumCategoriesPerHost: 2,
            maximumSourceRows: maximumSourceRows,
            maximumSourceBytes: maximumSourceBytes,
            maximumRetainedBytes: 8 * 1_024,
            maximumReadSeconds: 2
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
