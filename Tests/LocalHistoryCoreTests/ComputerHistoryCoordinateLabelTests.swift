import XCTest

@testable import LocalHistoryCore

final class ComputerHistoryCoordinateLabelTests: XCTestCase {
    func testCoordinatesOutsideIntRangeNeverTrap() {
        XCTAssertEqual(ComputerHistorySupport.coordinateText(1e100), "?")
        XCTAssertEqual(ComputerHistorySupport.coordinateText(.nan), "?")
        XCTAssertEqual(ComputerHistorySupport.coordinateText(10.6), "11")
    }
}
