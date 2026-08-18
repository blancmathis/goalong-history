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
}

public struct ActivityAnalysisOptions: Codable, Equatable {
    public var maximumFocusBlocks: Int
    public var maximumSites: Int
    public var maximumPagesPerSite: Int
    public var maximumRequests: Int
    public var maximumContextHighlights: Int
    public var agentTokenBudget: Int

    public init(
        maximumFocusBlocks: Int = 24,
        maximumSites: Int = 12,
        maximumPagesPerSite: Int = 5,
        maximumRequests: Int = 20,
        maximumContextHighlights: Int = 16,
        agentTokenBudget: Int = 1_600
    ) {
        self.maximumFocusBlocks = max(4, min(maximumFocusBlocks, 96))
        self.maximumSites = max(4, min(maximumSites, 50))
        self.maximumPagesPerSite = max(2, min(maximumPagesPerSite, 20))
        self.maximumRequests = max(4, min(maximumRequests, 80))
        self.maximumContextHighlights = max(4, min(maximumContextHighlights, 80))
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

public struct ActivityPageSummary: Codable, Equatable, Identifiable {
    public let title: String
    public let URL: String?
    public let activeSeconds: Int
    public let firstSeen: Date
    public let lastSeen: Date

    public init(title: String, URL: String?, activeSeconds: Int, firstSeen: Date, lastSeen: Date) {
        self.title = title
        self.URL = URL
        self.activeSeconds = activeSeconds
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    public var id: String { URL ?? title }
}

public struct ActivitySiteSummary: Codable, Equatable, Identifiable {
    public let host: String
    public let activeSeconds: Int
    public let visitCount: Int
    public let pageCount: Int
    public let pages: [ActivityPageSummary]

    public init(
        host: String,
        activeSeconds: Int,
        visitCount: Int,
        pageCount: Int,
        pages: [ActivityPageSummary]
    ) {
        self.host = host
        self.activeSeconds = activeSeconds
        self.visitCount = visitCount
        self.pageCount = pageCount
        self.pages = pages
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
        schemaVersion: Int = 1,
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
    public static func clean(_ raw: String?, maximumLength: Int = 2_400) -> String? {
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
        let limit = max(64, min(maximumLength, 20_000))
        if value.count > limit {
            value = String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
