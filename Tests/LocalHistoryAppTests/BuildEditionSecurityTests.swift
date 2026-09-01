#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    final class BuildEditionSecurityTests: XCTestCase {
        func testWorkspaceOpenPolicySeparatesLocalFilesSettingsAndReviewedHTTPS() throws {
            let localFile = URL(fileURLWithPath: "/tmp/goalong-security-test")
            XCTAssertTrue(GoalongWorkspaceOpenPolicy.permits(localFile, purpose: .localFile))
            XCTAssertFalse(GoalongWorkspaceOpenPolicy.permits(localFile, purpose: .observedWebsite))

            let settings = try XCTUnwrap(
                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
            )
            XCTAssertTrue(GoalongWorkspaceOpenPolicy.permits(settings, purpose: .systemSettings))
            XCTAssertFalse(GoalongWorkspaceOpenPolicy.permits(settings, purpose: .localFile))

            let plainHTTP = try XCTUnwrap(URL(string: "http://example.com"))
            XCTAssertFalse(GoalongWorkspaceOpenPolicy.permits(plainHTTP, purpose: .observedWebsite))

            let observedHTTPS = try XCTUnwrap(URL(string: "https://example.com/work"))
            XCTAssertEqual(
                GoalongWorkspaceOpenPolicy.permits(observedHTTPS, purpose: .observedWebsite),
                GoalongBuildCapabilities.permitsHTTPWorkspaceOpening
            )

            let account = try XCTUnwrap(URL(string: "https://auth.openai.com/authorize"))
            XCTAssertEqual(
                GoalongWorkspaceOpenPolicy.permits(account, purpose: .accountAuthorization),
                GoalongBuildCapabilities.permitsHTTPWorkspaceOpening
            )
            XCTAssertFalse(
                GoalongWorkspaceOpenPolicy.permits(observedHTTPS, purpose: .accountAuthorization)
            )

            let credentialed = try XCTUnwrap(URL(string: "https://user:secret@example.com/work"))
            XCTAssertFalse(
                GoalongWorkspaceOpenPolicy.permits(credentialed, purpose: .observedWebsite)
            )
            let alternatePort = try XCTUnwrap(URL(string: "https://example.com:8443/work"))
            XCTAssertFalse(
                GoalongWorkspaceOpenPolicy.permits(alternatePort, purpose: .observedWebsite)
            )
        }

        func testSingleAppCapabilityDeclarationIsSecurityFirst() {
            XCTAssertEqual(GoalongBuildCapabilities.edition, .unified)
            XCTAssertFalse(GoalongBuildCapabilities.permitsFirstPartyNetworking)
            XCTAssertFalse(GoalongBuildCapabilities.permitsRemoteVerification)
            XCTAssertTrue(GoalongBuildCapabilities.permitsRemoteAnalysis)
            XCTAssertFalse(GoalongBuildCapabilities.permitsAutomaticUpdates)
        }

        func testCompatibilityBuildEntryPointCannotCreateSecondAppIdentity() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let script = try String(
                contentsOf: repositoryRoot.appendingPathComponent("scripts/build_local_app.sh"),
                encoding: .utf8
            )

            XCTAssertTrue(script.contains("source \"$ROOT_DIR/scripts/preserve_package_resolved.sh\""))
            XCTAssertTrue(script.contains("goalong_preserve_package_resolved \"$ROOT_DIR\""))
            XCTAssertTrue(script.contains("LOCALHISTORY_APP_NAME=\"Goalong History\""))
            XCTAssertTrue(script.contains("LOCALHISTORY_BUNDLE_ID=\"ai.goalong.localhistory\""))
            XCTAssertFalse(script.contains("Goalong History Local"))
            XCTAssertFalse(script.contains("ai.goalong.localhistory.local"))

            let helper = try String(
                contentsOf: repositoryRoot.appendingPathComponent("scripts/preserve_package_resolved.sh"),
                encoding: .utf8
            )
            XCTAssertTrue(helper.contains("GOALONG_PACKAGE_RESOLVED_BACKUP="))
            XCTAssertTrue(helper.contains("trap goalong_restore_package_resolved EXIT"))
            XCTAssertTrue(helper.contains("cp \"$GOALONG_PACKAGE_RESOLVED_BACKUP\" \"$GOALONG_PACKAGE_RESOLVED\""))
        }
    }
#endif
