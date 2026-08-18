import XCTest
import LocalHistoryCore

final class PublicProtocolAPITests: XCTestCase {
    func testRequestModelsCanBeConstructedOutsideCoreModule() {
        let registration = DeviceRegistrationRequest(
            challengeID: "challenge",
            deviceID: "device",
            publicKeyBase64: "public-key",
            signatureAlgorithm: "P-256",
            localTrustTier: "secure_enclave",
            appVersion: "0.3.2"
        )
        XCTAssertEqual(registration.deviceID, "device")

        let challenge = ChallengeRequest(deviceID: "device")
        XCTAssertEqual(challenge.deviceID, "device")

        let response = ChallengeResponse(challengeID: "challenge", challengeBase64: "nonce")
        XCTAssertEqual(response.challengeID, "challenge")

        let anchor = AnchorUploadRequest(
            deviceID: "device",
            anchorSequence: 1,
            minuteRoot: String(repeating: "a", count: 64),
            previousAnchorHash: String(repeating: "0", count: 64),
            anchorHash: String(repeating: "b", count: 64),
            signatureBase64: "signature",
            signatureAlgorithm: "P-256",
            appVersion: "0.3.2",
            challengeID: "challenge"
        )
        XCTAssertEqual(anchor.anchorSequence, 1)
    }
}
