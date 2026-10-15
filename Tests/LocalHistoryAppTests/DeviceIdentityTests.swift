#if os(macOS)
    import Foundation
    import Security
    import XCTest
    @testable import LocalHistoryApp

    final class DeviceIdentityTests: XCTestCase {
        private func info(_ id: String, _ tier: String) -> DeviceIdentityInfo {
            DeviceIdentityInfo(deviceID: id, publicKeyBase64: "", trustTier: tier, algorithm: "test")
        }

        func testUnreadableExistingKeyIsRetriedThenThrownWithoutCreatingALowerTierKey() {
            var firstTierCalls = 0, lowerTierCalls = 0, pauses = 0
            let tiers: [() throws -> String] = [
                { firstTierCalls += 1; throw DeviceIdentityError.cannotLoadKey(errSecInteractionNotAllowed) },
                { lowerTierCalls += 1; return "lower" },
            ]
            XCTAssertThrowsError(try DeviceIdentity.resolveFirst(tiers, attempts: 3, pause: { _ in pauses += 1 }))
            XCTAssertEqual(firstTierCalls, 3)
            XCTAssertEqual(pauses, 2)
            XCTAssertEqual(lowerTierCalls, 0)
        }

        func testTransientLoadErrorThatClearsKeepsTheSameTier() throws {
            var calls = 0
            let tiers: [() throws -> String] = [
                { calls += 1; if calls < 2 { throw DeviceIdentityError.cannotLoadKey(errSecNotAvailable) }; return "first" },
                { XCTFail("Must not fall through"); return "lower" },
            ]
            XCTAssertEqual(try DeviceIdentity.resolveFirst(tiers, pause: { _ in }), "first")
        }

        func testMissingEntitlementAndRefusedCreationStillFallThrough() throws {
            let tiers: [() throws -> String] = [
                { throw DeviceIdentityError.cannotLoadKey(errSecMissingEntitlement) },
                { throw DeviceIdentityError.cannotCreateKey(errSecParam) },
                { "third" },
            ]
            XCTAssertEqual(try DeviceIdentity.resolveFirst(tiers, pause: { _ in XCTFail("No retry for unavailable tiers") }), "third")
            XCTAssertNil(try DeviceIdentity.resolveFirst([{ throw DeviceIdentityError.cannotLoadKey(errSecMissingEntitlement) } as () throws -> String]))
        }

        func testDeviceIdentityChangeIsDetectedAgainstThePersistedValue() {
            XCTAssertFalse(DeviceIdentity.identityChanged(previous: nil, current: info("a", "secure_enclave")))
            XCTAssertFalse(DeviceIdentity.identityChanged(previous: "a|secure_enclave", current: info("a", "secure_enclave")))
            XCTAssertTrue(DeviceIdentity.identityChanged(previous: "a|secure_enclave", current: info("b", "secure_enclave")))
            XCTAssertTrue(DeviceIdentity.identityChanged(previous: "a|secure_enclave", current: info("a", "keychain_software")))
        }

        func testOnlyTheSecureEnclaveSummaryClaimsANonExportableKey() {
            for tier in ["secure_enclave", "keychain_software", "local_software"] {
                let summary = info("a", tier).protectionSummary
                XCTAssertEqual(summary.contains("non exportable"), tier == "secure_enclave", tier)
            }
        }
    }
#endif
