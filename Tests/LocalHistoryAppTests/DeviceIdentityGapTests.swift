#if os(macOS)
import Foundation
import Security
import XCTest
@testable import LocalHistoryApp

/// Titles, error classes and startup fallback of the device identity.
final class DeviceIdentityGapTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "goalong.test.deviceidentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testProtectionAndTierTitles() {
        func title(_ tier: String) -> String {
            DeviceIdentityInfo(deviceID: "d", publicKeyBase64: "", trustTier: tier, algorithm: "a").protectionTitle
        }
        XCTAssertEqual(title("secure_enclave"), "Protégée par la Secure Enclave")
        XCTAssertEqual(title("keychain_software"), "Protégée par le Trousseau")
        XCTAssertEqual(title("unavailable"), "Signature suspendue")
        XCTAssertEqual(title("local_software"), "Clé logicielle locale")
        XCTAssertEqual(DeviceIdentityRotation.tierTitle("secure_enclave"), "Secure Enclave")
        XCTAssertEqual(DeviceIdentityRotation.tierTitle("keychain_software"), "Trousseau")
        XCTAssertEqual(DeviceIdentityRotation.tierTitle("local_software"), "clé logicielle locale")
        XCTAssertEqual(DeviceIdentityRotation.tierTitle("???"), "inconnue")
    }

    func testErrorDescriptionsNameTheStatusAndSuspensionOnlyForUserBlockedSigning() {
        XCTAssertTrue(DeviceIdentityError.cannotCreateKey(-1).description.contains("-1"))
        XCTAssertTrue(DeviceIdentityError.cannotLoadKey(-2).description.contains("-2"))
        XCTAssertTrue(DeviceIdentityError.cannotExportPublicKey(-3).description.contains("-3"))
        XCTAssertTrue(DeviceIdentityError.identityUnavailable(-4).description.contains("-4"))
        XCTAssertFalse(DeviceIdentityError.cannotCopyPublicKey.description.isEmpty)
        XCTAssertFalse(DeviceIdentityError.cannotPersistSoftwareKey.description.isEmpty)
        XCTAssertFalse(DeviceIdentityError.cannotSign(nil).description.isEmpty)

        XCTAssertTrue(DeviceIdentityError.identityUnavailable(errSecInteractionNotAllowed).shouldSuspendBackgroundSigning)
        XCTAssertFalse(DeviceIdentityError.cannotSign(nil).shouldSuspendBackgroundSigning)
        XCTAssertFalse(DeviceIdentityError.cannotCreateKey(errSecUserCanceled).shouldSuspendBackgroundSigning)
        for code in [errSecUserCanceled, errSecInteractionNotAllowed, errSecAuthFailed] {
            let error = CFErrorCreate(nil, kCFErrorDomainOSStatus, CFIndex(code), nil)
            XCTAssertTrue(DeviceIdentityError.cannotSign(error).shouldSuspendBackgroundSigning, "\(code)")
        }
        let other = CFErrorCreate(nil, kCFErrorDomainOSStatus, CFIndex(errSecParam), nil)
        XCTAssertFalse(DeviceIdentityError.cannotSign(other).shouldSuspendBackgroundSigning)
    }

    func testStartupNeverFailsAndKeepsTheLastKnownDeviceID() {
        let defaults = defaults()
        let first = DeviceIdentityStartup.resolve(provider: { throw DeviceIdentityError.cannotLoadKey(errSecAuthFailed) },
                                                  defaults: defaults)
        XCTAssertTrue(first.isDegraded)
        XCTAssertEqual(first.unavailableStatus, errSecAuthFailed)
        XCTAssertNil(first.info.knownDeviceID, "No earlier ID: the placeholder is not a device")

        DeviceIdentity.noteIdentity(DeviceIdentityInfo(deviceID: "dev-1", publicKeyBase64: "", trustTier: "secure_enclave", algorithm: "a"),
                                    defaults: defaults)
        let second = DeviceIdentityStartup.resolve(provider: { throw DeviceIdentityError.cannotCreateKey(errSecMissingEntitlement) },
                                                   defaults: defaults)
        XCTAssertEqual(second.unavailableStatus, errSecMissingEntitlement)
        XCTAssertEqual(second.info.knownDeviceID, "dev-1")

        let other = DeviceIdentityStartup.resolve(provider: { throw DeviceIdentityError.cannotCopyPublicKey }, defaults: defaults)
        XCTAssertEqual(other.unavailableStatus, errSecInteractionNotAllowed, "Unknown errors suspend as « interaction not allowed »")
    }

    func testRotationNoticeIsKeptUntilAcknowledgedAndMalformedValuesAreIgnored() throws {
        let defaults = defaults()
        XCTAssertNil(DeviceIdentityRotation.load(defaults: defaults))
        defaults.set("not-a-rotation", forKey: DeviceIdentity.rotationKey)
        XCTAssertNil(DeviceIdentityRotation.load(defaults: defaults))
        defaults.set("abc|a|b", forKey: DeviceIdentity.rotationKey)
        XCTAssertNil(DeviceIdentityRotation.load(defaults: defaults), "A non-numeric date is rejected")

        let before = DeviceIdentityInfo(deviceID: "d", publicKeyBase64: "", trustTier: "secure_enclave", algorithm: "a")
        let after = DeviceIdentityInfo(deviceID: "d", publicKeyBase64: "", trustTier: "local_software", algorithm: "a")
        DeviceIdentity.noteIdentity(before, defaults: defaults, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(DeviceIdentityRotation.load(defaults: defaults), "First launch is not a change")
        DeviceIdentity.noteIdentity(after, defaults: defaults, now: Date(timeIntervalSince1970: 2_000))
        let rotation = DeviceIdentityRotation.load(defaults: defaults)
        XCTAssertEqual(rotation, DeviceIdentityRotation(at: Date(timeIntervalSince1970: 2_000),
                                                         previousTier: "secure_enclave", newTier: "local_software"))
        XCTAssertTrue(try XCTUnwrap(rotation).notice.contains("Secure Enclave → clé logicielle locale"))
        DeviceTrustState.acknowledgeRotation(defaults: defaults)
        XCTAssertNil(DeviceIdentityRotation.load(defaults: defaults))
    }

    func testRetryFeedbackFollowsTheSuspendedState() throws {
        let state = DeviceTrustState()
        XCTAssertNil(state.retryFeedback)
        XCTAssertNil(state.sealingSuspendedNotice)
        state.setSealingSuspended(status: errSecAuthFailed)
        XCTAssertNotNil(state.sealingSuspendedNotice)
        XCTAssertNil(state.retryFeedback)
        XCTAssertTrue(state.beginRetry())
        XCTAssertFalse(state.beginRetry(), "A second click never overlaps")
        XCTAssertEqual(state.retryFeedback, "Nouvelle tentative en cours…")
        state.markRetryFailed(at: Date())
        XCTAssertFalse(state.isRetryInFlight)
        XCTAssertTrue(try XCTUnwrap(state.retryFeedback).contains("trousseau toujours inaccessible"))
        state.setSealingSuspended(status: nil)
        XCTAssertNil(state.retryFeedback, "Recovery clears the failure line")
        XCTAssertNil(state.sealingSuspendedNotice)
    }
}
#endif
