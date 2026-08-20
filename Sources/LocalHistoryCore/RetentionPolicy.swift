import Foundation

public enum HistoryDataClass: String, Codable, CaseIterable {
    case detailedEvents
    case semanticSnapshots
    case memories
    case analysisCaches
    case minuteSeals
    case anchorReceipts

    public var isCryptographicProof: Bool {
        self == .minuteSeals || self == .anchorReceipts
    }

    public var isDerived: Bool {
        self == .memories || self == .analysisCaches
    }
}

/// `days == nil` means keep until explicit deletion. A non-nil value is clamped
/// to a conservative maximum and never interpreted as permission to delete a
/// different data class.
public struct RetentionDuration: Codable, Equatable {
    public let days: Int?

    public init(days: Int?) {
        if let days {
            self.days = min(max(0, days), 3_650)
        } else {
            self.days = nil
        }
    }

    public static let indefinite = RetentionDuration(days: nil)

    public func cutoff(relativeTo now: Date, calendar: Calendar = .current) -> Date? {
        guard let days else { return nil }
        return calendar.date(byAdding: .day, value: -days, to: now)
    }
}

public struct HistoryRetentionPolicy: Codable, Equatable {
    public let schemaVersion: Int
    public var detailedEvents: RetentionDuration
    public var semanticSnapshots: RetentionDuration
    public var memories: RetentionDuration
    public var analysisCaches: RetentionDuration
    public var minuteSeals: RetentionDuration
    public var anchorReceipts: RetentionDuration
    public let migratedFromLegacyRetentionDays: Int?

    public init(
        schemaVersion: Int = 1,
        detailedEvents: RetentionDuration,
        semanticSnapshots: RetentionDuration,
        memories: RetentionDuration,
        analysisCaches: RetentionDuration,
        minuteSeals: RetentionDuration,
        anchorReceipts: RetentionDuration,
        migratedFromLegacyRetentionDays: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.detailedEvents = detailedEvents
        self.semanticSnapshots = semanticSnapshots
        self.memories = memories
        self.analysisCaches = analysisCaches
        self.minuteSeals = minuteSeals
        self.anchorReceipts = anchorReceipts
        self.migratedFromLegacyRetentionDays = migratedFromLegacyRetentionDays
    }

    /// Non-destructive migration from the existing single `retentionDays` value.
    /// Existing raw and semantic data keep the old window; memories and proofs are
    /// retained until the user explicitly chooses a policy for them.
    public static func migratingLegacy(retentionDays: Int) -> HistoryRetentionPolicy {
        let legacy = min(max(0, retentionDays), 3_650)
        let inherited: RetentionDuration = legacy == 0 ? .indefinite : RetentionDuration(days: legacy)
        return HistoryRetentionPolicy(
            detailedEvents: inherited,
            semanticSnapshots: inherited,
            memories: .indefinite,
            analysisCaches: inherited,
            minuteSeals: .indefinite,
            anchorReceipts: .indefinite,
            migratedFromLegacyRetentionDays: legacy
        )
    }

    public func duration(for dataClass: HistoryDataClass) -> RetentionDuration {
        switch dataClass {
        case .detailedEvents: return detailedEvents
        case .semanticSnapshots: return semanticSnapshots
        case .memories: return memories
        case .analysisCaches: return analysisCaches
        case .minuteSeals: return minuteSeals
        case .anchorReceipts: return anchorReceipts
        }
    }
}

public struct HistoryStoredArtifact: Codable, Equatable, Identifiable {
    public let id: String
    public let dataClass: HistoryDataClass
    public let start: Date
    public let end: Date
    public let localPath: String

    public init(
        id: String,
        dataClass: HistoryDataClass,
        start: Date,
        end: Date,
        localPath: String
    ) {
        self.id = id
        self.dataClass = dataClass
        self.start = start
        self.end = max(start, end)
        self.localPath = localPath
    }
}

public enum RetentionDecisionReason: String, Codable {
    case withinRetentionWindow
    case indefiniteRetention
    case expiredByPolicy
}

public struct RetentionDecision: Codable, Equatable {
    public let artifact: HistoryStoredArtifact
    public let shouldDelete: Bool
    public let reason: RetentionDecisionReason

    public init(
        artifact: HistoryStoredArtifact,
        shouldDelete: Bool,
        reason: RetentionDecisionReason
    ) {
        self.artifact = artifact
        self.shouldDelete = shouldDelete
        self.reason = reason
    }
}

public enum RetentionPlanner {
    public static func decisions(
        for artifacts: [HistoryStoredArtifact],
        policy: HistoryRetentionPolicy,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RetentionDecision] {
        artifacts.map { artifact in
            let duration = policy.duration(for: artifact.dataClass)
            guard let cutoff = duration.cutoff(relativeTo: now, calendar: calendar) else {
                return RetentionDecision(
                    artifact: artifact,
                    shouldDelete: false,
                    reason: .indefiniteRetention
                )
            }
            let expired = artifact.end < cutoff
            return RetentionDecision(
                artifact: artifact,
                shouldDelete: expired,
                reason: expired ? .expiredByPolicy : .withinRetentionWindow
            )
        }
    }
}

public enum HistoryDeletionScope: String, Codable, CaseIterable {
    case timelineEntry
    case interval
    case day
    case allDetailedData
    case allMemories
    case allDerivedData
    case allLocalHistoryIncludingProofs
}

public struct HistoryDeletionRequest: Codable, Equatable {
    public let scope: HistoryDeletionScope
    public let start: Date?
    public let end: Date?
    public let timelineEntryID: String?
    /// Cryptographic proofs require a second, explicit choice. A generic "delete
    /// history" action must never silently erase them.
    public let includeCryptographicProofs: Bool

    public init(
        scope: HistoryDeletionScope,
        start: Date? = nil,
        end: Date? = nil,
        timelineEntryID: String? = nil,
        includeCryptographicProofs: Bool = false
    ) {
        self.scope = scope
        self.start = start
        self.end = end
        self.timelineEntryID = timelineEntryID
        self.includeCryptographicProofs = includeCryptographicProofs
    }
}

public struct HistoryDeletionPlan: Codable, Equatable {
    public let request: HistoryDeletionRequest
    public let matchingArtifactIDs: [String]
    public let preservedProofArtifactIDs: [String]
    public let explanation: String

    public init(
        request: HistoryDeletionRequest,
        matchingArtifactIDs: [String],
        preservedProofArtifactIDs: [String],
        explanation: String
    ) {
        self.request = request
        self.matchingArtifactIDs = matchingArtifactIDs
        self.preservedProofArtifactIDs = preservedProofArtifactIDs
        self.explanation = explanation
    }
}

public enum HistoryDeletionPlanner {
    public static func plan(
        request: HistoryDeletionRequest,
        artifacts: [HistoryStoredArtifact]
    ) -> HistoryDeletionPlan {
        let scoped = artifacts.filter { artifact in
            switch request.scope {
            case .timelineEntry:
                return request.timelineEntryID == artifact.id
            case .interval, .day:
                guard let start = request.start, let end = request.end else { return false }
                return artifact.end >= start && artifact.start <= end
            case .allDetailedData:
                return artifact.dataClass == .detailedEvents || artifact.dataClass == .semanticSnapshots
            case .allMemories:
                return artifact.dataClass == .memories
            case .allDerivedData:
                return artifact.dataClass == .memories || artifact.dataClass == .analysisCaches
            case .allLocalHistoryIncludingProofs:
                return true
            }
        }

        var deletable: [HistoryStoredArtifact] = []
        var preservedProofs: [HistoryStoredArtifact] = []
        for artifact in scoped {
            if artifact.dataClass.isCryptographicProof,
                !request.includeCryptographicProofs
            {
                preservedProofs.append(artifact)
            } else {
                deletable.append(artifact)
            }
        }

        let explanation: String
        if preservedProofs.isEmpty {
            explanation = "The selected local artifacts can be deleted. This plan does not claim that already published external commitments can be erased."
        } else {
            explanation = "Detailed or derived data can be deleted, but local seals and receipts are preserved unless cryptographic-proof deletion is explicitly selected. Already published commitments may remain externally observable."
        }

        return HistoryDeletionPlan(
            request: request,
            matchingArtifactIDs: deletable.map(\.id).sorted(),
            preservedProofArtifactIDs: preservedProofs.map(\.id).sorted(),
            explanation: explanation
        )
    }
}
