import Foundation
import XCTest
@testable import LocalHistoryQueryCLI

/// T-044 tour 8, volet C2 (C8-22).
final class C044R8C2CLIEdgeTests: XCTestCase {
    /// US-locale exports write swimming distance in yards.
    func testSwimmingDistanceInYardsIsKept() throws {
        let zone = TimeZone(identifier: "Europe/Paris")!
        let f = ISO8601DateFormatter()
        let options = GoalongHealthImportOptions(from: f.date(from: "2026-09-06T22:00:00Z")!, through: f.date(from: "2026-09-07T21:59:59Z")!, timezone: zone, groups: [.workouts])
        let body = "<Workout workoutActivityType=\"HKWorkoutActivityTypeSwimming\" duration=\"30\" durationUnit=\"min\" totalDistance=\"1000\" totalDistanceUnit=\"yd\" sourceName=\"Watch\" startDate=\"2026-09-07 10:00:00 +0200\" endDate=\"2026-09-07 10:30:00 +0200\"/>"
        let data = Data("<?xml version=\"1.0\"?><HealthData locale=\"en_US\"><ExportDate value=\"2026-09-08 09:00:00 +0200\"/>\(body)</HealthData>".utf8)
        let result = try GoalongHealthImport.read(data: data, options: options)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        let day = try XCTUnwrap((object["days"] as? [[String: Any]])?.first)
        let workouts = try XCTUnwrap((day["health"] as? [String: Any])?["workouts"] as? [[String: Any]])
        let meters = try XCTUnwrap(workouts.first?["distanceMeters"] as? Double, "workout \(workouts)")
        XCTAssertEqual(meters, 914.4, accuracy: 0.1)
    }
}
