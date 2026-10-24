import Foundation
import XCTest

@testable import LocalHistoryCore

final class DailyWebsiteUsageEdgeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var day: Date { calendar.startOfDay(for: fixtureStart) }

    private func accumulator(
        limits: DailyWebsiteUsageLimits = .production
    ) -> DailyWebsiteUsageAccumulator {
        DailyWebsiteUsageAccumulator(
            day: day, currentTime: day.addingTimeInterval(3_600), calendar: calendar,
            limits: limits)
    }

    private func limits(
        rows: Int = 1_000, sources: Int = 8, categories: Int = 8
    ) -> DailyWebsiteUsageLimits {
        DailyWebsiteUsageLimits(
            maximumHosts: 100, maximumSourceApplicationsPerHost: sources,
            maximumCategoriesPerHost: categories, maximumSourceRows: rows,
            maximumSourceBytes: 1_048_576, maximumRetainedBytes: 1_048_576,
            maximumReadSeconds: 1)
    }

    private func visit(
        _ offset: Double, host: String = "site.example", app: String = "Safari",
        bundle: String? = "com.apple.Safari", category: String = "web",
        schemaVersion: Int = 4
    ) -> HistoryEvent {
        HistoryEvent(
            schemaVersion: schemaVersion,
            id: UUID().uuidString,
            sessionID: "edge",
            timestamp: day.addingTimeInterval(offset),
            kind: .windowChanged,
            app: AppSnapshot(name: app, bundleIdentifier: bundle, processIdentifier: 5),
            window: nil, element: nil,
            url: URLSnapshot(value: "https://\(host)/", host: host, redactionApplied: true),
            pointer: PointerSnapshot(button: "left", x: 1, y: 1, clickCount: 1),
            keyboard: nil, scroll: nil, inputOrigin: nil, semanticContext: nil,
            classification: LocalClassification(
                category: category, isWork: nil, confidence: 0.9, classifierVersion: "edge"),
            suppressionReason: nil, message: nil, metadata: nil, integrity: nil)
    }

    func testDisplayableHostNormalizesAndRejectsMalformedNames() {
        XCTAssertEqual(DailyWebsiteUsageAccumulator.displayableHost("  WWW.Example.COM.. "), "example.com")
        XCTAssertEqual(DailyWebsiteUsageAccumulator.displayableHost("localhost"), "localhost")
        for bad in [nil, "", "   ", "-", "a..b", "bad host", "-lead.example", "under_score.com", "exa/mple"] {
            XCTAssertNil(DailyWebsiteUsageAccumulator.displayableHost(bad), "\(String(describing: bad))")
        }
        let tooLong = String(repeating: "a", count: 254)
        XCTAssertNil(DailyWebsiteUsageAccumulator.displayableHost(tooLong))
        XCTAssertNotNil(DailyWebsiteUsageAccumulator.displayableHost(String(repeating: "a", count: 253)))
    }

    func testTrackedHostRejectsNonWebSchemesButKeepsEmptyOrHttpValues() {
        func tracked(_ value: String, _ host: String?) -> String? {
            DailyWebsiteUsageAccumulator.trackedHost(
                from: URLSnapshot(value: value, host: host, redactionApplied: false))
        }
        XCTAssertEqual(tracked("https://www.a.example/x", "www.a.example"), "a.example")
        XCTAssertEqual(tracked("HTTP://a.example", "a.example"), "a.example")
        XCTAssertEqual(tracked("  ", "a.example"), "a.example")
        XCTAssertNil(tracked("file:///tmp/x", "a.example"))
        XCTAssertNil(tracked("chrome://settings", "settings"))
        XCTAssertNil(tracked("https://a.example", nil))
        XCTAssertNil(DailyWebsiteUsageAccumulator.trackedHost(from: nil))
    }

    func testSourceRowCapStopsIngestionAndFlagsTruncation() {
        var projection = accumulator(limits: limits(rows: 3))
        for index in 0..<5 { projection.ingest(visit(Double(index * 10))) }
        XCTAssertEqual(projection.sourceEventCount, 3)
        XCTAssertTrue(projection.wasTruncated)
        XCTAssertEqual(projection.finish().first?.eventCount, 3)
    }

    func testEventsOutsideTheDayAreIgnoredWithoutTruncation() {
        var projection = accumulator()
        projection.ingest(visit(-1))
        projection.ingest(visit(86_400))
        XCTAssertEqual(projection.sourceEventCount, 0)
        XCTAssertFalse(projection.wasTruncated)
        XCTAssertTrue(projection.finish().isEmpty)
    }

    func testSourceApplicationsPerHostAreCappedAndFlagged() {
        var projection = accumulator(limits: limits(sources: 1))
        projection.ingest(visit(0, app: "Safari", bundle: "com.apple.Safari"))
        projection.ingest(visit(30, app: "Chrome", bundle: "com.google.Chrome"))
        projection.ingest(visit(60, app: "Safari", bundle: "com.apple.Safari"))
        let result = projection.finish()
        XCTAssertTrue(projection.wasTruncated)
        XCTAssertEqual(result.first?.sourceUsage.map(\.applicationName), ["Safari"])
        XCTAssertEqual(result.first?.eventCount, 3, "host totals still count every visit")
    }

    func testSourceKeyMergesNamesWithoutBundleAndSeparatesBundles() {
        var projection = accumulator()
        projection.ingest(visit(0, app: "Open Browser", bundle: nil))
        projection.ingest(visit(20, app: "open-browser", bundle: nil))
        projection.ingest(visit(40, app: "Open Browser", bundle: "COM.Open.Browser"))
        projection.ingest(visit(60, app: "Open Browser", bundle: "com.open.browser"))
        let usage = projection.finish().first?.sourceUsage ?? []
        XCTAssertEqual(usage.count, 2)
        let byBundle = usage.first { $0.bundleIdentifier != nil }
        XCTAssertEqual(byBundle?.eventCount, 2, "bundle ids merge case-insensitively")
        XCTAssertEqual(byBundle?.id, "bundle:com.open.browser")
        XCTAssertEqual(usage.first { $0.bundleIdentifier == nil }?.eventCount, 2)
    }

    func testSourceUsageIdIsLowercasedBundleOrName() {
        func source(_ name: String, _ bundle: String?) -> DailyWebsiteSourceUsage {
            DailyWebsiteSourceUsage(
                applicationName: name, bundleIdentifier: bundle, foregroundSeconds: -5,
                eventCount: -2, identityProofAvailable: true)
        }
        XCTAssertEqual(source("Safari", "Com.Apple.Safari").id, "bundle:com.apple.safari")
        XCTAssertEqual(source("Safari", "").id, "name:safari")
        XCTAssertEqual(source("Safari", nil).id, "name:safari")
        XCTAssertEqual(source("Safari", nil).foregroundSeconds, 0)
        XCTAssertEqual(source("Safari", nil).eventCount, 0)
    }

    func testLegacySchemaRowsClearIdentityProofOnHostAndSource() {
        var projection = accumulator()
        projection.ingest(visit(0, host: "old.example", schemaVersion: 2))
        projection.ingest(visit(30, host: "new.example", schemaVersion: 4))
        let result = projection.finish()
        let old = result.first { $0.host == "old.example" }
        let new = result.first { $0.host == "new.example" }
        XCTAssertEqual(old?.identityProofAvailable, false)
        XCTAssertEqual(old?.sourceUsage.first?.identityProofAvailable, false)
        XCTAssertEqual(new?.identityProofAvailable, true)
    }

    func testCategoryTieGoesToTheAlphabeticallyFirstName() {
        var projection = accumulator()
        projection.ingest(visit(0, category: "social"))
        projection.ingest(visit(20, category: "news"))
        projection.ingest(visit(40, category: "social"))
        projection.ingest(visit(60, category: "news"))
        XCTAssertEqual(projection.finish().first?.category, "news")
        var majority = accumulator()
        majority.ingest(visit(0, category: "news"))
        majority.ingest(visit(20, category: "social"))
        majority.ingest(visit(40, category: "social"))
        XCTAssertEqual(majority.finish().first?.category, "social")
    }

    func testEqualTimeAndEventSourcesSortByNameIgnoringCase() {
        var projection = accumulator()
        projection.ingest(visit(0, host: "tie.example", app: "zeta", bundle: "b.z"))
        projection.ingest(visit(0, host: "tie.example", app: "Alpha", bundle: "b.a"))
        projection.ingest(visit(0, host: "tie.example", app: "mid", bundle: "b.m"))
        let result = projection.finish()
        let usage = result.first?.sourceUsage ?? []
        let ordered = zip(usage, usage.dropFirst()).allSatisfy {
            $0.foregroundSeconds > $1.foregroundSeconds
                || ($0.foregroundSeconds == $1.foregroundSeconds && $0.eventCount > $1.eventCount)
                || ($0.foregroundSeconds == $1.foregroundSeconds && $0.eventCount == $1.eventCount
                    && $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending)
        }
        XCTAssertTrue(ordered, "\(usage.map(\.applicationName))")
        XCTAssertEqual(Set(usage.map(\.applicationName)), ["zeta", "Alpha", "mid"])
    }

    func testLimitsClampNonPositiveValues() {
        let clamped = DailyWebsiteUsageLimits(
            maximumHosts: 0, maximumSourceApplicationsPerHost: -3, maximumCategoriesPerHost: 0,
            maximumSourceRows: 0, maximumSourceBytes: 0, maximumRetainedBytes: -1,
            maximumReadSeconds: -5)
        XCTAssertEqual(clamped.maximumHosts, 1)
        XCTAssertEqual(clamped.maximumSourceApplicationsPerHost, 1)
        XCTAssertEqual(clamped.maximumCategoriesPerHost, 1)
        XCTAssertEqual(clamped.maximumSourceRows, 1)
        XCTAssertEqual(clamped.maximumSourceBytes, 1)
        XCTAssertEqual(clamped.maximumRetainedBytes, 1)
        XCTAssertEqual(clamped.maximumReadSeconds, 0)
    }
}
