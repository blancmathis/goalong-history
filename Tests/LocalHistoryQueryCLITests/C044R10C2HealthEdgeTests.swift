import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryQueryCLI

final class C044R10C2HealthEdgeTests: XCTestCase {
    let zone = TimeZone(identifier: "Europe/Paris")!
    func date(_ v: String) -> Date { ISO8601DateFormatter().date(from: v)! }
    func opts(_ from: String, _ through: String, _ groups: Set<GoalongHealthGroup> = Set(GoalongHealthGroup.allCases)) -> GoalongHealthImportOptions {
        .init(from: date(from), through: date(through), timezone: zone, groups: groups)
    }
    func wrap(_ body: String) -> Data { Data("<?xml version=\"1.0\"?><HealthData locale=\"fr_FR\"><ExportDate value=\"2026-10-27 09:00:00 +0100\"/>\(body)</HealthData>".utf8) }
    func rec(_ type: String, _ value: String, unit: String = "count", source: String = "Watch", start: String, end: String) -> String {
        "<Record type=\"\(type)\" sourceName=\"\(source)\" unit=\"\(unit)\" value=\"\(value)\" startDate=\"\(start)\" endDate=\"\(end)\"/>"
    }
    func metrics(_ r: GoalongHealthImportResult, _ i: Int = 0) throws -> [String: Double] {
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: r.payload) as? [String: Any])
        let d = try XCTUnwrap((o["days"] as? [[String: Any]])?[i]); let h = try XCTUnwrap(d["health"] as? [String: Any])
        return Dictionary(uniqueKeysWithValues: try XCTUnwrap(h["metrics"] as? [[String: Any]]).map { ($0["key"] as! String, $0["value"] as! Double) })
    }
    func message(_ f: () throws -> Any) -> String { do { _ = try f(); return "" } catch { return "\(error)" + ((error as? LocalizedError)?.errorDescription ?? "") } }

    func readFile(_ data: Data, _ o: GoalongHealthImportOptions) throws -> Any {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("export.xml"); try data.write(to: f)
        return try GoalongHealthImport.read(file: f, options: o)
    }
    func testElementLimitBoundary12M() {
        // root + ExportDate + filler = exactly 12 000 000 elements: accepted by the limit, so only "no data" may fail.
        let o = opts("2026-10-24T22:00:00Z", "2026-10-25T21:59:59Z")
        func build(extra: Int) -> Data {
            var d = Data("<?xml version=\"1.0\"?><HealthData><ExportDate value=\"2026-10-27 09:00:00 +0100\"/>".utf8)
            d.append(Data(String(repeating: "<Z/>", count: 1000).utf8).repeated(11_999))   // 11 999 000
            d.append(Data(String(repeating: "<Z/>", count: 998 + extra).utf8)); d.append(Data("</HealthData>".utf8)); return d
        }
        let ok = message { try readFile(build(extra: 0), o) }
        XCTAssertTrue(ok.contains("Aucune donnée"), "12 000 000 elements must pass the limit: \(ok)")
        let over = message { try readFile(build(extra: 1), o) }
        XCTAssertTrue(over.contains("12 millions"), "12 000 001 elements must hit the limit: \(over)")
    }
    func testFallBackSleepDayIs25Hours() throws {
        let o = opts("2026-10-24T22:00:00Z", "2026-10-25T21:59:59Z", [.sleep])
        let s = rec("HKCategoryTypeIdentifierSleepAnalysis", "HKCategoryValueSleepAnalysisInBed", start: "2026-10-25 00:00:00 +0200", end: "2026-10-26 00:00:00 +0100")
        let m = try metrics(GoalongHealthImport.read(data: wrap(s), options: o))
        XCTAssertEqual(m["inBedSeconds"], 90_000)
    }
    func testFallBackDaySumsAndDayAssignment() throws {
        let o = opts("2026-10-24T22:00:00Z", "2026-10-25T21:59:59Z", [.activity])
        // 02:30 CET (second pass) and 23:59 CET belong to the 25th; 00:00 CET the 26th must not.
        let a = rec("HKQuantityTypeIdentifierStepCount", "10", start: "2026-10-25 02:30:00 +0100", end: "2026-10-25 02:40:00 +0100")
        let b = rec("HKQuantityTypeIdentifierStepCount", "20", start: "2026-10-25 23:59:00 +0100", end: "2026-10-25 23:59:30 +0100")
        let c = rec("HKQuantityTypeIdentifierStepCount", "40", start: "2026-10-26 00:00:00 +0100", end: "2026-10-26 00:01:00 +0100")
        let r = try GoalongHealthImport.read(data: wrap(a + b + c), options: o)
        XCTAssertEqual(try metrics(r)["steps"], 30)
        XCTAssertEqual(r.dayCount, 1)
    }
    func testSpringGapDaySleepIs23Hours() throws {
        let o = opts("2026-03-28T23:00:00Z", "2026-03-29T21:59:59Z", [.sleep])
        let s = rec("HKCategoryTypeIdentifierSleepAnalysis", "HKCategoryValueSleepAnalysisInBed", start: "2026-03-29 00:00:00 +0100", end: "2026-03-30 00:00:00 +0200")
        XCTAssertEqual(try metrics(GoalongHealthImport.read(data: wrap(s), options: o))["inBedSeconds"], 82_800)
    }
    func testRangeOf367DaysRejectedAnd366Accepted() {
        let s = rec("HKQuantityTypeIdentifierStepCount", "5", start: "2026-01-02 10:00:00 +0100", end: "2026-01-02 10:05:00 +0100")
        XCTAssertNoThrow(try GoalongHealthImport.read(data: wrap(s), options: opts("2025-12-31T23:00:00Z", "2027-01-01T21:59:59Z", [.activity])))
        XCTAssertThrowsError(try GoalongHealthImport.read(data: wrap(s), options: opts("2025-12-31T23:00:00Z", "2027-01-02T21:59:59Z", [.activity])))
    }
    func testMalformedValuesAreIgnoredNotParsedAsHexOrOctal() throws {
        let o = opts("2026-09-06T22:00:00Z", "2026-09-07T21:59:59Z", [.activity])
        let st = "start: \"x\""; _ = st
        func steps(_ v: String) throws -> Double? {
            let r = try? GoalongHealthImport.read(data: wrap(rec("HKQuantityTypeIdentifierStepCount", v, start: "2026-09-07 10:00:00 +0200", end: "2026-09-07 10:10:00 +0200") + rec("HKQuantityTypeIdentifierStepCount", "1", source: "Z", start: "2026-09-07 11:00:00 +0200", end: "2026-09-07 11:10:00 +0200")), options: o)
            return try r.flatMap { try metrics($0)["steps"] }
        }
        // source "Watch" has more... both have 1 sample, tie broken alphabetically ("Watch" > "Z"? no: "Watch" < "Z"). Watch wins when its value parses.
        XCTAssertEqual(try steps("0x10"), 1, "hex float '0x10' must be rejected (got 16)")
        XCTAssertEqual(try steps("1e2"), 100, "exponent notation stays a valid decimal")
        XCTAssertEqual(try steps("nan"), 1); XCTAssertEqual(try steps("inf"), 1); XCTAssertEqual(try steps("-5"), 1)
    }
    func testNegativeAndZeroDurationRecords() throws {
        let o = opts("2026-09-06T22:00:00Z", "2026-09-07T21:59:59Z", [.activity, .sleep])
        let neg = rec("HKQuantityTypeIdentifierStepCount", "10", start: "2026-09-07 10:10:00 +0200", end: "2026-09-07 10:00:00 +0200")
        let zero = rec("HKQuantityTypeIdentifierStepCount", "7", source: "B", start: "2026-09-07 12:00:00 +0200", end: "2026-09-07 12:00:00 +0200")
        let slp = rec("HKCategoryTypeIdentifierSleepAnalysis", "HKCategoryValueSleepAnalysisAsleepCore", start: "2026-09-07 03:00:00 +0200", end: "2026-09-07 03:00:00 +0200")
        let r = try GoalongHealthImport.read(data: wrap(neg + zero + slp), options: o)
        let m = try metrics(r)
        XCTAssertEqual(m["steps"], 7); XCTAssertNil(m["sleepSeconds"])
    }
    func testWorkoutDurationUnitsAndMidnight() throws {
        let o = opts("2026-09-06T22:00:00Z", "2026-09-07T21:59:59Z", [.workouts])
        let w = """
        <Workout sourceName="Watch" workoutActivityType="HKWorkoutActivityTypeRunning" startDate="2026-09-07 23:50:00 +0200" endDate="2026-09-08 00:20:00 +0200" duration="30" durationUnit="min"/>
        """
        let r = try GoalongHealthImport.read(data: wrap(w), options: o)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: r.payload) as? [String: Any])
        let day = try XCTUnwrap((obj["days"] as? [[String: Any]])?.first)
        XCTAssertEqual(day["date"] as? String, "2026-09-07")
        XCTAssertEqual(r.workoutCount, 1)
    }
    func testHeavyRepeatedRecordsDoNotOverflowCountsAt100WorkoutsPerDay() {
        var w = ""
        for i in 0..<101 { w += "<Workout sourceName=\"Watch\" workoutActivityType=\"HKWorkoutActivityTypeRunning\" startDate=\"2026-09-07 \(String(format: "%02d", 5 + i / 60)):\(String(format: "%02d", i % 60)):00 +0200\" endDate=\"2026-09-07 \(String(format: "%02d", 5 + i / 60)):\(String(format: "%02d", i % 60)):30 +0200\" duration=\"30\" durationUnit=\"s\"/>" }
        let msg = message { try GoalongHealthImport.read(data: wrap(w), options: opts("2026-09-06T22:00:00Z", "2026-09-07T21:59:59Z", [.workouts])) }
        XCTAssertTrue(msg.contains("100"), "101 workouts in one day must be rejected clearly, got '\(msg)'")
    }
    func testTruncatedAndNonHealthXML() {
        let o = opts("2026-09-06T22:00:00Z", "2026-09-07T21:59:59Z")
        let trunc = Data("<?xml version=\"1.0\"?><HealthData><Record type=\"HKQuantityTypeIdentifierStepCount\" unit=\"count\" value=\"5\" startDate=\"2026-09-07 10:00:00 +0200\" endDate=\"2026-09-07 10:05:00 +0200\"/>".utf8)
        XCTAssertThrowsError(try GoalongHealthImport.read(data: trunc, options: o), "truncated export (no closing tag) must not import silently")
        XCTAssertThrowsError(try GoalongHealthImport.read(data: Data(), options: o))
        XCTAssertThrowsError(try GoalongHealthImport.read(data: Data([0xFF, 0xFE, 0x00]), options: o))
    }
}
extension Data { func repeated(_ n: Int) -> Data { var d = Data(); d.reserveCapacity(count * n); for _ in 0..<n { d.append(self) }; return d } }
