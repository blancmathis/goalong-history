import XCTest
@testable import AppleSystemScreenTime

/// T-043 Q3: no test may open the real Screen Time store, knowledgeC.db or Biome of the Mac running it.
final class NoSystemPathGuardTests: XCTestCase {
    func testDefaultScreenTimePathsStayInsideTheTemporaryFolderDuringTests() {
        let paths = AppleSystemScreenTimePaths.default
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.path
        let urls = [paths.knowledgeDatabase, paths.biomeSyncDatabase, paths.biomeLocalDirectory, paths.biomeRemoteDirectory,
                    paths.appleAccountDeviceDatabase] + [paths.biomeScreenTimeAppUsageDirectory,
                    paths.biomeRemoteScreenTimeAppUsageDirectory, paths.screenTimeAdminLocalDatabase,
                    paths.screenTimeAdminCloudDatabase].compactMap { $0 }
        for url in urls {
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(temp), "A test would probe a real system path: \(url.path)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Guard folder must stay empty: \(url.path)")
        }
        XCTAssertEqual(AppleSystemScreenTimeSource(deviceID: "guard").activationAccess(), .noData)
    }
}
