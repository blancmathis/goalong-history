import XCTest
@testable import LocalHistoryCore

final class CapturePolicyPrecedenceTests: XCTestCase {
    func testExplicitApplicationExclusionWinsOverIncludeOnlyEntry() {
        var config = RecorderConfig.default
        config.applicationCaptureMode = .includeOnly
        config.excludedBundleIdentifiers = [
            "ai.goalong.localhistory",
            "com.example.password-manager",
        ]
        config.includedBundleIdentifiers = [
            "ai.goalong.localhistory",
            "com.example.password-manager",
            "com.apple.TextEdit",
        ]
        config = config.validated()

        XCTAssertFalse(
            config.allowsApplication(bundleIdentifier: "ai.goalong.localhistory")
        )
        XCTAssertFalse(
            config.allowsApplication(bundleIdentifier: "com.example.password-manager")
        )
        XCTAssertTrue(
            config.allowsApplication(bundleIdentifier: "com.apple.TextEdit")
        )
    }

    func testExplicitDomainExclusionWinsOverIncludeOnlyEntryAndSubdomain() {
        var config = RecorderConfig.default
        config.websiteCaptureMode = .includeOnly
        config.excludedDomains = ["secret.example.com"]
        config.includedDomains = ["example.com", "secret.example.com"]
        config = config.validated()

        XCTAssertTrue(config.allowsWebsite(host: "docs.example.com"))
        XCTAssertFalse(config.allowsWebsite(host: "secret.example.com"))
        XCTAssertFalse(config.allowsWebsite(host: "nested.secret.example.com"))
    }
}
