import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

public enum ShareLevel: String, Codable, CaseIterable {
    case everything
    case applicationOnly
    case categoryOnly
    case privateOnly
    case mixed

    public var title: String {
        switch self {
        case .everything: return "Everything"
        case .applicationOnly: return "Application only"
        case .categoryOnly: return "Category only"
        case .privateOnly: return "Completely private"
        case .mixed: return "Mixed per app and site"
        }
    }
}

public struct FieldDisclosure: Codable, Equatable {
    public let name: String
    public let commitmentHex: String
    public let opening: CommitmentOpening?

    public init(name: String, commitmentHex: String, opening: CommitmentOpening?) {
        self.name = name
        self.commitmentHex = commitmentHex
        self.opening = opening
    }

    public func verifies() -> Bool {
        guard let opening else { return true }
        return opening.commitmentHex() == commitmentHex
    }
}

public struct EventDisclosure: Codable, Equatable {
    public let eventRoot: String
    public let fieldCommitments: [FieldDisclosure]
    public let rawEvent: HistoryEvent?
    public let schemaVersion: Int?
    public let shareLevel: ShareLevel?

    public init(
        eventRoot: String,
        fieldCommitments: [FieldDisclosure],
        rawEvent: HistoryEvent?,
        schemaVersion: Int? = 2,
        shareLevel: ShareLevel? = nil
    ) {
        self.eventRoot = eventRoot
        self.fieldCommitments = fieldCommitments
        self.rawEvent = rawEvent
        self.schemaVersion = schemaVersion
        self.shareLevel = shareLevel
    }

    public func verifiesRoot() -> Bool {
        let resolvedSchemaVersion = schemaVersion ?? 2
        guard (2...5).contains(resolvedSchemaVersion), rawEvent == nil else { return false }
        let fieldOrder = IntegrityDomains.eventFieldOrder(for: resolvedSchemaVersion)
        guard let byName = exactCommitmentsByName(fieldCommitments, order: fieldOrder) else {
            return false
        }
        let leaves = fieldOrder.compactMap { name -> (String, String)? in
            guard let value = byName[name] else { return nil }
            return (name, value)
        }
        guard leaves.count == fieldOrder.count else { return false }
        guard fieldCommitments.allSatisfy({ $0.verifies() }) else { return false }
        return MerkleTree.root(labeledHexValues: leaves) == eventRoot
    }
}

private func exactCommitmentsByName(
    _ fields: [FieldDisclosure],
    order: [String]
) -> [String: String]? {
    guard fields.count == order.count else { return nil }
    var result: [String: String] = [:]
    result.reserveCapacity(fields.count)
    for field in fields {
        guard result.updateValue(field.commitmentHex, forKey: field.name) == nil else {
            return nil
        }
    }
    guard Set(result.keys) == Set(order) else { return nil }
    return result
}

public struct MinuteDisclosure: Codable, Equatable {
    public let anchorSequence: UInt64
    public let minuteRoot: String
    public let previousAnchorHash: String
    public let anchorHash: String
    public let shareLevel: ShareLevel
    public let minuteFields: [FieldDisclosure]
    public let eventRoots: [String]?
    public let events: [EventDisclosure]?
    public let signatureBase64: String?
    public let signatureAlgorithm: String?
    public let publicKeyBase64: String?
    public let deviceID: String
    public let trustTier: String
    public let liveReceiptID: String?

    public init(
        anchorSequence: UInt64,
        minuteRoot: String,
        previousAnchorHash: String,
        anchorHash: String,
        shareLevel: ShareLevel,
        minuteFields: [FieldDisclosure],
        eventRoots: [String]?,
        events: [EventDisclosure]?,
        signatureBase64: String?,
        signatureAlgorithm: String?,
        publicKeyBase64: String?,
        deviceID: String,
        trustTier: String,
        liveReceiptID: String?
    ) {
        self.anchorSequence = anchorSequence
        self.minuteRoot = minuteRoot
        self.previousAnchorHash = previousAnchorHash
        self.anchorHash = anchorHash
        self.shareLevel = shareLevel
        self.minuteFields = minuteFields
        self.eventRoots = eventRoots
        self.events = events
        self.signatureBase64 = signatureBase64
        self.signatureAlgorithm = signatureAlgorithm
        self.publicKeyBase64 = publicKeyBase64
        self.deviceID = deviceID
        self.trustTier = trustTier
        self.liveReceiptID = liveReceiptID
    }

    public func verifiesStructure() -> Bool {
        guard let minuteByName = exactCommitmentsByName(
            minuteFields,
            order: IntegrityDomains.minuteFieldOrder
        ) else { return false }
        let minuteLeaves = IntegrityDomains.minuteFieldOrder.compactMap { name -> (String, String)? in
            guard let value = minuteByName[name] else { return nil }
            return (name, value)
        }
        guard minuteLeaves.count == IntegrityDomains.minuteFieldOrder.count else { return false }
        guard minuteFields.allSatisfy({ $0.verifies() }) else { return false }
        guard MerkleTree.root(labeledHexValues: minuteLeaves) == minuteRoot else { return false }
        guard ChainHash.anchor(sequence: anchorSequence, previous: previousAnchorHash, minuteRoot: minuteRoot) == anchorHash else { return false }

        if shareLevel == .privateOnly {
            return eventRoots == nil && events == nil
        }

        guard let eventRoots, let events, eventRoots.count == events.count else { return false }
        guard zip(eventRoots, events).allSatisfy({ $0 == $1.eventRoot && $1.verifiesRoot() }) else { return false }

        let eventsRoot = MerkleTree.root(labeledHexValues: eventRoots.enumerated().map { ("event:\($0.offset)", $0.element) })
        guard let rootDisclosure = minuteFields.first(where: { $0.name == "events_root" }),
              let rootOpening = rootDisclosure.opening,
              rootOpening.fields["events_root"] == eventsRoot
        else { return false }

        guard let countDisclosure = minuteFields.first(where: { $0.name == "event_count" }),
              let countOpening = countDisclosure.opening,
              countOpening.fields["count"] == String(eventRoots.count)
        else { return false }

        return true
    }

    /// Verifies the P-256 signature carried by this disclosure against the
    /// exact minute-chain message that Goalong signs at capture time.
    ///
    /// This is intentionally separate from `verifiesStructure()`: older callers
    /// may still need to inspect structural commitments, while anything claiming
    /// local authenticity must require both checks through
    /// `verifiesLocallySignedIntegrity()`.
    public func verifiesDeviceSignature() -> Bool {
        AnchorSignatureVerifier.verifies(
            deviceID: deviceID,
            sequence: anchorSequence,
            previousAnchorHash: previousAnchorHash,
            minuteRoot: minuteRoot,
            publicKeyBase64: publicKeyBase64,
            signatureBase64: signatureBase64,
            signatureAlgorithm: signatureAlgorithm
        )
    }

    public func verifiesLocallySignedIntegrity() -> Bool {
        verifiesStructure() && verifiesDeviceSignature()
    }
}

public enum AnchorSignatureVerifier {
    public static let supportedAlgorithm = "P-256/ECDSA-X9.62-SHA256"

    public static func verifies(
        deviceID: String,
        sequence: UInt64,
        previousAnchorHash: String,
        minuteRoot: String,
        publicKeyBase64: String?,
        signatureBase64: String?,
        signatureAlgorithm: String?
    ) -> Bool {
        let message = ChainHash.signingMessage(
            deviceID: deviceID,
            sequence: sequence,
            previous: previousAnchorHash,
            minuteRoot: minuteRoot
        )
        return DeviceP256SignatureVerifier.verifies(
            message: message,
            deviceID: deviceID,
            publicKeyBase64: publicKeyBase64,
            signatureBase64: signatureBase64,
            signatureAlgorithm: signatureAlgorithm
        )
    }
}

public enum DeviceP256SignatureVerifier {
    public static func verifies(
        message: Data,
        deviceID: String,
        publicKeyBase64: String?,
        signatureBase64: String?,
        signatureAlgorithm: String?
    ) -> Bool {
        #if canImport(CryptoKit)
            guard signatureAlgorithm == AnchorSignatureVerifier.supportedAlgorithm,
                let publicKeyBase64,
                let signatureBase64,
                let publicKeyData = Data(base64Encoded: publicKeyBase64),
                let signatureData = Data(base64Encoded: signatureBase64),
                SHA256Digest.hashHex(publicKeyData) == deviceID,
                let publicKey = try? P256.Signing.PublicKey(
                    x963Representation: publicKeyData
                ),
                let signature = try? P256.Signing.ECDSASignature(
                    derRepresentation: signatureData
                )
            else { return false }

            return publicKey.isValidSignature(signature, for: message)
        #else
            return false
        #endif
    }
}

public struct DaySharePackageVerificationReport: Codable, Equatable {
    public let schemaVersion: Int
    public let isLocallyValid: Bool
    public let minuteCount: Int
    public let validStructureCount: Int
    public let validDeviceSignatureCount: Int
    public let referencedServerReceiptCount: Int
    public let unverifiedMetadataFields: [String]
    public let issues: [String]
    public let limitation: String

    public init(
        schemaVersion: Int = 1,
        isLocallyValid: Bool,
        minuteCount: Int,
        validStructureCount: Int,
        validDeviceSignatureCount: Int,
        referencedServerReceiptCount: Int,
        unverifiedMetadataFields: [String],
        issues: [String],
        limitation: String
    ) {
        self.schemaVersion = schemaVersion
        self.isLocallyValid = isLocallyValid
        self.minuteCount = minuteCount
        self.validStructureCount = validStructureCount
        self.validDeviceSignatureCount = validDeviceSignatureCount
        self.referencedServerReceiptCount = referencedServerReceiptCount
        self.unverifiedMetadataFields = unverifiedMetadataFields
        self.issues = issues
        self.limitation = limitation
    }
}

public struct DaySharePackage: Codable, Equatable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let deviceID: String
    public let deviceIDs: [String]?
    public let localDay: String
    public let classifierVersion: String
    public let boundaryBefore: MinuteDisclosure?
    public let boundaryAfter: MinuteDisclosure?
    public let minutes: [MinuteDisclosure]

    public init(
        schemaVersion: Int = 2,
        createdAt: Date = Date(),
        deviceID: String,
        deviceIDs: [String]? = nil,
        localDay: String,
        classifierVersion: String,
        boundaryBefore: MinuteDisclosure? = nil,
        boundaryAfter: MinuteDisclosure? = nil,
        minutes: [MinuteDisclosure]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.deviceID = deviceID
        self.deviceIDs = deviceIDs
        self.localDay = localDay
        self.classifierVersion = classifierVersion
        self.boundaryBefore = boundaryBefore
        self.boundaryAfter = boundaryAfter
        self.minutes = minutes
    }

    /// Performs the checks that are possible using only the exported package:
    /// commitments, Merkle roots, minute chaining, boundary linkage, declared
    /// device identities, and every embedded P-256 device signature.
    ///
    /// A receipt identifier is only an opaque reference. Without the signed
    /// receipt payload and its verifier key, this offline report deliberately
    /// does not claim that a server or Apple App Attest verified anything.
    public func verificationReport() -> DaySharePackageVerificationReport {
        var issues: [String] = []
        var validStructureCount = 0
        var validSignatureCount = 0

        // v2 is the single-device uniform-disclosure package, v3 adds
        // per-event disclosure levels, and v4 makes device rotation explicit.
        // Reject anything else instead of attempting a best-effort parse.
        if !(2...4).contains(schemaVersion) {
            issues.append("unsupported_package_schema")
        }

        if minutes.isEmpty {
            issues.append("package_contains_no_minutes")
        }

        for minute in minutes {
            if minute.verifiesStructure() {
                validStructureCount += 1
            } else {
                issues.append("minute_\(minute.anchorSequence)_structure_invalid")
            }
            if minute.verifiesDeviceSignature() {
                validSignatureCount += 1
            } else {
                issues.append("minute_\(minute.anchorSequence)_device_signature_invalid")
            }
            guard let time = minute.minuteFields.first(where: { $0.name == "time" }),
                time.opening?.fields["local_day"] == localDay
            else {
                issues.append("minute_\(minute.anchorSequence)_local_day_invalid")
                continue
            }
        }

        for (current, next) in zip(minutes, minutes.dropFirst()) {
            guard current.anchorSequence < UInt64.max,
                next.anchorSequence == current.anchorSequence + 1,
                next.previousAnchorHash == current.anchorHash
            else {
                issues.append("minute_chain_invalid_after_\(current.anchorSequence)")
                continue
            }
        }

        if let first = minutes.first, deviceID != first.deviceID {
            issues.append("primary_device_identity_mismatch")
        }

        let observedDeviceIDs = Set(minutes.map(\.deviceID))
        if let deviceIDs {
            if Set(deviceIDs).count != deviceIDs.count || Set(deviceIDs) != observedDeviceIDs {
                issues.append("declared_device_identities_mismatch")
            }
        } else if observedDeviceIDs.count > 1 || observedDeviceIDs.first != deviceID {
            issues.append("undeclared_device_identity_rotation")
        }

        if let boundaryBefore {
            if !boundaryBefore.verifiesLocallySignedIntegrity() {
                issues.append("boundary_before_invalid")
            }
            if let first = minutes.first {
                guard boundaryBefore.anchorSequence < UInt64.max,
                    boundaryBefore.anchorSequence + 1 == first.anchorSequence,
                    boundaryBefore.anchorHash == first.previousAnchorHash
                else {
                    issues.append("boundary_before_link_invalid")
                    return makeVerificationReport(
                        issues: issues,
                        validStructureCount: validStructureCount,
                        validSignatureCount: validSignatureCount
                    )
                }
            }
        }

        if let boundaryAfter {
            if !boundaryAfter.verifiesLocallySignedIntegrity() {
                issues.append("boundary_after_invalid")
            }
            if let last = minutes.last {
                guard last.anchorSequence < UInt64.max,
                    boundaryAfter.anchorSequence == last.anchorSequence + 1,
                    boundaryAfter.previousAnchorHash == last.anchorHash
                else {
                    issues.append("boundary_after_link_invalid")
                    return makeVerificationReport(
                        issues: issues,
                        validStructureCount: validStructureCount,
                        validSignatureCount: validSignatureCount
                    )
                }
            }
        }

        return makeVerificationReport(
            issues: issues,
            validStructureCount: validStructureCount,
            validSignatureCount: validSignatureCount
        )
    }

    private func makeVerificationReport(
        issues: [String],
        validStructureCount: Int,
        validSignatureCount: Int
    ) -> DaySharePackageVerificationReport {
        DaySharePackageVerificationReport(
            isLocallyValid: issues.isEmpty,
            minuteCount: minutes.count,
            validStructureCount: validStructureCount,
            validDeviceSignatureCount: validSignatureCount,
            referencedServerReceiptCount:
                minutes.filter { $0.liveReceiptID != nil }.count
                + (boundaryBefore?.liveReceiptID == nil ? 0 : 1)
                + (boundaryAfter?.liveReceiptID == nil ? 0 : 1),
            unverifiedMetadataFields: [
                "createdAt",
                "classifierVersion",
                "minute.shareLevel",
                "minute.trustTier",
                "minute.liveReceiptID",
                "event.shareLevel",
            ],
            issues: issues,
            limitation:
                "This offline report proves disclosed commitments, local-day binding, chains and signatures from the included local device keys. The listed metadata fields are not covered by those minute signatures. Receipt IDs are references only; it does not prove Apple App Attest, an external timestamp, the official Goalong build, or provider authorship."
        )
    }
}
