import Foundation

/// Metadata names used by the optional, local-only rich-context collector.
/// They intentionally live in the existing event metadata map so that the captured
/// context remains covered by the normal event hash and minute seal.
public enum ActivitySemanticMetadata {
    public static let version = "analysis.semantic_version"
    public static let text = "analysis.semantic_text"
    public static let source = "analysis.semantic_source"
    public static let redacted = "analysis.semantic_redacted"
    public static let truncated = "analysis.semantic_truncated"
    public static let fingerprint = "analysis.semantic_fingerprint"
    public static let characterCount = "analysis.semantic_character_count"
}

public struct ActivityAnalysisOptions: Codable, Equatable {
    public var maximumFocusBlocks: Int
    public var maximumSites: Int
    public var maximumPagesPerSite: Int
    public var maximumRequests: Int
    public var maximumContextHighlights: Int
    public var maximumWebInteractionsPerSite: Int
    public var maximumWebInteractionsPerPage: Int
    public var maximumRememberedContextPerSite: Int
    public var maximumRememberedContextPerPage: Int
    public var agentTokenBudget: Int

    public init(
        maximumFocusBlocks: Int = 24,
        maximumSites: Int = 5_000,
        maximumPagesPerSite: Int = 2_000,
        maximumRequests: Int = 40,
        maximumContextHighlights: Int = 40,
        maximumWebInteractionsPerSite: Int = 5_000,
        maximumWebInteractionsPerPage: Int = 2_000,
        maximumRememberedContextPerSite: Int = 500,
        maximumRememberedContextPerPage: Int = 250,
        agentTokenBudget: Int = 1_600
    ) {
        self.maximumFocusBlocks = max(4, min(maximumFocusBlocks, 96))
        self.maximumSites = max(4, min(maximumSites, 20_000))
        self.maximumPagesPerSite = max(2, min(maximumPagesPerSite, 10_000))
        self.maximumRequests = max(4, min(maximumRequests, 200))
        self.maximumContextHighlights = max(4, min(maximumContextHighlights, 200))
        self.maximumWebInteractionsPerSite = max(8, min(maximumWebInteractionsPerSite, 20_000))
        self.maximumWebInteractionsPerPage = max(4, min(maximumWebInteractionsPerPage, 10_000))
        self.maximumRememberedContextPerSite = max(4, min(maximumRememberedContextPerSite, 2_000))
        self.maximumRememberedContextPerPage = max(2, min(maximumRememberedContextPerPage, 1_000))
        self.agentTokenBudget = max(400, min(agentTokenBudget, 12_000))
    }

    public static let `default` = ActivityAnalysisOptions()
}

public struct ActivityFocusBlock: Codable, Equatable, Identifiable {
    public let id: String
    public let start: Date
    public let end: Date
    public let activeSeconds: Int
    public let title: String
    public let applications: [String]
    public let hosts: [String]
    public let pageTitles: [String]
    public let URLs: [String]
    public let category: String?
    public let isWork: Bool?
    public let eventCount: Int
    public let inputEventCount: Int
    public let contextSnippets: [String]
    public let requestSnippets: [String]

    public init(
        id: String,
        start: Date,
        end: Date,
        activeSeconds: Int,
        title: String,
        applications: [String],
        hosts: [String],
        pageTitles: [String],
        URLs: [String],
        category: String?,
        isWork: Bool?,
        eventCount: Int,
        inputEventCount: Int,
        contextSnippets: [String],
        requestSnippets: [String]
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.activeSeconds = activeSeconds
        self.title = title
        self.applications = applications
        self.hosts = hosts
        self.pageTitles = pageTitles
        self.URLs = URLs
        self.category = category
        self.isWork = isWork
        self.eventCount = eventCount
        self.inputEventCount = inputEventCount
        self.contextSnippets = contextSnippets
        self.requestSnippets = requestSnippets
    }
}

public enum ActivityWebInteractionKind: String, Codable, CaseIterable, Sendable {
    case click
    case typing
    case scroll
    case shortcut

    public var displayName: String {
        switch self {
        case .click: return "Click"
        case .typing: return "Typing activity"
        case .scroll: return "Scroll"
        case .shortcut: return "Shortcut"
        }
    }
}

public struct ActivityWebInteractionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ActivityWebInteractionKind
    public let label: String
    public let role: String?
    public let pageTitle: String?
    public let URL: String?
    public let count: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let detail: String?

    public init(
        id: String,
        kind: ActivityWebInteractionKind,
        label: String,
        role: String?,
        pageTitle: String?,
        URL: String?,
        count: Int,
        firstSeen: Date,
        lastSeen: Date,
        detail: String?
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.role = role
        self.pageTitle = pageTitle
        self.URL = URL
        self.count = max(1, count)
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.detail = detail
    }
}

public struct ActivityPageSummary: Codable, Equatable, Identifiable {
    public let title: String
    public let URL: String?
    public let activeSeconds: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let eventCount: Int
    public let clickCount: Int
    public let typingBurstCount: Int
    public let scrollBurstCount: Int
    public let shortcutCount: Int
    public let semanticSnapshotCount: Int
    public let interactions: [ActivityWebInteractionSummary]
    public let rememberedContext: [String]
    public let interactionsTruncated: Bool
    public let rememberedContextTruncated: Bool

    public init(
        title: String,
        URL: String?,
        activeSeconds: Int,
        firstSeen: Date,
        lastSeen: Date,
        eventCount: Int,
        clickCount: Int,
        typingBurstCount: Int,
        scrollBurstCount: Int,
        shortcutCount: Int,
        semanticSnapshotCount: Int,
        interactions: [ActivityWebInteractionSummary],
        rememberedContext: [String],
        interactionsTruncated: Bool,
        rememberedContextTruncated: Bool
    ) {
        self.title = title
        self.URL = URL
        self.activeSeconds = activeSeconds
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.eventCount = eventCount
        self.clickCount = clickCount
        self.typingBurstCount = typingBurstCount
        self.scrollBurstCount = scrollBurstCount
        self.shortcutCount = shortcutCount
        self.semanticSnapshotCount = semanticSnapshotCount
        self.interactions = interactions
        self.rememberedContext = rememberedContext
        self.interactionsTruncated = interactionsTruncated
        self.rememberedContextTruncated = rememberedContextTruncated
    }

    public var id: String { URL ?? title }
}

public struct ActivitySiteSummary: Codable, Equatable, Identifiable {
    public let host: String
    public let activeSeconds: Int
    public let visitCount: Int
    public let pageCount: Int
    public let pages: [ActivityPageSummary]
    public let sourceApplications: [String]
    public let clickCount: Int
    public let typingBurstCount: Int
    public let scrollBurstCount: Int
    public let shortcutCount: Int
    public let semanticSnapshotCount: Int
    public let interactions: [ActivityWebInteractionSummary]
    public let rememberedContext: [String]
    public let pagesTruncated: Bool
    public let interactionsTruncated: Bool
    public let rememberedContextTruncated: Bool

    public init(
        host: String,
        activeSeconds: Int,
        visitCount: Int,
        pageCount: Int,
        pages: [ActivityPageSummary],
        sourceApplications: [String],
        clickCount: Int,
        typingBurstCount: Int,
        scrollBurstCount: Int,
        shortcutCount: Int,
        semanticSnapshotCount: Int,
        interactions: [ActivityWebInteractionSummary],
        rememberedContext: [String],
        pagesTruncated: Bool,
        interactionsTruncated: Bool,
        rememberedContextTruncated: Bool
    ) {
        self.host = host
        self.activeSeconds = activeSeconds
        self.visitCount = visitCount
        self.pageCount = pageCount
        self.pages = pages
        self.sourceApplications = sourceApplications
        self.clickCount = clickCount
        self.typingBurstCount = typingBurstCount
        self.scrollBurstCount = scrollBurstCount
        self.shortcutCount = shortcutCount
        self.semanticSnapshotCount = semanticSnapshotCount
        self.interactions = interactions
        self.rememberedContext = rememberedContext
        self.pagesTruncated = pagesTruncated
        self.interactionsTruncated = interactionsTruncated
        self.rememberedContextTruncated = rememberedContextTruncated
    }

    public var id: String { host }
}

public struct ActivityApplicationSummary: Codable, Equatable, Identifiable {
    public let name: String
    public let bundleIdentifier: String?
    public let activeSeconds: Int
    public let focusBlockCount: Int

    public init(name: String, bundleIdentifier: String?, activeSeconds: Int, focusBlockCount: Int) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.activeSeconds = activeSeconds
        self.focusBlockCount = focusBlockCount
    }

    public var id: String { bundleIdentifier ?? "name:\(name)" }
}

public struct ActivityRequestSummary: Codable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let occurrences: Int
    public let application: String?
    public let host: String?
    public let confidence: Double

    public init(
        id: String,
        text: String,
        firstSeen: Date,
        lastSeen: Date,
        occurrences: Int,
        application: String?,
        host: String?,
        confidence: Double
    ) {
        self.id = id
        self.text = text
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.occurrences = occurrences
        self.application = application
        self.host = host
        self.confidence = confidence
    }
}

public struct ActivityContextHighlight: Codable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let firstSeen: Date
    public let application: String?
    public let host: String?

    public init(id: String, text: String, firstSeen: Date, application: String?, host: String?) {
        self.id = id
        self.text = text
        self.firstSeen = firstSeen
        self.application = application
        self.host = host
    }
}

public struct ActivityAnalysisCoverage: Codable, Equatable {
    public let sourceEventCount: Int
    public let representativeMinuteCount: Int
    public let privateMinuteCount: Int
    public let semanticSnapshotCount: Int
    public let semanticContextEnabledInData: Bool
    public let sourceFirstSequence: UInt64?
    public let sourceLastSequence: UInt64?
    public let sourceLastEventHash: String?

    public init(
        sourceEventCount: Int,
        representativeMinuteCount: Int,
        privateMinuteCount: Int,
        semanticSnapshotCount: Int,
        semanticContextEnabledInData: Bool,
        sourceFirstSequence: UInt64?,
        sourceLastSequence: UInt64?,
        sourceLastEventHash: String?
    ) {
        self.sourceEventCount = sourceEventCount
        self.representativeMinuteCount = representativeMinuteCount
        self.privateMinuteCount = privateMinuteCount
        self.semanticSnapshotCount = semanticSnapshotCount
        self.semanticContextEnabledInData = semanticContextEnabledInData
        self.sourceFirstSequence = sourceFirstSequence
        self.sourceLastSequence = sourceLastSequence
        self.sourceLastEventHash = sourceLastEventHash
    }
}

public struct ActivityDayAnalysis: Codable, Equatable {
    public let schemaVersion: Int
    public let dayStart: Date
    public let dayEnd: Date
    public let generatedAt: Date
    public let headline: String
    public let activeSeconds: Int
    public let workSeconds: Int
    public let focusBlocks: [ActivityFocusBlock]
    public let sites: [ActivitySiteSummary]
    public let applications: [ActivityApplicationSummary]
    public let requests: [ActivityRequestSummary]
    public let contextHighlights: [ActivityContextHighlight]
    public let coverage: ActivityAnalysisCoverage
    public let agentMarkdown: String
    public let estimatedAgentTokens: Int

    public init(
        schemaVersion: Int = 2,
        dayStart: Date,
        dayEnd: Date,
        generatedAt: Date,
        headline: String,
        activeSeconds: Int,
        workSeconds: Int,
        focusBlocks: [ActivityFocusBlock],
        sites: [ActivitySiteSummary],
        applications: [ActivityApplicationSummary],
        requests: [ActivityRequestSummary],
        contextHighlights: [ActivityContextHighlight],
        coverage: ActivityAnalysisCoverage,
        agentMarkdown: String,
        estimatedAgentTokens: Int
    ) {
        self.schemaVersion = schemaVersion
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.generatedAt = generatedAt
        self.headline = headline
        self.activeSeconds = activeSeconds
        self.workSeconds = workSeconds
        self.focusBlocks = focusBlocks
        self.sites = sites
        self.applications = applications
        self.requests = requests
        self.contextHighlights = contextHighlights
        self.coverage = coverage
        self.agentMarkdown = agentMarkdown
        self.estimatedAgentTokens = estimatedAgentTokens
    }
}

/// Conservative local redaction for optional rich context. This does not try to
/// infer every possible secret; it removes common credentials before persistence.
public enum ActivitySemanticTextSanitizer {
    public static func clean(_ raw: String?, maximumLength: Int = 6_000) -> String? {
        guard var value = raw else { return nil }
        value = value.replacingOccurrences(of: "\u{0000}", with: "")
        value = value.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\r\\n?", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        let credentialPatterns: [(String, String)] = [
            (#"(?i)\b(password|passwd|secret|api[ _-]?key|access[ _-]?token|authorization)\s*[:=]\s*[^\s,;]+"#, "$1=[REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]{16,}\b"#, "[REDACTED_KEY]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, "[REDACTED_TOKEN]"),
            (#"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "[REDACTED_TOKEN]"),
            (#"\b(?:\d[ -]*?){13,19}\b"#, "[REDACTED_NUMBER]"),
        ]
        for (pattern, replacement) in credentialPatterns {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let limit = max(64, min(maximumLength, 40_000))
        if value.count > limit {
            value = String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
