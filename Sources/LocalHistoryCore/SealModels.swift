import Foundation

public struct LocalMinuteSeal: Codable, Equatable {
    public let schemaVersion: Int
    public let anchorSequence: UInt64
    public let minuteStart: Date
    public let minuteEnd: Date
    public let minuteFields: [LocalFieldCommitment]
    public let eventRoots: [String]
    public let minuteRoot: String
    public let previousAnchorHash: String
    public let anchorHash: String
    public let deviceID: String
    public let publicKeyBase64: String
    public let trustTier: String
    public let signatureBase64: String
    public let signatureAlgorithm: String

    public init(
        schemaVersion: Int = 1,
        anchorSequence: UInt64,
        minuteStart: Date,
        minuteEnd: Date,
        minuteFields: [LocalFieldCommitment],
        eventRoots: [String],
        minuteRoot: String,
        previousAnchorHash: String,
        anchorHash: String,
        deviceID: String,
        publicKeyBase64: String,
        trustTier: String,
        signatureBase64: String,
        signatureAlgorithm: String
    ) {
        self.schemaVersion = schemaVersion
        self.anchorSequence = anchorSequence
        self.minuteStart = minuteStart
        self.minuteEnd = minuteEnd
        self.minuteFields = minuteFields
        self.eventRoots = eventRoots
        self.minuteRoot = minuteRoot
        self.previousAnchorHash = previousAnchorHash
        self.anchorHash = anchorHash
        self.deviceID = deviceID
        self.publicKeyBase64 = publicKeyBase64
        self.trustTier = trustTier
        self.signatureBase64 = signatureBase64
        self.signatureAlgorithm = signatureAlgorithm
    }
}

public struct AnchorReceipt: Codable, Equatable {
    public let schemaVersion: Int
    public let deviceID: String
    public let anchorSequence: UInt64
    public let anchorHash: String
    public let receiptID: String
    public let receivedAt: Date
    public let appAttestAccepted: Bool
    public let serverSignature: String?

    public init(
        schemaVersion: Int = 1,
        deviceID: String,
        anchorSequence: UInt64,
        anchorHash: String,
        receiptID: String,
        receivedAt: Date,
        appAttestAccepted: Bool,
        serverSignature: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.anchorSequence = anchorSequence
        self.anchorHash = anchorHash
        self.receiptID = receiptID
        self.receivedAt = receivedAt
        self.appAttestAccepted = appAttestAccepted
        self.serverSignature = serverSignature
    }
}

public struct DeviceRegistrationRequest: Codable {
    public let challengeID: String
    public let deviceID: String
    public let publicKeyBase64: String
    public let signatureAlgorithm: String
    public let localTrustTier: String
    public let appVersion: String
    public let appAttestKeyID: String?
    public let appAttestationObjectBase64: String?

    public init(
        challengeID: String,
        deviceID: String,
        publicKeyBase64: String,
        signatureAlgorithm: String,
        localTrustTier: String,
        appVersion: String,
        appAttestKeyID: String? = nil,
        appAttestationObjectBase64: String? = nil
    ) {
        self.challengeID = challengeID
        self.deviceID = deviceID
        self.publicKeyBase64 = publicKeyBase64
        self.signatureAlgorithm = signatureAlgorithm
        self.localTrustTier = localTrustTier
        self.appVersion = appVersion
        self.appAttestKeyID = appAttestKeyID
        self.appAttestationObjectBase64 = appAttestationObjectBase64
    }
}

public struct ChallengeRequest: Codable {
    public let deviceID: String

    public init(deviceID: String) {
        self.deviceID = deviceID
    }
}

public struct ChallengeResponse: Codable {
    public let challengeID: String
    public let challengeBase64: String

    public init(challengeID: String, challengeBase64: String) {
        self.challengeID = challengeID
        self.challengeBase64 = challengeBase64
    }
}

public struct AnchorUploadRequest: Codable {
    public let deviceID: String
    public let anchorSequence: UInt64
    public let minuteRoot: String
    public let previousAnchorHash: String
    public let anchorHash: String
    public let signatureBase64: String
    public let signatureAlgorithm: String
    public let appVersion: String
    public let challengeID: String
    public let appAttestKeyID: String?
    public let appAttestAssertionBase64: String?

    public init(
        deviceID: String,
        anchorSequence: UInt64,
        minuteRoot: String,
        previousAnchorHash: String,
        anchorHash: String,
        signatureBase64: String,
        signatureAlgorithm: String,
        appVersion: String,
        challengeID: String,
        appAttestKeyID: String? = nil,
        appAttestAssertionBase64: String? = nil
    ) {
        self.deviceID = deviceID
        self.anchorSequence = anchorSequence
        self.minuteRoot = minuteRoot
        self.previousAnchorHash = previousAnchorHash
        self.anchorHash = anchorHash
        self.signatureBase64 = signatureBase64
        self.signatureAlgorithm = signatureAlgorithm
        self.appVersion = appVersion
        self.challengeID = challengeID
        self.appAttestKeyID = appAttestKeyID
        self.appAttestAssertionBase64 = appAttestAssertionBase64
    }
}
