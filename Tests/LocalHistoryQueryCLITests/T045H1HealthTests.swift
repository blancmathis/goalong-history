import Foundation
import XCTest
@testable import LocalHistoryQueryCLI

/// T-045 H1-02: the 12 M element bound counts the whole file, so « Réduisez la période » cannot help.
final class T045H1HealthTests: XCTestCase {
    let zone = TimeZone(identifier: "Europe/Paris")!
    func options() -> GoalongHealthImportOptions {
        .init(from: ISO8601DateFormatter().date(from: "2026-09-06T22:00:00Z")!,
              through: ISO8601DateFormatter().date(from: "2026-09-07T21:59:59Z")!, timezone: zone, groups: [.activity])
    }

    func testElementBoundMessageDoesNotAskForAShorterPeriod() {
        // Twenty records from 2020, outside the one-day period: the period holds nothing, the file is still too big.
        let old = String(repeating: "<Record type=\"HKQuantityTypeIdentifierStepCount\" sourceName=\"Watch\" unit=\"count\" value=\"1\" startDate=\"2020-01-01 10:00:00 +0100\" endDate=\"2020-01-01 10:01:00 +0100\"/>", count: 20)
        let data = Data("<?xml version=\"1.0\"?><HealthData locale=\"fr_FR\"><ExportDate value=\"2026-09-08 09:00:00 +0200\"/>\(old)</HealthData>".utf8)
        XCTAssertThrowsError(try GoalongHealthImport.read(data: data, options: options(), elementLimit: 10)) { error in
            let message = "\(error)"
            XCTAssertFalse(message.contains("Réduisez la période"), message)
            XCTAssertTrue(message.contains("12 millions"), message)
        }
    }
}
