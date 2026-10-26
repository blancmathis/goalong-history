import Foundation
import XCTest
@testable import LocalHistoryQueryCLI

/// T-044 tour 7, volet C2: Apple Health import edge cases. Red tests only; never committed.
final class C044R7C2CLIEdgeTests: XCTestCase {
    /// HealthKit writes large calories as « Cal » (HKUnit.largeCalorie) in export.xml.
    func testActiveEnergyInLargeCaloriesIsKept() throws {
        let zone = TimeZone(identifier: "Europe/Paris")!
        let f = ISO8601DateFormatter()
        let options = GoalongHealthImportOptions(from: f.date(from: "2026-09-06T22:00:00Z")!, through: f.date(from: "2026-09-07T21:59:59Z")!, timezone: zone, groups: [.activity])
        let body = "<Record type=\"HKQuantityTypeIdentifierActiveEnergyBurned\" sourceName=\"Watch\" unit=\"Cal\" value=\"250\" startDate=\"2026-09-07 10:00:00 +0200\" endDate=\"2026-09-07 10:10:00 +0200\"/>"
            + "<Record type=\"HKQuantityTypeIdentifierStepCount\" sourceName=\"Watch\" unit=\"count\" value=\"100\" startDate=\"2026-09-07 10:00:00 +0200\" endDate=\"2026-09-07 10:10:00 +0200\"/>"
        let data = Data("<?xml version=\"1.0\"?><HealthData locale=\"en_US\"><ExportDate value=\"2026-09-08 09:00:00 +0200\"/>\(body)</HealthData>".utf8)
        let result = try GoalongHealthImport.read(data: data, options: options)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        let day = try XCTUnwrap((object["days"] as? [[String: Any]])?.first)
        let metrics = try XCTUnwrap((day["health"] as? [String: Any])?["metrics"] as? [[String: Any]])
        let values = Dictionary(uniqueKeysWithValues: metrics.map { ($0["key"] as! String, $0["value"] as! Double) })
        XCTAssertEqual(values["steps"], 100)
        XCTAssertEqual(values["activeEnergyKcal"], 250, "warnings \(result.warnings)")
    }
}
