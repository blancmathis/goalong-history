import Foundation

public enum MinuteSealStorageFormat: Equatable {
    case fullCommitments
    case compactSalts
}

public struct LocalMinuteSeal: Codable, Equatable {
    private static let maximumPackedEventRootCount = 16_384

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
    /// Controls only the next LocalMinuteSeal JSON encoding.
    public let storageFormat: MinuteSealStorageFormat

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
        signatureAlgorithm: String,
        storageFormat: MinuteSealStorageFormat = .fullCommitments
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
        self.storageFormat = storageFormat
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case anchorSequence
        case minuteStart
        case minuteEnd
        case minuteFields
        case minuteIntegrity
        case eventRoots
        case minuteRoot
        case previousAnchorHash
        case anchorHash
        case deviceID
        case publicKeyBase64
        case trustTier
        case signatureBase64
        case signatureAlgorithm
    }

    private struct CompactMinuteIntegrityV1: Codable {
        static let formatName = "salts-v1"

        let format: String
        let fieldSalts: [String]
        let localDay: String
        let timeZone: String
        let utcOffsetSeconds: String
        let coverageFields: [String: String]
    }

    private struct PackedMinuteIntegrity: Codable {
        static let currentFormat = "material-v1"

        let format: String
        let materialBase64: String
        let localDay: String
        let timeZone: String
        let utcOffsetSeconds: String
        let coverageFields: [String: String]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let anchorSequence = try container.decode(UInt64.self, forKey: .anchorSequence)
        let minuteStart = try container.decode(Date.self, forKey: .minuteStart)
        let minuteEnd = try container.decode(Date.self, forKey: .minuteEnd)
        let deviceID = try container.decode(String.self, forKey: .deviceID)
        let publicKeyBase64 = try container.decode(String.self, forKey: .publicKeyBase64)
        let trustTier = try container.decode(String.self, forKey: .trustTier)
        let signatureBase64 = try container.decode(String.self, forKey: .signatureBase64)
        let signatureAlgorithm = try container.decode(String.self, forKey: .signatureAlgorithm)

        let eventRoots: [String]
        let minuteRoot: String
        let previousAnchorHash: String
        let anchorHash: String
        let minuteFields: [LocalFieldCommitment]
        let storageFormat: MinuteSealStorageFormat
        if schemaVersion >= 2,
            let compact = try? container.decode(
                PackedMinuteIntegrity.self,
                forKey: .minuteIntegrity
            ),
            compact.format == PackedMinuteIntegrity.currentFormat
        {
            guard let material = IntegrityMaterialPacking.unpack(
                compact.materialBase64,
                minimumHashCount: 3,
                maximumHashCount: 3 + Self.maximumPackedEventRootCount,
                saltCount: IntegrityDomains.minuteFieldOrder.count
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .minuteIntegrity,
                    in: container,
                    debugDescription: "Packed minute integrity material is invalid."
                )
            }
            minuteRoot = material.hashes[0]
            previousAnchorHash = material.hashes[1]
            anchorHash = material.hashes[2]
            eventRoots = Array(material.hashes.dropFirst(3))
            guard let rehydrated = MinuteIntegrityMaterial.rehydrateFieldCommitments(
                minuteStart: minuteStart,
                minuteEnd: minuteEnd,
                localDay: compact.localDay,
                timeZone: compact.timeZone,
                utcOffsetSeconds: compact.utcOffsetSeconds,
                eventRoots: eventRoots,
                coverageFields: compact.coverageFields,
                saltBase64Values: material.saltBase64Values
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .minuteIntegrity,
                    in: container,
                    debugDescription: "Packed minute integrity metadata or salts are invalid."
                )
            }
            minuteFields = rehydrated
            storageFormat = .compactSalts
        } else {
            eventRoots = try container.decode([String].self, forKey: .eventRoots)
            minuteRoot = try container.decode(String.self, forKey: .minuteRoot)
            previousAnchorHash = try container.decode(
                String.self,
                forKey: .previousAnchorHash
            )
            anchorHash = try container.decode(String.self, forKey: .anchorHash)
            if schemaVersion >= 2,
                let compact = try? container.decode(
                    CompactMinuteIntegrityV1.self,
                    forKey: .minuteIntegrity
                ),
                compact.format == CompactMinuteIntegrityV1.formatName
            {
                guard let rehydrated = MinuteIntegrityMaterial.rehydrateFieldCommitments(
                    minuteStart: minuteStart,
                    minuteEnd: minuteEnd,
                    localDay: compact.localDay,
                    timeZone: compact.timeZone,
                    utcOffsetSeconds: compact.utcOffsetSeconds,
                    eventRoots: eventRoots,
                    coverageFields: compact.coverageFields,
                    saltBase64Values: compact.fieldSalts
                ) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .minuteIntegrity,
                        in: container,
                        debugDescription: "Compact minute integrity metadata or salts are invalid."
                    )
                }
                minuteFields = rehydrated
                storageFormat = .compactSalts
            } else {
                minuteFields = try container.decode(
                    [LocalFieldCommitment].self,
                    forKey: .minuteFields
                )
                storageFormat = .fullCommitments
            }
        }

        self.init(
            schemaVersion: schemaVersion,
            anchorSequence: anchorSequence,
            minuteStart: minuteStart,
            minuteEnd: minuteEnd,
            minuteFields: minuteFields,
            eventRoots: eventRoots,
            minuteRoot: minuteRoot,
            previousAnchorHash: previousAnchorHash,
            anchorHash: anchorHash,
            deviceID: deviceID,
            publicKeyBase64: publicKeyBase64,
            trustTier: trustTier,
            signatureBase64: signatureBase64,
            signatureAlgorithm: signatureAlgorithm,
            storageFormat: storageFormat
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(anchorSequence, forKey: .anchorSequence)
        try container.encode(minuteStart, forKey: .minuteStart)
        try container.encode(minuteEnd, forKey: .minuteEnd)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(publicKeyBase64, forKey: .publicKeyBase64)
        try container.encode(trustTier, forKey: .trustTier)
        try container.encode(signatureBase64, forKey: .signatureBase64)
        try container.encode(signatureAlgorithm, forKey: .signatureAlgorithm)

        guard schemaVersion >= 2, storageFormat == .compactSalts else {
            try container.encode(eventRoots, forKey: .eventRoots)
            try container.encode(minuteRoot, forKey: .minuteRoot)
            try container.encode(previousAnchorHash, forKey: .previousAnchorHash)
            try container.encode(anchorHash, forKey: .anchorHash)
            try container.encode(minuteFields, forKey: .minuteFields)
            return
        }

        var commitmentsByName: [String: LocalFieldCommitment] = [:]
        commitmentsByName.reserveCapacity(minuteFields.count)
        for commitment in minuteFields {
            guard commitmentsByName.updateValue(commitment, forKey: commitment.name) == nil else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: container.codingPath + [CodingKeys.minuteIntegrity],
                        debugDescription: "Minute integrity contains duplicate field commitments."
                    )
                )
            }
        }
        let order = IntegrityDomains.minuteFieldOrder
        guard commitmentsByName.count == order.count else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.minuteIntegrity],
                    debugDescription: "Compact minute integrity is missing a required field commitment."
                )
            )
        }
        let fieldSalts = try order.map { name -> String in
            guard let value = commitmentsByName[name]?.opening.saltBase64,
                let salt = Data(base64Encoded: value),
                salt.count == 32
            else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: container.codingPath + [CodingKeys.minuteIntegrity],
                        debugDescription: "Compact minute integrity contains an invalid field salt."
                    )
                )
            }
            return value
        }
        guard let timeFields = commitmentsByName["time"]?.opening.fields,
            let localDay = timeFields["local_day"],
            let timeZone = timeFields["timezone"],
            let utcOffsetSeconds = timeFields["utc_offset_seconds"],
            let coverageFields = commitmentsByName["coverage"]?.opening.fields
        else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.minuteIntegrity],
                    debugDescription: "Compact minute integrity metadata is incomplete."
                )
            )
        }
        if let materialBase64 = IntegrityMaterialPacking.pack(
            hashes: [minuteRoot, previousAnchorHash, anchorHash] + eventRoots,
            saltBase64Values: fieldSalts
        ) {
            try container.encode(
                PackedMinuteIntegrity(
                    format: PackedMinuteIntegrity.currentFormat,
                    materialBase64: materialBase64,
                    localDay: localDay,
                    timeZone: timeZone,
                    utcOffsetSeconds: utcOffsetSeconds,
                    coverageFields: coverageFields
                ),
                forKey: .minuteIntegrity
            )
            return
        }

        // Preserve source compatibility for synthetic/custom seals whose roots are not
        // SHA-256 values. Production seals always take the smaller packed branch.
        try container.encode(eventRoots, forKey: .eventRoots)
        try container.encode(minuteRoot, forKey: .minuteRoot)
        try container.encode(previousAnchorHash, forKey: .previousAnchorHash)
        try container.encode(anchorHash, forKey: .anchorHash)
        try container.encode(
            CompactMinuteIntegrityV1(
                format: CompactMinuteIntegrityV1.formatName,
                fieldSalts: fieldSalts,
                localDay: localDay,
                timeZone: timeZone,
                utcOffsetSeconds: utcOffsetSeconds,
                coverageFields: coverageFields
            ),
            forKey: .minuteIntegrity
        )
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
