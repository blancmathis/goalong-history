import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode
    case cursor
    case openCode
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .openCode: return "OpenCode"
        case .custom: return "Other agent"
        }
    }
}

public enum AgentCaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcriptsAndLogs
    case everyFile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .transcriptsAndLogs: return "Chats & logs"
        case .everyFile: return "Every file"
        }
    }
}

public struct AgentWatchedFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var path: String
    public var provider: AgentProvider
    public var isEnabled: Bool
    public var includeSubdirectories: Bool
    public var captureMode: AgentCaptureMode
    public var isManaged: Bool
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        path: String,
        provider: AgentProvider,
        isEnabled: Bool = true,
        includeSubdirectories: Bool = true,
        captureMode: AgentCaptureMode = .transcriptsAndLogs,
        isManaged: Bool = false,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = cleanPath.isEmpty ? "" : URL(fileURLWithPath: cleanPath).standardizedFileURL.path
        self.provider = provider
        self.isEnabled = isEnabled
        self.includeSubdirectories = includeSubdirectories
        self.captureMode = captureMode
        self.isManaged = isManaged
        self.addedAt = addedAt
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

public struct AgentActivityConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var watchedFolders: [AgentWatchedFolder]
    public var scanIntervalSeconds: Double
    public var maximumFileBytes: Int64
    public var captureFullContents: Bool
    public var keepEveryVersion: Bool
    public var maximumDeltaDepth: Int

    public init(
        schemaVersion: Int = 1,
        watchedFolders: [AgentWatchedFolder] = [],
        scanIntervalSeconds: Double = 8,
        maximumFileBytes: Int64 = 256 * 1_024 * 1_024,
        captureFullContents: Bool = true,
        keepEveryVersion: Bool = true,
        maximumDeltaDepth: Int = 20
    ) {
        self.schemaVersion = schemaVersion
        self.watchedFolders = watchedFolders
        self.scanIntervalSeconds = scanIntervalSeconds
        self.maximumFileBytes = maximumFileBytes
        self.captureFullContents = captureFullContents
        self.keepEveryVersion = keepEveryVersion
        self.maximumDeltaDepth = maximumDeltaDepth
    }

    public static let `default` = AgentActivityConfiguration()

    public func validated() -> AgentActivityConfiguration {
        var output = self
        output.schemaVersion = max(schemaVersion, 1)
        output.scanIntervalSeconds = min(max(scanIntervalSeconds, 3), 300)
        output.maximumFileBytes = min(max(maximumFileBytes, 64 * 1_024), 1_024 * 1_024 * 1_024)
        output.maximumDeltaDepth = min(max(maximumDeltaDepth, 1), 100)

        var seen = Set<String>()
        output.watchedFolders = watchedFolders.compactMap { folder in
            let cleanPath = folder.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanPath.isEmpty else { return nil }
            var normalized = folder
            normalized.path = URL(fileURLWithPath: cleanPath).standardizedFileURL.path
            let key = normalized.path.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }
        return output
    }
}

public enum AgentDocumentFormat: String, Codable, Sendable {
    case json
    case jsonLines
    case markdown
    case text
    case database
    case binary
    case hookEvent
    case unknown
}

public struct AgentDocumentSummary: Codable, Equatable, Sendable {
    public var format: AgentDocumentFormat
    public var sessionID: String?
    public var title: String?
    public var excerpt: String?
    public var projectPath: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var messageCount: Int
    public var userMessageCount: Int
    public var assistantMessageCount: Int
    public var systemMessageCount: Int
    public var toolCallCount: Int
    public var errorCount: Int
    public var subagentCount: Int
    public var models: [String]
    public var tools: [String]
    public var touchedFiles: [String]
    public var commands: [String]

    public init(
        format: AgentDocumentFormat = .unknown,
        sessionID: String? = nil,
        title: String? = nil,
        excerpt: String? = nil,
        projectPath: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        messageCount: Int = 0,
        userMessageCount: Int = 0,
        assistantMessageCount: Int = 0,
        systemMessageCount: Int = 0,
        toolCallCount: Int = 0,
        errorCount: Int = 0,
        subagentCount: Int = 0,
        models: [String] = [],
        tools: [String] = [],
        touchedFiles: [String] = [],
        commands: [String] = []
    ) {
        self.format = format
        self.sessionID = sessionID
        self.title = title
        self.excerpt = excerpt
        self.projectPath = projectPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.systemMessageCount = systemMessageCount
        self.toolCallCount = toolCallCount
        self.errorCount = errorCount
        self.subagentCount = subagentCount
        self.models = models
        self.tools = tools
        self.touchedFiles = touchedFiles
        self.commands = commands
    }
}

public enum AgentCaptureStorageKind: String, Codable, Sendable {
    case full
    case appendDelta
    case digestOnly
}

public struct AgentCaptureRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sourceKey: String
    public var watchedFolderID: String
    public var watchedFolderName: String
    public var provider: AgentProvider
    public var sourcePath: String
    public var relativePath: String
    public var sourceModifiedAt: Date?
    public var capturedAt: Date
    public var byteCount: Int64
    public var storedByteCount: Int64
    public var sha256: String
    public var blobSHA256: String
    public var blobRelativePath: String?
    public var storageKind: AgentCaptureStorageKind
    public var baseCaptureID: String?
    public var previousCaptureID: String?
    public var version: Int
    public var deltaDepth: Int
    public var summary: AgentDocumentSummary
    public var previousManifestHash: String
    public var manifestHash: String

    public init(
        id: String,
        sourceKey: String,
        watchedFolderID: String,
        watchedFolderName: String,
        provider: AgentProvider,
        sourcePath: String,
        relativePath: String,
        sourceModifiedAt: Date?,
        capturedAt: Date,
        byteCount: Int64,
        storedByteCount: Int64,
        sha256: String,
        blobSHA256: String,
        blobRelativePath: String?,
        storageKind: AgentCaptureStorageKind,
        baseCaptureID: String?,
        previousCaptureID: String?,
        version: Int,
        deltaDepth: Int,
        summary: AgentDocumentSummary,
        previousManifestHash: String,
        manifestHash: String
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.watchedFolderID = watchedFolderID
        self.watchedFolderName = watchedFolderName
        self.provider = provider
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.sourceModifiedAt = sourceModifiedAt
        self.capturedAt = capturedAt
        self.byteCount = byteCount
        self.storedByteCount = storedByteCount
        self.sha256 = sha256
        self.blobSHA256 = blobSHA256
        self.blobRelativePath = blobRelativePath
        self.storageKind = storageKind
        self.baseCaptureID = baseCaptureID
        self.previousCaptureID = previousCaptureID
        self.version = version
        self.deltaDepth = deltaDepth
        self.summary = summary
        self.previousManifestHash = previousManifestHash
        self.manifestHash = manifestHash
    }

    public var searchableText: String {
        [
            provider.displayName,
            watchedFolderName,
            relativePath,
            summary.sessionID,
            summary.title,
            summary.excerpt,
            summary.projectPath,
            summary.models.joined(separator: " "),
            summary.tools.joined(separator: " "),
            summary.touchedFiles.joined(separator: " "),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }
}

public struct AgentSourceState: Codable, Equatable, Sendable {
    public var captureID: String
    public var sha256: String
    public var byteCount: Int64
    public var sourceModifiedAt: Date?
    public var version: Int
    public var deltaDepth: Int

    public init(
        captureID: String,
        sha256: String,
        byteCount: Int64,
        sourceModifiedAt: Date?,
        version: Int,
        deltaDepth: Int
    ) {
        self.captureID = captureID
        self.sha256 = sha256
        self.byteCount = byteCount
        self.sourceModifiedAt = sourceModifiedAt
        self.version = version
        self.deltaDepth = deltaDepth
    }
}

public struct AgentActivityState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var latestBySource: [String: AgentSourceState]
    public var lastManifestHash: String
    public var updatedAt: Date
    public var integrityFaultDetected: Bool

    public init(
        schemaVersion: Int = 2,
        latestBySource: [String: AgentSourceState] = [:],
        lastManifestHash: String = "",
        updatedAt: Date = Date(),
        integrityFaultDetected: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.latestBySource = latestBySource
        self.lastManifestHash = lastManifestHash
        self.updatedAt = updatedAt
        self.integrityFaultDetected = integrityFaultDetected
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case latestBySource
        case lastManifestHash
        case updatedAt
        case integrityFaultDetected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        latestBySource = try container.decodeIfPresent([String: AgentSourceState].self, forKey: .latestBySource) ?? [:]
        lastManifestHash = try container.decodeIfPresent(String.self, forKey: .lastManifestHash) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        integrityFaultDetected = try container.decodeIfPresent(Bool.self, forKey: .integrityFaultDetected) ?? false
    }
}

public struct AgentActivityOverview: Equatable, Sendable {
    public var day: Date
    public var captures: [AgentCaptureRecord]
    public var sessionCount: Int
    public var messageCount: Int
    public var toolCallCount: Int
    public var errorCount: Int
    public var capturedBytes: Int64
    public var storedBytes: Int64
    public var lastCaptureAt: Date?

    public init(
        day: Date,
        captures: [AgentCaptureRecord] = [],
        sessionCount: Int = 0,
        messageCount: Int = 0,
        toolCallCount: Int = 0,
        errorCount: Int = 0,
        capturedBytes: Int64 = 0,
        storedBytes: Int64 = 0,
        lastCaptureAt: Date? = nil
    ) {
        self.day = day
        self.captures = captures
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.errorCount = errorCount
        self.capturedBytes = capturedBytes
        self.storedBytes = storedBytes
        self.lastCaptureAt = lastCaptureAt
    }
}

public struct AgentScanResult: Equatable, Sendable {
    public var scannedFileCount: Int
    public var newCaptureCount: Int
    public var skippedFileCount: Int
    public var failures: [String]
    public var captures: [AgentCaptureRecord]

    public init(
        scannedFileCount: Int = 0,
        newCaptureCount: Int = 0,
        skippedFileCount: Int = 0,
        failures: [String] = [],
        captures: [AgentCaptureRecord] = []
    ) {
        self.scannedFileCount = scannedFileCount
        self.newCaptureCount = newCaptureCount
        self.skippedFileCount = skippedFileCount
        self.failures = failures
        self.captures = captures
    }
}

public struct AgentHookEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var provider: AgentProvider
    public var eventName: String
    public var capturedAt: Date
    public var processIdentifier: Int32
    public var payload: Data

    public init(
        schemaVersion: Int = 1,
        id: String = UUID().uuidString,
        provider: AgentProvider,
        eventName: String,
        capturedAt: Date = Date(),
        processIdentifier: Int32,
        payload: Data
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.provider = provider
        self.eventName = eventName
        self.capturedAt = capturedAt
        self.processIdentifier = processIdentifier
        self.payload = payload
    }
}

public enum AgentIntegrationKind: String, CaseIterable, Identifiable, Sendable {
    case codexHooks
    case claudeCodeHooks
    case cursorHooks
    case openCodePlugin

    public var id: String { rawValue }

    public var provider: AgentProvider {
        switch self {
        case .codexHooks: return .codex
        case .claudeCodeHooks: return .claudeCode
        case .cursorHooks: return .cursor
        case .openCodePlugin: return .openCode
        }
    }

    public var displayName: String {
        switch self {
        case .codexHooks: return "Codex hooks"
        case .claudeCodeHooks: return "Claude Code hooks"
        case .cursorHooks: return "Cursor hooks"
        case .openCodePlugin: return "OpenCode plugin"
        }
    }
}
