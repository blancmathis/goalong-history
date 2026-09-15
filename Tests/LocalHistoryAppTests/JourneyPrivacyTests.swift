#if os(macOS)
import AppKit
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class JourneyPrivacyTests: XCTestCase {
    private func consentStore() throws -> GoalongCapabilityConsentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-journey-consent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consents.json"))
    }
    func testOpeningEveryDisabledHistoryNeverProbesOrEnablesASource() throws {
        let store = try consentStore()
        let validation = SourceAccessValidation(store: store)
        for capability in [GoalongCapability.localComputerHistory, .appleScreenTime, .aiConversations] {
            validation.validate(capability) { _, _ in XCTFail("Navigation is not consent to inspect a disabled source") }
            XCTAssertFalse(store.isEnabled(capability))
            XCTAssertNil(validation.result)
            XCTAssertFalse(validation.checking)
        }
    }
    func testMissingPermissionDoesNotRewriteTheUsersSourceChoice() throws {
        let store = try consentStore()
        XCTAssertTrue(store.set(.localComputerHistory, enabled: true, surface: .settings))
        let before = store.document
        let validation = SourceAccessValidation(store: store)
        validation.validate(.localComputerHistory) { _, done in done(.accessibility) }
        XCTAssertEqual(validation.result, .accessibility)
        XCTAssertEqual(store.document, before)
    }
    func testRevocationDuringPermissionCheckDiscardsLateReadyResult() throws {
        let store = try consentStore()
        XCTAssertTrue(store.set(.appleScreenTime, enabled: true, surface: .settings))
        let validation = SourceAccessValidation(store: store)
        var completion: ((SourceAccessStatus) -> Void)?
        validation.validate(.appleScreenTime) { _, done in completion = done }
        XCTAssertTrue(validation.checking)
        XCTAssertTrue(store.set(.appleScreenTime, enabled: false, surface: .settings))
        completion?(.ready)
        XCTAssertNil(validation.result)
        XCTAssertFalse(store.isEnabled(.appleScreenTime))
    }
    func testCancelledAndReplacedPermissionChecksCannotPublishStaleStatus() throws {
        let store = try consentStore()
        XCTAssertTrue(store.set(.aiConversations, enabled: true, surface: .settings))
        let validation = SourceAccessValidation(store: store)
        var first: ((SourceAccessStatus) -> Void)?
        validation.validate(.aiConversations) { _, done in first = done }
        validation.cancel(); first?(.ready)
        XCTAssertNil(validation.result)
        validation.validate(.aiConversations) { _, done in first = done }
        validation.validate(.aiConversations) { _, done in done(.fullDiskAccess) }
        first?(.ready)
        XCTAssertEqual(validation.result, .fullDiskAccess)
    }
    func testSetupAlwaysReviewsDataBeforeSourcesWithoutChangingLegacyStepIDs() {
        XCTAssertEqual(SetupStep.allCases, [.privacy, .sources, .ready])
        XCTAssertEqual(SetupStep.sources.rawValue, 1)
        XCTAssertEqual(SetupStep.ready.rawValue, 2)
        XCTAssertEqual(SetupStep.welcome.next, .privacy)
        XCTAssertEqual(SetupStep.sources.previous, .privacy)
        XCTAssertEqual(SetupStep.privacy.position, 1)
        XCTAssertNil(SetupStep.ready.next)
    }
    func testMinimalNewConfigurationLeavesAllOptionalFieldsOff() {
        let draft = DashboardSettingsDraft(config: .default)
        for signal in RecordingSignal.allCases { XCTAssertFalse(draft[keyPath: signal.keyPath], signal.title) }
        XCTAssertFalse(draft.capturePrivateBrowsing)
        XCTAssertTrue(draft.redactAllURLQueryValues)
    }
    func testWebsiteURLInputDropsPathsQueriesAndFragmentsBeforeSavingRules() throws {
        XCTAssertEqual(try PrivacyScopeInput.domains(" HTTPS://EXAMPLE.COM/path?token=do-not-store#secret\n*.example.com\nprivate.example.org "), ["example.com", "private.example.org"])
        var draft = DashboardSettingsDraft(config: .default)
        draft.excludedDomainsText = "https://EXAMPLE.com/private?token=synthetic"
        draft.includedDomainsText = "https://work.example.org/projects"
        try draft.validatePrivacyRules()
        let applied = draft.applying(to: .default)
        XCTAssertEqual(applied.excludedDomains, ["example.com"])
        XCTAssertEqual(applied.includedDomains, ["work.example.org"])
    }
    func testMalformedPrivacyScopesAreRejectedInsteadOfSilentlyIgnored() {
        for input in ["bad..example", "https://user:password@example.com", "ftp://example.com", "bad domain", "*", "https://"] {
            XCTAssertThrowsError(try PrivacyScopeInput.domains(input), input)
        }
        var draft = DashboardSettingsDraft(config: .default)
        draft.includedApplicationsText = "not a bundle identifier"
        XCTAssertThrowsError(try draft.validatePrivacyRules())
    }
    func testInvalidRuleApplicationRetainsExistingScopeAsDefenseInDepth() {
        var original = RecorderConfig.default
        original.excludedDomains = ["private.example"]
        original.includedDomains = ["work.example"]
        var draft = DashboardSettingsDraft(config: original)
        draft.excludedDomainsText = "bad..example"
        draft.includedDomainsText = "bad..example"
        let result = draft.applying(to: original)
        XCTAssertEqual(result.excludedDomains, original.excludedDomains)
        XCTAssertEqual(result.includedDomains, original.includedDomains)
    }
}
#endif
