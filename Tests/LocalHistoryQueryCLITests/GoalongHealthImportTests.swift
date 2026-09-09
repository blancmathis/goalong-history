import Foundation
import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongHealthImportTests: XCTestCase {
    let zone = TimeZone(identifier: "Europe/Paris")!
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func options(_ groups: Set<GoalongHealthGroup> = Set(GoalongHealthGroup.allCases)) -> GoalongHealthImportOptions {
        .init(from: date("2026-09-06T22:00:00Z"), through: date("2026-09-07T21:59:59Z"), timezone: zone, groups: groups)
    }
    func xml(_ body: String) -> Data { Data("<?xml version=\"1.0\"?><HealthData locale=\"fr_FR\"><ExportDate value=\"2026-09-08 09:00:00 +0200\"/>\(body)</HealthData>".utf8) }
    func record(_ type: String, value: String, unit: String = "count", source: String = "Watch", start: String = "2026-09-07 10:00:00 +0200", end: String = "2026-09-07 10:10:00 +0200") -> String {
        "<Record type=\"\(type)\" sourceName=\"\(source)\" unit=\"\(unit)\" value=\"\(value)\" startDate=\"\(start)\" endDate=\"\(end)\"/>"
    }
    func day(_ result: GoalongHealthImportResult, index: Int = 0) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "apple-health")
        return try XCTUnwrap((object["days"] as? [[String: Any]])?[index])
    }
    func metrics(_ result: GoalongHealthImportResult, index: Int = 0) throws -> [String: Double] {
        let health = try XCTUnwrap(try day(result, index: index)["health"] as? [String: Any])
        let metrics = try XCTUnwrap(health["metrics"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: metrics.map { ($0["key"] as! String, $0["value"] as! Double) })
    }
    func testSourceChoiceAndDuplicateSamplesNeverSumPhoneAndWatch() throws {
        let step = record("HKQuantityTypeIdentifierStepCount", value: "100")
        let data = xml(step + step + record("HKQuantityTypeIdentifierStepCount", value: "500", source: "iPhone"))
        let result = try GoalongHealthImport.read(data: data, options: options())
        XCTAssertEqual(try metrics(result)["steps"], 100)
        XCTAssertEqual(result.sources[.activity], ["Watch", "iPhone"])
        var selected = options(); selected.preferredSources[.activity] = "iPhone"
        XCTAssertEqual(try metrics(GoalongHealthImport.read(data: data, options: selected))["steps"], 500)
        XCTAssertFalse(result.warnings.isEmpty)
    }
    func testSleepIsUnionAcrossStagesAndSplitAtLocalMidnight() throws {
        let asleep = record("HKCategoryTypeIdentifierSleepAnalysis", value: "HKCategoryValueSleepAnalysisAsleepCore", start: "2026-09-06 23:00:00 +0200", end: "2026-09-07 02:00:00 +0200")
        let overlap = record("HKCategoryTypeIdentifierSleepAnalysis", value: "HKCategoryValueSleepAnalysisAsleepDeep", start: "2026-09-07 01:00:00 +0200", end: "2026-09-07 03:00:00 +0200")
        let inBed = record("HKCategoryTypeIdentifierSleepAnalysis", value: "HKCategoryValueSleepAnalysisInBed", start: "2026-09-06 22:00:00 +0200", end: "2026-09-07 04:00:00 +0200")
        let values = try metrics(GoalongHealthImport.read(data: xml(asleep + overlap + inBed), options: options([.sleep])))
        XCTAssertEqual(values["sleepSeconds"], 10800)
        XCTAssertEqual(values["inBedSeconds"], 14400)
        XCTAssertEqual(values["sleepCoreSeconds"], 7200)
    }
    func testHeartAverageIsSampleMeanAndPrivateClinicalFieldsAreAbsent() throws {
        let data = xml(record("HKQuantityTypeIdentifierHeartRate", value: "60", unit: "count/min") + record("HKQuantityTypeIdentifierHeartRate", value: "100", unit: "count/min", start: "2026-09-07 11:00:00 +0200", end: "2026-09-07 11:01:00 +0200") + "<Me HKCharacteristicTypeIdentifierBloodType=\"SECRET\"/>" + record("HKQuantityTypeIdentifierBloodGlucose", value: "SECRET"))
        let result = try GoalongHealthImport.read(data: data, options: options([.heart]))
        let values = try metrics(result)
        XCTAssertEqual(values["heartRateBPM"], 80); XCTAssertEqual(values["heartRateMinBPM"], 60); XCTAssertEqual(values["heartRateMaxBPM"], 100)
        XCTAssertFalse(String(decoding: result.payload, as: UTF8.self).contains("SECRET"))
        XCTAssertNil(values["steps"])
    }
    func testWorkoutStatisticsConvertUnitsAndExcludeRoutes() throws {
        let workout = """
        <Workout sourceName="Watch" workoutActivityType="HKWorkoutActivityTypeRunning" startDate="2026-09-07 10:00:00 +0200" endDate="2026-09-07 10:30:00 +0200" duration="30" durationUnit="min">
          <WorkoutStatistics type="HKQuantityTypeIdentifierDistanceWalkingRunning" sum="5" unit="km"/>
          <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" sum="1000" unit="kJ"/>
          <WorkoutRoute><FileReference path="PRIVATE_ROUTE.gpx"/></WorkoutRoute>
        </Workout>
        """
        let result = try GoalongHealthImport.read(data: xml(workout), options: options([.workouts]))
        let health = try XCTUnwrap(try day(result)["health"] as? [String: Any])
        let value = try XCTUnwrap((health["workouts"] as? [[String: Any]])?.first)
        XCTAssertEqual(value["durationSeconds"] as? Double, 1800)
        XCTAssertEqual(value["distanceMeters"] as? Double, 5000)
        XCTAssertEqual(value["energyKcal"] as! Double, 1000 / 4.184, accuracy: 0.001)
        XCTAssertFalse(String(decoding: result.payload, as: UTF8.self).contains("PRIVATE_ROUTE"))
        XCTAssertEqual(result.workoutCount, 1)
    }
    func testUnknownUnitsAndMissingDataDoNotBecomeZeros() throws {
        let data = xml(record("HKQuantityTypeIdentifierStepCount", value: "0") + record("HKQuantityTypeIdentifierHeartRate", value: "200", unit: "wrong"))
        let values = try metrics(GoalongHealthImport.read(data: data, options: options()))
        XCTAssertEqual(values["steps"], 0); XCTAssertNil(values["heartRateBPM"])
        XCTAssertThrowsError(try GoalongHealthImport.read(data: data, options: options([.heart])))
    }
    func testSourceLabelsAndLegacyWorkoutBoundsStayCompatibleWithWebsite() throws {
        let source = String(repeating: "⌚️", count: 70) + "&#x7F;"
        let workout = """
        <Workout sourceName="\(source)" workoutActivityType="invalid-kind" startDate="2026-09-07 10:00:00 +0200" endDate="2026-09-07 10:30:00 +0200" duration="30" durationUnit="min" totalDistance="9000000" totalDistanceUnit="km" totalEnergyBurned="9000000" totalEnergyBurnedUnit="kcal"/>
        """
        let result = try GoalongHealthImport.read(data: xml(workout), options: options([.workouts]))
        let health = try XCTUnwrap(try day(result)["health"] as? [String: Any])
        let value = try XCTUnwrap((health["workouts"] as? [[String: Any]])?.first)
        XCTAssertLessThanOrEqual((value["source"] as! String).utf16.count, 100)
        XCTAssertNil((value["source"] as! String).rangeOfCharacter(from: .controlCharacters))
        XCTAssertEqual(value["sport"] as? String, "HKWorkoutActivityTypeOther")
        XCTAssertTrue(value["distanceMeters"] is NSNull)
        XCTAssertTrue(value["energyKcal"] is NSNull)
        XCTAssertFalse(result.warnings.isEmpty)
    }
    func testMalformedDocumentsAndEntitiesAreRejected() throws {
        for text in ["<HealthData>", "<Other/>", "<!DOCTYPE HealthData [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><HealthData>&secret;</HealthData>", "<!DOCTYPE HealthData [<!ENTITY x 'hello'>]><HealthData>&x;</HealthData>"] {
            XCTAssertThrowsError(try GoalongHealthImport.read(data: Data(text.utf8), options: options()))
        }
    }
    func testFileStreamPreservesSourceAndRejectsSymbolicLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("export.xml")
        let data = xml(record("HKQuantityTypeIdentifierStepCount", value: "100"))
        try data.write(to: file)
        let result = try GoalongHealthImport.read(file: file, options: options())
        XCTAssertEqual(try metrics(result)["steps"], 100)
        XCTAssertEqual(try Data(contentsOf: file), data)
        let link = dir.appendingPathComponent("link.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try GoalongHealthImport.read(file: link, options: options()))
    }
    func testRepeatedImportProducesIdenticalPayload() throws {
        let data = xml(record("HKQuantityTypeIdentifierStepCount", value: "100"))
        let a = try GoalongHealthImport.read(data: data, options: options()).payload
        let b = try GoalongHealthImport.read(data: data, options: options()).payload
        XCTAssertEqual(a, b)
    }
    func testSleepAcrossFallBackUsesElapsedSecondsAndValidLocalDay() throws {
        let sample = record("HKCategoryTypeIdentifierSleepAnalysis", value: "HKCategoryValueSleepAnalysisAsleep", start: "2026-10-25 01:00:00 +0200", end: "2026-10-25 04:00:00 +0100")
        let selected = GoalongHealthImportOptions(from: date("2026-10-24T22:00:00Z"), through: date("2026-10-25T22:00:00Z"), timezone: zone, groups: [.sleep])
        XCTAssertEqual(try metrics(GoalongHealthImport.read(data: xml(sample), options: selected))["sleepSeconds"], 14400)
    }
    func testOverlappingCumulativeSamplesAndCrossMidnightAreNotProrated() throws {
        let data = xml(record("HKQuantityTypeIdentifierStepCount", value: "100") + record("HKQuantityTypeIdentifierStepCount", value: "90", start: "2026-09-07 10:05:00 +0200", end: "2026-09-07 10:15:00 +0200") + record("HKQuantityTypeIdentifierStepCount", value: "500", start: "2026-09-07 23:55:00 +0200", end: "2026-09-08 00:05:00 +0200"))
        let result = try GoalongHealthImport.read(data: data, options: options())
        XCTAssertEqual(try metrics(result)["steps"], 100)
        XCTAssertEqual(result.warnings.count, 2)
    }
    func testProtectedArchiveReplacesOnlySelectedHealthDays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("screen-time.json")
        try Data("unchanged".utf8).write(to: unrelated)
        let first = try GoalongHealthImport.read(data: xml(record("HKQuantityTypeIdentifierStepCount", value: "100")), options: options())
        try GoalongHealthArchive.save(first, root: root)
        XCTAssertEqual(try GoalongHealthArchive.dates(root: root), ["2026-09-07"])
        let path = root.appendingPathComponent("health/2026-09-07.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let second = try GoalongHealthImport.read(data: xml(record("HKQuantityTypeIdentifierStepCount", value: "200")), options: options())
        try GoalongHealthArchive.save(second, root: root)
        let bytes = try GoalongHealthArchive.read(day: "2026-09-07", root: root)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let health = try XCTUnwrap((object["days"] as? [[String: Any]])?.first?["health"] as? [String: Any])
        XCTAssertEqual((health["metrics"] as? [[String: Any]])?.first?["value"] as? Double, 200)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unchanged".utf8))
        XCTAssertThrowsError(try GoalongHealthArchive.read(day: "../screen-time", root: root))
        XCTAssertThrowsError(try GoalongHealthArchive.read(day: "2026-02-30", root: root))
        var tampered = object
        var days = tampered["days"] as! [[String: Any]]
        var importedHealth = days[0]["health"] as! [String: Any]
        importedHealth["medicalRecords"] = ["private clinical text"]
        days[0]["health"] = importedHealth; tampered["days"] = days
        try JSONSerialization.data(withJSONObject: tampered).write(to: path)
        XCTAssertThrowsError(try GoalongHealthArchive.read(day: "2026-09-07", root: root))
    }
}
