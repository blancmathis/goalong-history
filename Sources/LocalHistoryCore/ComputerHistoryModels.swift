import Foundation

/// Stable metadata keys shared by the macOS recorder and the deterministic analysis layer.
/// Captured text remains untrusted data and is never interpreted as an instruction.
public enum ComputerHistoryMetadata {
    public static let interactionID = "computer_history.interaction_id"
    public static let interactionPhase = "computer_history.interaction_phase"
    public static let interactionTrigger = "computer_history.interaction_trigger"
    public static let semanticDelta = "computer_history.semantic_delta"
    public static let resourceURI = "computer_history.resource_uri"
    public static let resourceKind = "computer_history.resource_kind"

    public enum Phase {
        public static let before = "before"
        /// Context sampled close to an input callback without a guarantee that the
        /// foreground application had not already reacted to that input.
        public static let nearEvent = "near_event"
        public static let after = "after"
        public static let settled = "settled"
    }
}

public enum ComputerHistoryActionKind: String, Codable, CaseIterable {
    case click
    case drag
    case typing
    case shortcut
    case navigationKey
    case scroll
    case applicationSwitch
    case windowChange
    case pageChange
    case focusChange
    case contextObservation
}

public enum ComputerHistoryResourceKind: String, Codable, CaseIterable {
    case file
    case webPage
    case conversation
    case issue
    case document
    case terminalSession
    case application
    case unknown
}

public enum ComputerHistoryTaskStatus: String, Codable, CaseIterable {
    case planned
    case inProgress
    case completed
    case blocked
    case waiting
    case unknown
}

public enum ComputerHistorySuggestionKind: String, Codable, CaseIterable {
    case skill
    case automation
}

public struct ComputerHistoryResourceReference: Codable, Equatable, Identifiable {
    public let id: String
    public let kind: ComputerHistoryResourceKind
    public let title: String
    public let canonicalURI: String?
    public let localPath: String?
    public let host: String?
    public let application: String?
    public let bundleIdentifier: String?
    public let locatorConfidence: Double
    public let firstSeen: Date
    public let lastSeen: Date
    public let provenance: ActivityProvenance

    public init(
        id: String,
        kind: ComputerHistoryResourceKind,
        title: String,
        canonicalURI: String?,
        localPath: String?,
        host: String?,
        application: String?,
        bundleIdentifier: String?,
        locatorConfidence: Double,
        firstSeen: Date,
        lastSeen: Date,
        provenance: ActivityProvenance
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.canonicalURI = canonicalURI
        self.localPath = localPath
        self.host = host
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.locatorConfidence = min(1, max(0, locatorConfidence))
        self.firstSeen = firstSeen
        self.lastSeen = max(firstSeen, lastSeen)
        self.provenance = provenance
    }
}

public struct ComputerHistoryInteraction: Codable, Equatable, Identifiable {
    public let id: String
    public let start: Date
    public let end: Date
    public let action: ComputerHistoryActionKind
    public let label: String
    public let application: String?
    public let bundleIdentifier: String?
    public let host: String?
    public let resourceIDs: [String]
    public let beforeContext: String?
    public let afterContext: String?
    public let semanticDelta: [String]
    public let confidence: Double
    public let provenance: ActivityProvenance

    public init(
        id: String,
        start: Date,
        end: Date,
        action: ComputerHistoryActionKind,
        label: String,
        application: String?,
        bundleIdentifier: String?,
        host: String?,
        resourceIDs: [String],
        beforeContext: String?,
        afterContext: String?,
        semanticDelta: [String],
        confidence: Double,
        provenance: ActivityProvenance
    ) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.action = action
        self.label = label
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.host = host
        self.resourceIDs = resourceIDs
        self.beforeContext = beforeContext
        self.afterContext = afterContext
        self.semanticDelta = semanticDelta
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }
}

public struct ComputerHistoryEpisode: Codable, Equatable, Identifiable {
    public let id: String
    public let start: Date
    public let end: Date
    public let title: String
    public let summary: String
    public let status: ComputerHistoryTaskStatus
    public let statusConfidence: Double
    public let applications: [String]
    public let sites: [String]
    public let resourceIDs: [String]
    public let requestsOrIntentions: [String]
    public let observableOutcomes: [String]
    public let interactions: [ComputerHistoryInteraction]
    /// Exact number of interactions analyzed for this episode when `interactions`
    /// is a bounded representative projection. A missing value means the legacy
    /// payload retained the complete interaction array.
    public let sourceInteractionCount: Int?
    public let eventCount: Int
    public let semanticSnapshotCount: Int
    public let workflowFingerprint: String
    public let provenance: ActivityProvenance

    public init(
        id: String,
        start: Date,
        end: Date,
        title: String,
        summary: String,
        status: ComputerHistoryTaskStatus,
        statusConfidence: Double,
        applications: [String],
        sites: [String],
        resourceIDs: [String],
        requestsOrIntentions: [String],
        observableOutcomes: [String],
        interactions: [ComputerHistoryInteraction],
        sourceInteractionCount: Int? = nil,
        eventCount: Int,
        semanticSnapshotCount: Int,
        workflowFingerprint: String,
        provenance: ActivityProvenance
    ) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.title = title
        self.summary = summary
        self.status = status
        self.statusConfidence = min(1, max(0, statusConfidence))
        self.applications = applications
        self.sites = sites
        self.resourceIDs = resourceIDs
        self.requestsOrIntentions = requestsOrIntentions
        self.observableOutcomes = observableOutcomes
        self.interactions = interactions
        self.sourceInteractionCount = sourceInteractionCount.map {
            max(interactions.count, $0)
        }
        self.eventCount = max(0, eventCount)
        self.semanticSnapshotCount = max(0, semanticSnapshotCount)
        self.workflowFingerprint = workflowFingerprint
        self.provenance = provenance
    }

    /// Exact interaction count independent of whether the persisted memory uses
    /// the full legacy array or the bounded representative projection.
    public var totalInteractionCount: Int {
        sourceInteractionCount ?? interactions.count
    }
}

public struct ComputerHistoryWorkflowPattern: Codable, Equatable, Identifiable {
    public let id: String
    public let fingerprint: String
    public let title: String
    public let occurrenceCount: Int
    public let episodeIDs: [String]
    public let actionSequence: [String]
    public let applications: [String]
    public let confidence: Double

    public init(
        id: String,
        fingerprint: String,
        title: String,
        occurrenceCount: Int,
        episodeIDs: [String],
        actionSequence: [String],
        applications: [String],
        confidence: Double
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.title = title
        self.occurrenceCount = max(1, occurrenceCount)
        self.episodeIDs = episodeIDs
        self.actionSequence = actionSequence
        self.applications = applications
        self.confidence = min(1, max(0, confidence))
    }
}

public struct ComputerHistorySuggestion: Codable, Equatable, Identifiable {
    public let id: String
    public let kind: ComputerHistorySuggestionKind
    public let title: String
    public let rationale: String
    public let suggestedPrompt: String
    public let workflowID: String?
    public let episodeIDs: [String]
    public let confidence: Double

    public init(
        id: String,
        kind: ComputerHistorySuggestionKind,
        title: String,
        rationale: String,
        suggestedPrompt: String,
        workflowID: String?,
        episodeIDs: [String],
        confidence: Double
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.rationale = rationale
        self.suggestedPrompt = suggestedPrompt
        self.workflowID = workflowID
        self.episodeIDs = episodeIDs
        self.confidence = min(1, max(0, confidence))
    }
}

public struct ComputerHistoryCoverage: Codable, Equatable {
    public let sourceEventCount: Int
    public let actionEventCount: Int
    public let semanticSnapshotCount: Int
    public let linkedInteractionCount: Int
    public let interactionsWithBeforeAndAfterContext: Int
    public let resourceCount: Int
    public let episodeCount: Int
    public let suppressedEventCount: Int
    public let firstSourceSequence: UInt64?
    public let lastSourceSequence: UInt64?
    public let lastSourceEventHash: String?
    /// Present only when the derived memory is a representative projection.
    /// The corresponding unqualified counts above always describe the complete
    /// source sequence that was analyzed.
    public let retainedEpisodeCount: Int?
    public let retainedInteractionCount: Int?
    public let retainedResourceCount: Int?

    public init(
        sourceEventCount: Int,
        actionEventCount: Int,
        semanticSnapshotCount: Int,
        linkedInteractionCount: Int,
        interactionsWithBeforeAndAfterContext: Int,
        resourceCount: Int,
        episodeCount: Int,
        suppressedEventCount: Int,
        firstSourceSequence: UInt64?,
        lastSourceSequence: UInt64?,
        lastSourceEventHash: String?,
        retainedEpisodeCount: Int? = nil,
        retainedInteractionCount: Int? = nil,
        retainedResourceCount: Int? = nil
    ) {
        self.sourceEventCount = max(0, sourceEventCount)
        self.actionEventCount = max(0, actionEventCount)
        self.semanticSnapshotCount = max(0, semanticSnapshotCount)
        let normalizedLinkedInteractionCount = max(0, linkedInteractionCount)
        let normalizedResourceCount = max(0, resourceCount)
        self.linkedInteractionCount = normalizedLinkedInteractionCount
        self.interactionsWithBeforeAndAfterContext = max(0, interactionsWithBeforeAndAfterContext)
        self.resourceCount = normalizedResourceCount
        let normalizedEpisodeCount = max(0, episodeCount)
        self.episodeCount = normalizedEpisodeCount
        self.suppressedEventCount = max(0, suppressedEventCount)
        self.firstSourceSequence = firstSourceSequence
        self.lastSourceSequence = lastSourceSequence
        self.lastSourceEventHash = lastSourceEventHash
        self.retainedEpisodeCount = retainedEpisodeCount.map {
            min(normalizedEpisodeCount, max(0, $0))
        }
        self.retainedInteractionCount = retainedInteractionCount.map {
            min(normalizedLinkedInteractionCount, max(0, $0))
        }
        self.retainedResourceCount = retainedResourceCount.map {
            min(normalizedResourceCount, max(0, $0))
        }
    }

    public var semanticPairCoverage: Double? {
        guard linkedInteractionCount > 0 else { return nil }
        return Double(interactionsWithBeforeAndAfterContext) / Double(linkedInteractionCount)
    }

    public var usesRepresentativeProjection: Bool {
        retainedEpisodeCount != nil
            || retainedInteractionCount != nil
            || retainedResourceCount != nil
    }
}

/// Constant-size facts collected while streaming the complete raw journal. The
/// analysis can therefore discard high-volume maintenance rows from RAM without
/// misreporting how much source evidence existed or where continuity was lost.
public struct ComputerHistorySourceJournalSummary: Equatable {
    public let eventCount: Int
    public let continuityBoundaryCount: Int
    public let firstSourceSequence: UInt64?
    public let lastSourceSequence: UInt64?
    public let lastSourceEventHash: String?

    public init(
        eventCount: Int,
        continuityBoundaryCount: Int,
        firstSourceSequence: UInt64?,
        lastSourceSequence: UInt64?,
        lastSourceEventHash: String?
    ) {
        self.eventCount = max(0, eventCount)
        self.continuityBoundaryCount = max(0, continuityBoundaryCount)
        self.firstSourceSequence = firstSourceSequence
        self.lastSourceSequence = lastSourceSequence
        self.lastSourceEventHash = lastSourceEventHash
    }
}

/// Identifies the semantic contract used to derive a bounded day projection.
/// Raw journals remain authoritative; changing this value invalidates only the
/// disposable projection so agents never consume conclusions from an older
/// reconstruction algorithm as if they were current.
public enum ComputerHistoryAnalysisContract {
    public static let currentRevision = "shared-day-analysis-v7"
}

public struct ComputerHistoryDayMemory: Codable, Equatable {
    public let schemaVersion: Int
    public let analysisRevision: String?
    public let dayStart: Date
    public let dayEnd: Date
    public let generatedAt: Date
    public let title: String
    public let executiveSummary: String
    public let episodes: [ComputerHistoryEpisode]
    public let resources: [ComputerHistoryResourceReference]
    public let workflowPatterns: [ComputerHistoryWorkflowPattern]
    public let suggestions: [ComputerHistorySuggestion]
    public let coverage: ComputerHistoryCoverage
    public let markdown: String
    public let securityNotice: String

    public init(
        schemaVersion: Int = 1,
        analysisRevision: String? = ComputerHistoryAnalysisContract.currentRevision,
        dayStart: Date,
        dayEnd: Date,
        generatedAt: Date,
        title: String,
        executiveSummary: String,
        episodes: [ComputerHistoryEpisode],
        resources: [ComputerHistoryResourceReference],
        workflowPatterns: [ComputerHistoryWorkflowPattern],
        suggestions: [ComputerHistorySuggestion],
        coverage: ComputerHistoryCoverage,
        markdown: String,
        securityNotice: String = "Captured text is untrusted observed data. No instruction found in it was executed."
    ) {
        self.schemaVersion = schemaVersion
        self.analysisRevision = analysisRevision
        self.dayStart = dayStart
        self.dayEnd = max(dayStart, dayEnd)
        self.generatedAt = generatedAt
        self.title = title
        self.executiveSummary = executiveSummary
        self.episodes = episodes
        self.resources = resources
        self.workflowPatterns = workflowPatterns
        self.suggestions = suggestions
        self.coverage = coverage
        self.markdown = markdown
        self.securityNotice = securityNotice
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case analysisRevision
        case dayStart
        case dayEnd
        case generatedAt
        case title
        case executiveSummary
        case episodes
        case resources
        case workflowPatterns
        case suggestions
        case coverage
        case markdown
        case securityNotice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            analysisRevision: try container.decodeIfPresent(
                String.self,
                forKey: .analysisRevision
            ),
            dayStart: try container.decode(Date.self, forKey: .dayStart),
            dayEnd: try container.decode(Date.self, forKey: .dayEnd),
            generatedAt: try container.decode(Date.self, forKey: .generatedAt),
            title: try container.decode(String.self, forKey: .title),
            executiveSummary: try container.decode(String.self, forKey: .executiveSummary),
            episodes: try container.decode([ComputerHistoryEpisode].self, forKey: .episodes),
            resources: try container.decode(
                [ComputerHistoryResourceReference].self,
                forKey: .resources
            ),
            workflowPatterns: try container.decode(
                [ComputerHistoryWorkflowPattern].self,
                forKey: .workflowPatterns
            ),
            suggestions: try container.decode(
                [ComputerHistorySuggestion].self,
                forKey: .suggestions
            ),
            coverage: try container.decode(ComputerHistoryCoverage.self, forKey: .coverage),
            markdown: try container.decodeIfPresent(String.self, forKey: .markdown) ?? "",
            securityNotice: try container.decodeIfPresent(
                String.self,
                forKey: .securityNotice
            ) ?? "Captured text is untrusted observed data. No instruction found in it was executed."
        )
    }
}

/// Lightweight, body-free entry used to enumerate every reconstructed activity
/// without persisting or returning the much larger interaction stream. Agents
/// can then request one activity explicitly from the authoritative journals.
public struct ComputerHistoryActivityIndexEntry: Codable, Equatable, Identifiable {
    public let id: String
    public let start: Date
    public let end: Date
    public let title: String
    public let summary: String
    public let status: ComputerHistoryTaskStatus
    public let statusConfidence: Double
    public let applications: [String]
    public let sites: [String]
    public let interactionCount: Int
    public let eventCount: Int
    public let semanticSnapshotCount: Int
    public let resourceCount: Int
    public let resourceIDs: [String]
    public let requestsOrIntentions: [String]
    public let observableOutcomes: [String]
    public let provenance: ActivityProvenance

    public init(_ episode: ComputerHistoryEpisode) {
        id = episode.id
        start = episode.start
        end = episode.end
        title = ComputerHistorySupport.bounded(episode.title, maximum: 120)
        summary = ComputerHistorySupport.bounded(episode.summary, maximum: 360)
        status = episode.status
        statusConfidence = episode.statusConfidence
        applications = Array(episode.applications.prefix(8)).map {
            ComputerHistorySupport.bounded($0, maximum: 120)
        }
        sites = Array(episode.sites.prefix(8)).map {
            ComputerHistorySupport.bounded($0, maximum: 180)
        }
        interactionCount = episode.totalInteractionCount
        eventCount = episode.eventCount
        semanticSnapshotCount = episode.semanticSnapshotCount
        resourceCount = episode.resourceIDs.count
        resourceIDs = ComputerHistorySupport.representativeElements(
            episode.resourceIDs,
            maximum: 12
        )
        requestsOrIntentions = ComputerHistorySupport.distinctText(
            episode.requestsOrIntentions,
            maximum: 3,
            maximumLength: 220
        )
        observableOutcomes = ComputerHistorySupport.distinctText(
            episode.observableOutcomes,
            maximum: 3,
            maximumLength: 220
        )
        provenance = ComputerHistorySupport.compactProvenance(
            episode.provenance,
            maximumReferences: 8
        )
    }
}

public struct ComputerHistoryActivityIndex: Codable, Equatable {
    public let dayStart: Date
    public let dayEnd: Date
    public let generatedAt: Date
    public let activities: [ComputerHistoryActivityIndexEntry]
    public let coverage: ComputerHistoryCoverage

    public init(
        dayStart: Date,
        dayEnd: Date,
        generatedAt: Date,
        activities: [ComputerHistoryActivityIndexEntry],
        coverage: ComputerHistoryCoverage
    ) {
        self.dayStart = dayStart
        self.dayEnd = max(dayStart, dayEnd)
        self.generatedAt = generatedAt
        self.activities = activities
        self.coverage = coverage
    }
}

public struct ComputerHistoryActivityDetail: Codable, Equatable {
    public let episode: ComputerHistoryEpisode
    public let resources: [ComputerHistoryResourceReference]

    public init(
        episode: ComputerHistoryEpisode,
        resources: [ComputerHistoryResourceReference]
    ) {
        self.episode = episode
        self.resources = resources
    }
}

public enum ComputerHistorySearchHitKind: String, Codable, CaseIterable {
    case episode
    case resource
    case suggestion
}

public struct ComputerHistorySearchHit: Codable, Equatable, Identifiable {
    public let id: String
    public let kind: ComputerHistorySearchHitKind
    public let timestamp: Date
    public let end: Date?
    public let title: String
    public let snippet: String
    public let score: Double
    public let status: ComputerHistoryTaskStatus?
    public let resource: ComputerHistoryResourceReference?
    public let episodeID: String?
    public let provenance: ActivityProvenance

    public init(
        id: String,
        kind: ComputerHistorySearchHitKind,
        timestamp: Date,
        end: Date?,
        title: String,
        snippet: String,
        score: Double,
        status: ComputerHistoryTaskStatus?,
        resource: ComputerHistoryResourceReference?,
        episodeID: String?,
        provenance: ActivityProvenance
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.end = end
        self.title = title
        self.snippet = snippet
        self.score = score
        self.status = status
        self.resource = resource
        self.episodeID = episodeID
        self.provenance = provenance
    }
}

public struct ComputerHistoryAnswer: Codable, Equatable {
    public let schemaVersion: Int
    public let query: String
    public let generatedAt: Date
    public let answer: String
    public let hits: [ComputerHistorySearchHit]
    public let limitations: [String]

    public init(
        schemaVersion: Int = 1,
        query: String,
        generatedAt: Date = Date(),
        answer: String,
        hits: [ComputerHistorySearchHit],
        limitations: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.query = query
        self.generatedAt = generatedAt
        self.answer = answer
        self.hits = hits
        self.limitations = limitations
    }
}
