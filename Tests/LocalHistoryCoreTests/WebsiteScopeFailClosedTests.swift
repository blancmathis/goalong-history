import Foundation
import XCTest
@testable import LocalHistoryCore

final class WebsiteScopeFailClosedTests: XCTestCase {
    func testExcludedDomainsFailClosedWithoutAKnownHost() {
        var config = RecorderConfig.default
        config.excludedDomains = ["private.example"]
        XCTAssertFalse(config.allowsWebsite(host: nil))
        XCTAssertFalse(config.allowsWebsite(host: ""))
        XCTAssertFalse(config.allowsWebsite(host: "private.example"))
        XCTAssertFalse(config.allowsWebsite(host: "sub.private.example"))
        XCTAssertTrue(config.allowsWebsite(host: "work.example"))
        XCTAssertTrue(config.allowsWebsite(host: "notprivate.example"))
    }
    func testUnrestrictedConfigurationStillAllowsUnknownBrowserHosts() {
        XCTAssertTrue(RecorderConfig.default.allowsWebsite(host: nil))
    }
    func testExclusionsOverrideTheIncludeList() {
        var config = RecorderConfig.default
        config.includedDomains = ["example.com"]
        config.excludedDomains = ["private.example.com"]
        XCTAssertTrue(config.allowsWebsite(host: "work.example.com"))
        XCTAssertFalse(config.allowsWebsite(host: "private.example.com"))
        XCTAssertFalse(config.allowsWebsite(host: nil))
        XCTAssertFalse(config.allowsWebsite(host: "elsewhere.com"))
    }
}
