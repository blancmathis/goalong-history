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

        func testUserCancelledOrDeniedKeychainPromptStopsAfterOneAttempt() {
            for status in [errSecUserCanceled, errSecAuthFailed] {
                var calls = 0
                let tiers: [() throws -> String] = [
                    { calls += 1; throw DeviceIdentityError.cannotLoadKey(status) }
                ]
                XCTAssertThrowsError(
                    try DeviceIdentity.resolveFirst(tiers, pause: { _ in XCTFail("No retry after a prompt answer") }))
                XCTAssertEqual(calls, 1)
            }
        }

        func testPersistentKeychainErrorStartsDegradedWithSealingSuspended() throws {
            let suite = "goalong-identity-test-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("known-device|secure_enclave", forKey: "goalong.deviceIdentity.last.v1")

            let startup = DeviceIdentityStartup.resolve(
                provider: { throw DeviceIdentityError.cannotLoadKey(errSecInteractionNotAllowed) },
                defaults: defaults)
            XCTAssertTrue(startup.isDegraded)
            XCTAssertEqual(startup.unavailableStatus, errSecInteractionNotAllowed)
            XCTAssertEqual(startup.info.deviceID, "known-device")
            XCTAssertThrowsError(try startup.identity.sign(Data("x".utf8))) { error in
                XCTAssertTrue((error as? DeviceIdentityError)?.shouldSuspendBackgroundSigning == true)
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("goalong-degraded-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sealer = MinuteSealer(
                stateStore: IntegrityStateStore(fileURL: directory.appendingPathComponent("state.json"), prepareStorage: {}),
                identity: startup.identity,
                sealDirectory: directory.appendingPathComponent("seals"),
                prepareStorage: {})
            sealer.suspendSigning(reason: "test")
            XCTAssertTrue(sealer.runtimeSnapshot.signingSuspended)
        }

        func testUnavailableTierDoesNotClaimAKey() {
            let info = UnavailableDeviceIdentity(status: errSecInteractionNotAllowed, deviceID: nil).info
            XCTAssertEqual(info.protectionTitle, "Signature suspendue")
            XCTAssertFalse(info.protectionSummary.contains("sont signés par"))
        }

        func testIdentityChangeSetsAVisibleRotationFlag() throws {
            let suite = "goalong-identity-test-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            DeviceIdentity.noteIdentity(info("a", "secure_enclave"), defaults: defaults)
            XCTAssertNil(DeviceIdentityRotation.load(defaults: defaults))
            DeviceIdentity.noteIdentity(info("b", "local_software"), defaults: defaults)
            let rotation = try XCTUnwrap(DeviceIdentityRotation.load(defaults: defaults))
            XCTAssertEqual(rotation.previousTier, "secure_enclave")
            XCTAssertEqual(rotation.newTier, "local_software")
            XCTAssertTrue(rotation.notice.contains("Secure Enclave"))
        }

        func testOnlyTheSecureEnclaveSummaryClaimsANonExportableKey() {
            for tier in ["secure_enclave", "keychain_software", "local_software"] {
                let summary = info("a", tier).protectionSummary
                XCTAssertEqual(summary.contains("non exportable"), tier == "secure_enclave", tier)
            }
        }
    }
#endif
