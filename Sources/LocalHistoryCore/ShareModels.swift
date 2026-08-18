import Foundation

public enum ShareLevel: String, Codable, CaseIterable {
    case everything
    case applicationOnly
    case categoryOnly
    case privateOnly

    public var title: String {
        switch self {
        case .everything: return "Everything"
        case .applicationOnly: return "Application only"
        case .categoryOnly: return "Category only"
        case .privateOnly: return "Completely private"
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

    public init(eventRoot: String, fieldCommitments: [FieldDisclosure], rawEvent: HistoryEvent?) {
        self.eventRoot = eventRoot
        self.fieldCommitments = fieldCommitments
        self.rawEvent = rawEvent
    }

    public func verifiesRoot() -> Bool {
        let byName = Dictionary(uniqueKeysWithValues: fieldCommitments.map { ($0.name, $0.commitmentHex) })
        let leaves = IntegrityDomains.eventFieldOrder.compactMap { name -> (String, String)? in
            guard let value = byName[name] else { return nil }
            return (name, value)
        }
        guard leaves.count == IntegrityDomains.eventFieldOrder.count else { return false }
        guard fieldCommitments.allSatisfy({ $0.verifies() }) else { return false }
        return MerkleTree.root(labeledHexValues: leaves) == eventRoot
    }
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
        let minuteByName = Dictionary(uniqueKeysWithValues: minuteFields.map { ($0.name, $0.commitmentHex) })
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
}

public struct DaySharePackage: Codable, Equatable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let deviceID: String
    public let localDay: String
    public let classifierVersion: String
    public let boundaryBefore: MinuteDisclosure?
    public let boundaryAfter: MinuteDisclosure?
    public let minutes: [MinuteDisclosure]

    public init(
        schemaVersion: Int = 2,
        createdAt: Date = Date(),
        deviceID: String,
        localDay: String,
        classifierVersion: String,
        boundaryBefore: MinuteDisclosure? = nil,
        boundaryAfter: MinuteDisclosure? = nil,
        minutes: [MinuteDisclosure]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.deviceID = deviceID
        self.localDay = localDay
        self.classifierVersion = classifierVersion
        self.boundaryBefore = boundaryBefore
        self.boundaryAfter = boundaryAfter
        self.minutes = minutes
    }
}
