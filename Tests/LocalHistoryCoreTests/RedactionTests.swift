import XCTest

@testable import LocalHistoryCore

final class RedactionTests: XCTestCase {
    func testURLRedactionRemovesCredentialsFragmentAndValues() throws {
        let snapshot = try XCTUnwrap(
            URLRedactor.sanitize(
                "https://alice:secret@example.com/path?q=hello&token=abc#section",
                redactAllQueryValues: true,
                maxLength: 512
            )
        )

        XCTAssertFalse(snapshot.value.contains("alice"))
        XCTAssertFalse(snapshot.value.contains("secret"))
        XCTAssertFalse(snapshot.value.contains("hello"))
        XCTAssertFalse(snapshot.value.contains("abc"))
        XCTAssertFalse(snapshot.value.contains("section"))
        XCTAssertEqual(snapshot.host, "example.com")
        XCTAssertTrue(snapshot.redactionApplied)
    }

    func testSanitizerKeepsEmojiAndSupplementaryScalarsButDropsControls() {
        XCTAssertEqual(StringSanitizer.clean("Release \u{1F680} planning", maxLength: 100), "Release \u{1F680} planning")
        XCTAssertEqual(StringSanitizer.clean("\u{20BB7}\u{91CE}", maxLength: 100), "\u{20BB7}\u{91CE}")
        XCTAssertEqual(StringSanitizer.clean("a\u{7F}b\u{85}c", maxLength: 100), "abc")
    }

    func testURLRedactionMasksCommonSecretParametersWithoutAllValuesMode() throws {
        let url = "https://s3.example.com/f?X-Amz-Signature=aaa&id_token=bbb&api_key=ccc&my_session_token=ddd&page=2"
        let snapshot = try XCTUnwrap(URLRedactor.sanitize(url, redactAllQueryValues: false, maxLength: 512))
        for secret in ["aaa", "bbb", "ccc", "ddd"] { XCTAssertFalse(snapshot.value.contains(secret), secret) }
        XCTAssertTrue(snapshot.value.contains("page=2"))
    }

    func testPrivateMarkerIsCaseAndAccentInsensitive() {
        XCTAssertTrue(
            PrivacyClassifier.containsPrivateMarker(
                in: ["Nouvel onglet — NAVIGATION PRIVÉE"],
                markers: ["navigation privée"]
            )
        )
    }

    func testDomainMatchingIncludesSubdomains() {
        XCTAssertTrue(URLRedactor.domain("accounts.example.com", matches: ["example.com"]))
        XCTAssertFalse(URLRedactor.domain("notexample.com", matches: ["example.com"]))
    }

    func testStringSanitizerRemovesNewlinesAndLimitsLength() {
        let result = StringSanitizer.clean(" hello\n\nworld ", maxLength: 8)
        XCTAssertEqual(result, "hello wo…")
    }
    func testBlankPrivateMarkerDoesNotMatchEverything() {
        XCTAssertFalse(
            PrivacyClassifier.containsPrivateMarker(
                in: ["A normal browser window"],
                markers: ["", "   "]
            )
        )
    }

    func testMalformedURLFailsClosed() {
        XCTAssertNil(
            URLRedactor.sanitize(
                "https://exa mple.com/?token=secret",
                redactAllQueryValues: true,
                maxLength: 512
            )
        )
    }

    func testConfigurationValidationClampsUnsafeValues() {
        var config = RecorderConfig.default
        config.retentionDays = -20
        config.pollIntervalMilliseconds = 1
        config.heartbeatSeconds = 1
        config.maxStringLength = -1
        config.privateWindowMarkers = ["", "  "]

        let validated = config.validated()
        XCTAssertEqual(validated.retentionDays, RecorderConfig.default.retentionDays)
        XCTAssertEqual(validated.pollIntervalMilliseconds, 250)
        XCTAssertEqual(validated.heartbeatSeconds, 10)
        XCTAssertEqual(validated.maxStringLength, 64)
        XCTAssertFalse(validated.privateWindowMarkers.isEmpty)
    }

    func testIncludeOnlyScopesFailClosedAndExclusionsWin() {
        var config = RecorderConfig.default
        config.includedBundleIdentifiers = ["com.apple.TextEdit"]
        config.includedDomains = ["work.example.com"]

        XCTAssertTrue(config.allowsApplication(bundleIdentifier: "com.apple.textedit"))
        XCTAssertFalse(config.allowsApplication(bundleIdentifier: "com.apple.finder"))
        XCTAssertFalse(config.allowsApplication(bundleIdentifier: nil))
        XCTAssertTrue(config.allowsWebsite(host: "docs.work.example.com"))
        XCTAssertFalse(config.allowsWebsite(host: "example.org"))
        XCTAssertFalse(config.allowsWebsite(host: nil))

        config.excludedBundleIdentifiers.append("com.apple.TextEdit")
        config.excludedDomains.append("docs.work.example.com")
        XCTAssertFalse(config.allowsApplication(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertFalse(config.allowsWebsite(host: "docs.work.example.com"))
    }

    func testEmptyIncludeOnlyScopesRemainBackwardsCompatible() throws {
        var config = RecorderConfig.default
        config.includedBundleIdentifiers = []
        config.includedDomains = ["", "  "]

        let validated = config.validated()
        XCTAssertNil(validated.includedBundleIdentifiers)
        XCTAssertNil(validated.includedDomains)
        XCTAssertTrue(validated.allowsApplication(bundleIdentifier: nil))
        XCTAssertTrue(validated.allowsWebsite(host: nil))

        let decoded = try JSONDecoder().decode(
            RecorderConfig.self,
            from: JSONEncoder().encode(RecorderConfig.default)
        )
        XCTAssertNil(decoded.includedBundleIdentifiers)
        XCTAssertNil(decoded.includedDomains)
    }

}
