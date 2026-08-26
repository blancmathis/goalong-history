#if os(macOS)
    import XCTest

    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    final class ComputerHistoryPublicControlParityTests: XCTestCase {
        func testSettingsDraftPersistsIncludeOnlyScopes() {
            var draft = DashboardSettingsDraft(config: .default)
            draft.includedDomainsText = "work.example.com\nWORK.EXAMPLE.COM\ndocs.example.org"
            draft.includedApplicationsText = "com.apple.TextEdit\ncom.apple.TextEdit"

            let applied = draft.applying(to: .default)

            XCTAssertEqual(applied.includedDomains, ["work.example.com", "docs.example.org"])
            XCTAssertEqual(applied.includedBundleIdentifiers, ["com.apple.TextEdit"])
            XCTAssertTrue(applied.allowsWebsite(host: "docs.work.example.com"))
            XCTAssertFalse(applied.allowsWebsite(host: "outside.example.net"))
            XCTAssertTrue(applied.allowsApplication(bundleIdentifier: "com.apple.textedit"))
            XCTAssertFalse(applied.allowsApplication(bundleIdentifier: "com.apple.finder"))
        }

        func testMenuOffersAllDocumentedBulkClearWindows() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/MenuBarController.swift"),
                encoding: .utf8
            )

            XCTAssertTrue(source.contains("Last 10 minutes…"))
            XCTAssertTrue(source.contains("Last hour…"))
            XCTAssertTrue(source.contains("Last day…"))
            XCTAssertTrue(source.contains("All detailed history…"))
            XCTAssertTrue(source.contains("Date().addingTimeInterval(-24 * 60 * 60)"))
        }
    }
#endif
