@testable import LocalHistoryApp
import LocalHistoryCore
import XCTest

final class GoalongDevIsolationPathTests: XCTestCase {
    func testReleasePathsAreUnchangedAndBlockingStaysReal() {
        let real = GoalongBuildChannel.realDataRoot
        XCTAssertEqual(AppPaths.applicationSupportDirectory, real)
        XCTAssertEqual(ActivityAnalysisPaths.applicationSupportDirectory, real)
        XCTAssertEqual(AppPaths.realApplicationSupportDirectory, real)
        XCTAssertEqual(BlockingStore.standard.directory, real.appendingPathComponent("Blocking", isDirectory: true))
        XCTAssertEqual(FocusStore.standard.directory, real.appendingPathComponent("Focus"))
        XCTAssertEqual(ProductIdentity.windowTitle("Signaler un problème"), "Signaler un problème")
        XCTAssertEqual(ProductIdentity.mainWindowTitle, ProductIdentity.displayName)
    }
}
