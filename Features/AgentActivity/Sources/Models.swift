import Foundation
import LocalHistoryCore

public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode
    case cursor
    case openCode
    case gemini
    case copilot
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .openCode: return "OpenCode"
        case .gemini: return "Gemini CLI"
        case .copilot: return "GitHub Copilot"
        case .custom: return "Other agent"
        }
    }
}

/// Opaque, deterministic identity for one provider root. It is stable across
/// relaunches, distinct for case-distinct paths, and contains no source path.
public enum AgentFolderIdentifier {
    private static let sourcePrefix = "agent-source-"
    private static let legacyPrefix = "folder-sha256-"

    public static func persisted(provider: AgentProvider, path: String) -> String {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        return sourcePrefix
            + String(SHA256Digest.hashHex("\(provider.rawValue)\u{0}\(canonical)").prefix(24))
    }

    static func opaqueLegacy(_ value: String) -> String {
        legacyPrefix + SHA256Digest.hashHex(value)
    }

    public static func isPersisted(_ value: String) -> Bool {
        if value.hasPrefix(sourcePrefix) {
            let digest = value.dropFirst(sourcePrefix.count)
            return digest.count == 24 && digest.allSatisfy(\.isHexDigit)
        }
        if value.hasPrefix(legacyPrefix) {
            let digest = value.dropFirst(legacyPrefix.count)
            return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
        }
        return false
    }
}

public enum AgentCaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcriptsAndLogs
    case everyFile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .transcriptsAndLogs: return "Conversations & logs"
        case .everyFile: return "Every supported file"
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
        self.displayName = displayName
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = cleanPath.isEmpty ? "" : URL(fileURLWithPath: cleanPath).standardizedFileURL.path
        self.provider = provider
        _ = id
        self.id = AgentFolderIdentifier.persisted(provider: provider, path: self.path)
        self.isEnabled = isEnabled
        self.includeSubdirectories = includeSubdirectories
        self.captureMode = captureMode
        self.isManaged = isManaged
        self.addedAt = addedAt
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Records that a user explicitly stopped one of Goalong's default discoveries.
/// The identifier is an opaque provider/path digest; no path or conversation content is retained.
public struct AgentDiscoveryTombstone: Codable, Equatable, Sendable {
    public var sourceID: String
    public var suppressedAt: Date

    public init(sourceID: String, suppressedAt: Date = Date()) {
        self.sourceID = sourceID.lowercased()
        self.suppressedAt = suppressedAt
    }

    public static func isValidSourceID(_ value: String) -> Bool {
        let prefix = "agent-source-"
        let normalized = value.lowercased()
        guard normalized == value, normalized.hasPrefix(prefix) else { return false }
        let digest = normalized.dropFirst(prefix.count)
        return digest.count == 24 && digest.allSatisfy(\.isHexDigit)
    }
}

public struct AgentActivityConfiguration: Codable, Equatable, Sendable {
    public static let maximumWatchedFolders = 512
    public static let maximumDiscoveryTombstones = 256

    public var schemaVersion: Int
    public var watchedFolders: [AgentWatchedFolder]
    public var discoveryTombstones: [AgentDiscoveryTombstone]
    public var scanIntervalSeconds: Double
    public var fullDiscoveryIntervalSeconds: Double
    public var maximumFileBytes: Int64
    public var maximumIndexEntries: Int

    public init(
        schemaVersion: Int = 2,
        watchedFolders: [AgentWatchedFolder] = [],
        discoveryTombstones: [AgentDiscoveryTombstone] = [],
        scanIntervalSeconds: Double = 30,
        fullDiscoveryIntervalSeconds: Double = 24 * 60 * 60,
        maximumFileBytes: Int64 = 256 * 1_024 * 1_024,
        maximumIndexEntries: Int = 10_000
    ) {
        self.schemaVersion = schemaVersion
        self.watchedFolders = watchedFolders
        self.discoveryTombstones = discoveryTombstones
        self.scanIntervalSeconds = scanIntervalSeconds
        self.fullDiscoveryIntervalSeconds = fullDiscoveryIntervalSeconds
        self.maximumFileBytes = maximumFileBytes
        self.maximumIndexEntries = maximumIndexEntries
    }

    public static let `default` = AgentActivityConfiguration()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case watchedFolders
        case discoveryTombstones
        case scanIntervalSeconds
        case fullDiscoveryIntervalSeconds
        case maximumFileBytes
        case maximumIndexEntries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        watchedFolders = try container.decodeIfPresent([AgentWatchedFolder].self, forKey: .watchedFolders) ?? []
        discoveryTombstones =
            try container.decodeIfPresent([AgentDiscoveryTombstone].self, forKey: .discoveryTombstones) ?? []
        scanIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .scanIntervalSeconds) ?? 30
        fullDiscoveryIntervalSeconds =
            try container.decodeIfPresent(Double.self, forKey: .fullDiscoveryIntervalSeconds) ?? 24 * 60 * 60
        maximumFileBytes =
            try container.decodeIfPresent(Int64.self, forKey: .maximumFileBytes) ?? 256 * 1_024 * 1_024
        maximumIndexEntries = try container.decodeIfPresent(Int.self, forKey: .maximumIndexEntries) ?? 10_000
    }

    public func validated() -> AgentActivityConfiguration {
        var output = self
        output.schemaVersion = max(schemaVersion, 2)
        output.scanIntervalSeconds = min(max(scanIntervalSeconds, 30), 300)
        output.fullDiscoveryIntervalSeconds = 24 * 60 * 60
        output.maximumFileBytes = min(max(maximumFileBytes, 64 * 1_024), 512 * 1_024 * 1_024)
        output.maximumIndexEntries = min(max(maximumIndexEntries, 100), 50_000)

        var seen = Set<String>()
        output.watchedFolders = watchedFolders.prefix(Self.maximumWatchedFolders).compactMap { folder in
            let cleanPath = folder.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanPath.isEmpty else { return nil }
            var normalized = folder
            normalized.path = URL(fileURLWithPath: cleanPath).standardizedFileURL.path
            normalized.id = AgentFolderIdentifier.persisted(
                provider: normalized.provider,
                path: normalized.path
            )
            if normalized.isManaged {
                let components = normalized.url.pathComponents.map { $0.lowercased() }
                guard !components.contains("hook-inbox") else { return nil }
            }
            if normalized.provider == .custom {
                let rootKey = normalized.url.lastPathComponent.lowercased().unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) }
                    .map(String.init)
                    .joined()
                let unsafeCustomRoots: Set<String> = [
                    "ssh", "aws", "gnupg", "keychain", "keychains", "codex", "claude",
                    "gemini", "opencode", "githubcopilotchat",
                ]
                guard !unsafeCustomRoots.contains(rootKey) else { return nil }
            }
            let supportsCaseSensitiveNames = try? normalized.url.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ).volumeSupportsCaseSensitiveNames
            let key = supportsCaseSensitiveNames == false ? normalized.path.lowercased() : normalized.path
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }

        var tombstonesByID: [String: AgentDiscoveryTombstone] = [:]
        for tombstone in discoveryTombstones {
            let sourceID = tombstone.sourceID.lowercased()
            guard AgentDiscoveryTombstone.isValidSourceID(sourceID) else { continue }
            let normalized = AgentDiscoveryTombstone(sourceID: sourceID, suppressedAt: tombstone.suppressedAt)
            if let existing = tombstonesByID[sourceID], existing.suppressedAt > normalized.suppressedAt {
                continue
            }
            tombstonesByID[sourceID] = normalized
        }
        output.discoveryTombstones = Array(tombstonesByID.values)
            .sorted {
                if $0.suppressedAt != $1.suppressedAt { return $0.suppressedAt > $1.suppressedAt }
                return $0.sourceID < $1.sourceID
            }
            .prefix(Self.maximumDiscoveryTombstones)
            .map { $0 }
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
    case unknown
}

/// Byte-aware bounds used at public/model boundaries. Character-count prefixes can retain up
/// to four times their advertised size in UTF-8 and are therefore unsuitable for memory or
/// persistence limits.
enum AgentUTF8Bound {
    static func string(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        let ellipsis = "…"
        let ellipsisBytes = ellipsis.utf8.count
        guard maximumBytes > ellipsisBytes else { return "" }
        var prefix = Array(value.utf8.prefix(maximumBytes - ellipsisBytes))
        while !prefix.isEmpty, String(bytes: prefix, encoding: .utf8) == nil {
            prefix.removeLast()
        }
        return (String(bytes: prefix, encoding: .utf8) ?? "") + ellipsis
    }

    static func optional(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        return string(value, maximumBytes: maximumBytes)
    }

    static func array(_ values: [String], maximumCount: Int, maximumElementBytes: Int) -> [String] {
        values.prefix(maximumCount).map { string($0, maximumBytes: maximumElementBytes) }
    }
}

/// One user-visible conversation item retained only while Goalong is assembling an analysis.
/// Provider prompts, reasoning, tool traffic, progress commentary, and compaction payloads are
/// deliberately not representable by this type.
public struct AgentVisibleMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case assistantFinal
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// A transient analysis assembled from the provider's original storage.
/// It is deliberately never encoded into Goalong History's Agent Activity index.
public struct AgentDocumentSummary: Equatable, Sendable {
    static let maximumSessionIDBytes = 256
    static let maximumTitleBytes = 512
    static let maximumExcerptBytes = 2_048
    static let maximumProjectPathBytes = 2_048
    static let maximumModelCount = 20
    static let maximumToolCount = 80
    static let maximumTouchedFileCount = 160
    static let maximumCommandCount = 80
    static let maximumIdentifierBytes = 256
    static let maximumTouchedFileBytes = 1_024
    static let maximumCommandBytes = 2_048
    static let maximumVisibleMessageCount = 256
    static let maximumVisibleMessageBytes = 8 * 1_024
    static let maximumVisibleConversationBytes = 64 * 1_024

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
    public var visibleMessages: [AgentVisibleMessage]

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
        commands: [String] = [],
        visibleMessages: [AgentVisibleMessage] = []
    ) {
        self.format = format
        self.sessionID = AgentUTF8Bound.optional(sessionID, maximumBytes: Self.maximumSessionIDBytes)
        self.title = AgentUTF8Bound.optional(title, maximumBytes: Self.maximumTitleBytes)
        self.excerpt = AgentUTF8Bound.optional(excerpt, maximumBytes: Self.maximumExcerptBytes)
        self.projectPath = AgentUTF8Bound.optional(projectPath, maximumBytes: Self.maximumProjectPathBytes)
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.systemMessageCount = systemMessageCount
        self.toolCallCount = toolCallCount
        self.errorCount = errorCount
        self.subagentCount = subagentCount
        self.models = AgentUTF8Bound.array(
            models,
            maximumCount: Self.maximumModelCount,
            maximumElementBytes: Self.maximumIdentifierBytes
        )
        self.tools = AgentUTF8Bound.array(
            tools,
            maximumCount: Self.maximumToolCount,
            maximumElementBytes: Self.maximumIdentifierBytes
        )
        self.touchedFiles = AgentUTF8Bound.array(
            touchedFiles,
            maximumCount: Self.maximumTouchedFileCount,
            maximumElementBytes: Self.maximumTouchedFileBytes
        )
        self.commands = AgentUTF8Bound.array(
            commands,
            maximumCount: Self.maximumCommandCount,
            maximumElementBytes: Self.maximumCommandBytes
        )
        self.visibleMessages = Self.boundedVisibleMessages(visibleMessages)
    }

    /// Reapplies all limits after public mutable properties may have been changed by a caller.
    func boundedForTransientCache() -> AgentDocumentSummary {
        AgentDocumentSummary(
            format: format,
            sessionID: sessionID,
            title: title,
            excerpt: excerpt,
            projectPath: projectPath,
            startedAt: startedAt,
            endedAt: endedAt,
            messageCount: max(messageCount, 0),
            userMessageCount: max(userMessageCount, 0),
            assistantMessageCount: max(assistantMessageCount, 0),
            systemMessageCount: max(systemMessageCount, 0),
            toolCallCount: max(toolCallCount, 0),
            errorCount: max(errorCount, 0),
            subagentCount: max(subagentCount, 0),
            models: models,
            tools: tools,
            touchedFiles: touchedFiles,
            commands: commands,
            visibleMessages: visibleMessages
        )
    }

    private static func boundedVisibleMessages(
        _ values: [AgentVisibleMessage]
    ) -> [AgentVisibleMessage] {
        var bounded: [AgentVisibleMessage] = []
        bounded.reserveCapacity(min(values.count, maximumVisibleMessageCount))
        var retainedBytes = 0
        for value in values {
            let trimmed = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let text = AgentUTF8Bound.string(trimmed, maximumBytes: maximumVisibleMessageBytes)
            let byteCount = text.utf8.count
            guard byteCount > 0 else { continue }
            bounded.append(AgentVisibleMessage(role: value.role, text: text))
            retainedBytes += byteCount
            while bounded.count > maximumVisibleMessageCount
                || retainedBytes > maximumVisibleConversationBytes
            {
                let removalIndex = bounded.count > 2 ? bounded.count / 2 : 0
                retainedBytes -= bounded.remove(at: removalIndex).text.utf8.count
            }
        }
        return bounded
    }
}

public enum AgentSourceKind: String, Codable, Sendable {
    case file
    case sqliteConversation
}

public enum AgentSourceAvailability: String, Codable, Sendable {
    case available
    case missing
    case inaccessible

    public var displayName: String {
        switch self {
        case .available: return "Available"
        case .missing: return "Missing"
        case .inaccessible: return "Inaccessible"
        }
    }
}

/// Folder-level reachability is persisted separately from conversation metadata. A temporary
/// permission failure must be visible without rewriting every child conversation as unavailable.
public struct AgentFolderRootStatus: Codable, Equatable, Sendable {
    public var availability: AgentSourceAvailability
    public var changedAt: Date

    public init(availability: AgentSourceAvailability, changedAt: Date) {
        self.availability = availability
        self.changedAt = changedAt
    }
}

/// Persisted availability details are codes, never provider/error text. This prevents an error
/// carrying a transcript fragment or SQL value from becoming a second copy in `index.json`.
public enum AgentSourceStatusCode: String, Codable, CaseIterable, Sendable {
    case sourceMissing = "source_missing"
    case sourceInaccessible = "source_inaccessible"

    static func persistedValue(for availability: AgentSourceAvailability) -> String? {
        switch availability {
        case .available: return nil
        case .missing: return sourceMissing.rawValue
        case .inaccessible: return sourceInaccessible.rawValue
        }
    }

    static func isPersistedValue(_ value: String?) -> Bool {
        guard let value else { return true }
        return Self(rawValue: value) != nil
    }
}

public struct AgentSourceReference: Codable, Equatable, Sendable {
    static let maximumPathBytes = 4_096
    static let maximumLocatorBytes = 256

    public var kind: AgentSourceKind
    public var path: String
    public var locator: String?

    public init(kind: AgentSourceKind, path: String, locator: String? = nil) {
        self.kind = kind
        self.path = Self.persistablePath(path)
        self.locator = kind == .sqliteConversation ? Self.persistableLocator(locator) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case locator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(AgentSourceKind.self, forKey: .kind),
            path: try container.decode(String.self, forKey: .path),
            locator: try container.decodeIfPresent(String.self, forKey: .locator)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(locator, forKey: .locator)
    }

    private static func persistablePath(_ rawValue: String) -> String {
        let rawHasUnsafeControl = rawValue.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard rawValue.hasPrefix("/"), !rawHasUnsafeControl,
            rawValue.utf8.count <= maximumPathBytes
        else {
            return "/invalid-agent-source/source-sha256-" + SHA256Digest.hashHex(rawValue)
        }
        let standardized = URL(fileURLWithPath: rawValue).standardizedFileURL.path
        let hasUnsafeControl = standardized.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard standardized.hasPrefix("/"), !hasUnsafeControl,
            standardized.utf8.count <= maximumPathBytes
        else {
            return "/invalid-agent-source/source-sha256-" + SHA256Digest.hashHex(rawValue)
        }
        return standardized
    }

    private static func persistableLocator(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumLocatorBytes,
            value.unicodeScalars.allSatisfy({ scalar in
                guard scalar.isASCII else { return false }
                return CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_" || scalar == "-" || scalar == "." || scalar == ":"
            })
        else { return nil }
        return value
    }
}

/// Stable conversation identifiers are persisted only as opaque digests. Provider values can
/// contain titles, prompts or other free-form text, so even a mislabeled identifier must never
/// become a transcript fragment in Goalong History's index.
public enum AgentStableConversationIdentifier {
    private static let legacyPrefix = "sid-sha256-"
    private static let folderScopedPrefix = "sid3-sha256-"

    public static func persisted(
        provider: AgentProvider,
        rawValue: String?,
        reference: AgentSourceReference
    ) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isPersisted(trimmed) { return trimmed.lowercased() }
        let source =
            trimmed.isEmpty
            ? "\(reference.kind.rawValue)\u{0}\(reference.path)\u{0}\(reference.locator ?? "")"
            : trimmed
        return legacyPrefix + SHA256Digest.hashHex("\(provider.rawValue)\u{0}\(source)")
    }

    public static func persisted(
        provider: AgentProvider,
        folderID: String,
        rawValue: String?,
        reference: AgentSourceReference
    ) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.hasPrefix(folderScopedPrefix), isPersisted(trimmed) {
            return trimmed.lowercased()
        }
        let legacy = persisted(
            provider: provider,
            rawValue: trimmed,
            reference: reference
        )
        return folderScopedPrefix
            + SHA256Digest.hashHex("\(provider.rawValue)\u{0}\(folderID)\u{0}\(legacy)")
    }

    public static func entryID(provider: AgentProvider, persistedIdentifier: String) -> String {
        "agent-conversation-"
            + String(SHA256Digest.hashHex("\(provider.rawValue)\u{0}\(persistedIdentifier)").prefix(32))
    }

    public static func isPersisted(_ value: String) -> Bool {
        let prefix: String
        if value.hasPrefix(folderScopedPrefix) {
            prefix = folderScopedPrefix
        } else if value.hasPrefix(legacyPrefix) {
            prefix = legacyPrefix
        } else {
            return false
        }
        let digest = value.dropFirst(prefix.count)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }
}

/// The complete persisted contract for one conversation. It contains only source metadata.
public struct AgentSourceIndexEntry: Codable, Identifiable, Equatable, Sendable {
    static let maximumFolderIDBytes = 256
    static let maximumRelativePathBytes = 1_024

    public var id: String
    public var stableConversationID: String
    public var watchedFolderID: String
    var legacyWatchedFolderID: String?
    public var watchedFolderName: String
    public var provider: AgentProvider
    public var reference: AgentSourceReference
    public var relativePath: String
    public var sourceCreatedAt: Date?
    public var sourceModifiedAt: Date?
    /// Provider conversation bounds, when available. These timestamps are metadata only.
    public var conversationStartedAt: Date?
    public var conversationEndedAt: Date?
    public var firstIndexedAt: Date
    public var lastObservedAt: Date
    public var byteCount: Int64
    public var sha256: String
    public var sourceDevice: UInt64?
    public var sourceInode: UInt64?
    public var sourceChangedSeconds: Int64?
    public var sourceChangedNanoseconds: Int64?
    /// Identity of a shared provider container (currently OpenCode's SQLite file).
    /// Regular-file sources leave these fields nil because `byteCount` and
    /// `sourceModifiedAt` already describe the source itself.
    public var sourceContainerByteCount: Int64?
    public var sourceContainerModifiedSeconds: Int64?
    public var sourceContainerModifiedNanoseconds: Int64?
    public var startOffset: Int64?
    public var endOffset: Int64?
    public var availability: AgentSourceAvailability
    public var statusDetail: String?

    public init(
        id: String,
        stableConversationID: String,
        watchedFolderID: String,
        watchedFolderName: String,
        provider: AgentProvider,
        reference: AgentSourceReference,
        relativePath: String,
        sourceCreatedAt: Date?,
        sourceModifiedAt: Date?,
        conversationStartedAt: Date? = nil,
        conversationEndedAt: Date? = nil,
        firstIndexedAt: Date,
        lastObservedAt: Date,
        byteCount: Int64,
        sha256: String,
        sourceDevice: UInt64? = nil,
        sourceInode: UInt64? = nil,
        sourceChangedSeconds: Int64? = nil,
        sourceChangedNanoseconds: Int64? = nil,
        sourceContainerByteCount: Int64? = nil,
        sourceContainerModifiedSeconds: Int64? = nil,
        sourceContainerModifiedNanoseconds: Int64? = nil,
        startOffset: Int64? = nil,
        endOffset: Int64? = nil,
        availability: AgentSourceAvailability = .available,
        statusDetail: String? = nil
    ) {
        _ = id
        let persistedFolderID = Self.persistedFolderID(
            rawValue: watchedFolderID,
            provider: provider,
            reference: reference,
            relativePath: relativePath
        )
        let persistedIdentifier = AgentStableConversationIdentifier.persisted(
            provider: provider,
            folderID: persistedFolderID,
            rawValue: stableConversationID,
            reference: reference
        )
        self.id = AgentStableConversationIdentifier.entryID(
            provider: provider,
            persistedIdentifier: persistedIdentifier
        )
        self.stableConversationID = persistedIdentifier
        self.watchedFolderID = persistedFolderID
        legacyWatchedFolderID = nil
        _ = watchedFolderName
        self.watchedFolderName = provider.displayName
        self.provider = provider
        let persistableReference = AgentSourceReference(
            kind: reference.kind,
            path: reference.path,
            locator: reference.kind == .sqliteConversation
                ? persistedIdentifier
                : nil
        )
        self.reference = persistableReference
        self.relativePath = Self.persistableRelativePath(
            relativePath,
            reference: persistableReference
        )
        self.sourceCreatedAt = sourceCreatedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.conversationStartedAt = conversationStartedAt
        self.conversationEndedAt = conversationEndedAt
        self.firstIndexedAt = firstIndexedAt
        self.lastObservedAt = lastObservedAt
        self.byteCount = byteCount
        let normalizedSHA256 = sha256.lowercased()
        self.sha256 =
            normalizedSHA256.utf8.count == 64
                && normalizedSHA256.unicodeScalars.allSatisfy {
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                }
            ? normalizedSHA256
            : ""
        self.sourceDevice = sourceDevice
        self.sourceInode = sourceInode
        self.sourceChangedSeconds = sourceChangedSeconds
        self.sourceChangedNanoseconds = sourceChangedNanoseconds
        self.sourceContainerByteCount = sourceContainerByteCount
        self.sourceContainerModifiedSeconds = sourceContainerModifiedSeconds
        self.sourceContainerModifiedNanoseconds = sourceContainerModifiedNanoseconds
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.availability = availability
        _ = statusDetail
        self.statusDetail = AgentSourceStatusCode.persistedValue(for: availability)
    }

    /// Reapplies the persisted-metadata contract after public mutable properties may have been
    /// changed by a caller. Stores call this immediately before indexing or encoding.
    func sanitizedForPersistence() -> AgentSourceIndexEntry {
        AgentSourceIndexEntry(
            id: id,
            stableConversationID: stableConversationID,
            watchedFolderID: watchedFolderID,
            watchedFolderName: watchedFolderName,
            provider: provider,
            reference: reference,
            relativePath: relativePath,
            sourceCreatedAt: sourceCreatedAt,
            sourceModifiedAt: sourceModifiedAt,
            conversationStartedAt: conversationStartedAt,
            conversationEndedAt: conversationEndedAt,
            firstIndexedAt: firstIndexedAt,
            lastObservedAt: lastObservedAt,
            byteCount: max(byteCount, 0),
            sha256: sha256.lowercased(),
            sourceDevice: sourceDevice,
            sourceInode: sourceInode,
            sourceChangedSeconds: sourceChangedSeconds,
            sourceChangedNanoseconds: sourceChangedNanoseconds,
            sourceContainerByteCount: sourceContainerByteCount,
            sourceContainerModifiedSeconds: sourceContainerModifiedSeconds,
            sourceContainerModifiedNanoseconds: sourceContainerModifiedNanoseconds,
            startOffset: startOffset,
            endOffset: endOffset,
            availability: availability,
            statusDetail: statusDetail
        )
    }

    private static func persistedFolderID(
        rawValue: String,
        provider: AgentProvider,
        reference: AgentSourceReference,
        relativePath: String
    ) -> String {
        if AgentFolderIdentifier.isPersisted(rawValue) { return rawValue.lowercased() }
        let root: URL?
        switch reference.kind {
        case .sqliteConversation:
            root = URL(fileURLWithPath: reference.path).deletingLastPathComponent()
        case .file:
            let relative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var candidateRoot = URL(fileURLWithPath: reference.path)
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            for _ in components { candidateRoot.deleteLastPathComponent() }
            let rebuilt = candidateRoot.appendingPathComponent(relative).standardizedFileURL.path
            root =
                !components.isEmpty && rebuilt == URL(fileURLWithPath: reference.path).standardizedFileURL.path
                ? candidateRoot
                : nil
        }
        guard let root else { return AgentFolderIdentifier.opaqueLegacy(rawValue) }
        return AgentFolderIdentifier.persisted(provider: provider, path: root.path)
    }

    private static func persistableRelativePath(
        _ rawValue: String,
        reference: AgentSourceReference
    ) -> String {
        switch reference.kind {
        case .sqliteConversation:
            guard let locator = reference.locator else { return "opencode.db#session/unavailable" }
            return "opencode.db#session/\(locator)"
        case .file:
            let candidate = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let containsControl = candidate.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
            let isActualSuffix =
                !candidate.isEmpty
                && (reference.path == "/\(candidate)" || reference.path.hasSuffix("/\(candidate)"))
            guard !containsControl, isActualSuffix,
                candidate.utf8.count <= maximumRelativePathBytes
            else {
                return AgentUTF8Bound.string(
                    URL(fileURLWithPath: reference.path).lastPathComponent,
                    maximumBytes: maximumRelativePathBytes
                )
            }
            return candidate
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case stableConversationID
        case watchedFolderID
        case watchedFolderName
        case provider
        case reference
        case relativePath
        case sourceCreatedAt
        case sourceModifiedAt
        case conversationStartedAt
        case conversationEndedAt
        case firstIndexedAt
        case lastObservedAt
        case byteCount
        case sha256
        case sourceDevice
        case sourceInode
        case sourceChangedSeconds
        case sourceChangedNanoseconds
        case sourceContainerByteCount
        case sourceContainerModifiedSeconds
        case sourceContainerModifiedNanoseconds
        case startOffset
        case endOffset
        case availability
        case statusDetail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFolderID = try container.decode(String.self, forKey: .watchedFolderID)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            stableConversationID: try container.decode(String.self, forKey: .stableConversationID),
            watchedFolderID: decodedFolderID,
            watchedFolderName: try container.decode(String.self, forKey: .watchedFolderName),
            provider: try container.decode(AgentProvider.self, forKey: .provider),
            reference: try container.decode(AgentSourceReference.self, forKey: .reference),
            relativePath: try container.decode(String.self, forKey: .relativePath),
            sourceCreatedAt: try container.decodeIfPresent(Date.self, forKey: .sourceCreatedAt),
            sourceModifiedAt: try container.decodeIfPresent(Date.self, forKey: .sourceModifiedAt),
            conversationStartedAt: try container.decodeIfPresent(Date.self, forKey: .conversationStartedAt),
            conversationEndedAt: try container.decodeIfPresent(Date.self, forKey: .conversationEndedAt),
            firstIndexedAt: try container.decode(Date.self, forKey: .firstIndexedAt),
            lastObservedAt: try container.decode(Date.self, forKey: .lastObservedAt),
            byteCount: try container.decode(Int64.self, forKey: .byteCount),
            sha256: try container.decode(String.self, forKey: .sha256),
            sourceDevice: try container.decodeIfPresent(UInt64.self, forKey: .sourceDevice),
            sourceInode: try container.decodeIfPresent(UInt64.self, forKey: .sourceInode),
            sourceChangedSeconds: try container.decodeIfPresent(Int64.self, forKey: .sourceChangedSeconds),
            sourceChangedNanoseconds: try container.decodeIfPresent(
                Int64.self,
                forKey: .sourceChangedNanoseconds
            ),
            sourceContainerByteCount: try container.decodeIfPresent(
                Int64.self,
                forKey: .sourceContainerByteCount
            ),
            sourceContainerModifiedSeconds: try container.decodeIfPresent(
                Int64.self,
                forKey: .sourceContainerModifiedSeconds
            ),
            sourceContainerModifiedNanoseconds: try container.decodeIfPresent(
                Int64.self,
                forKey: .sourceContainerModifiedNanoseconds
            ),
            startOffset: try container.decodeIfPresent(Int64.self, forKey: .startOffset),
            endOffset: try container.decodeIfPresent(Int64.self, forKey: .endOffset),
            availability: try container.decode(AgentSourceAvailability.self, forKey: .availability),
            statusDetail: try container.decodeIfPresent(String.self, forKey: .statusDetail)
        )
        if decodedFolderID != watchedFolderID { legacyWatchedFolderID = decodedFolderID }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(stableConversationID, forKey: .stableConversationID)
        try container.encode(watchedFolderID, forKey: .watchedFolderID)
        try container.encode(watchedFolderName, forKey: .watchedFolderName)
        try container.encode(provider, forKey: .provider)
        try container.encode(reference, forKey: .reference)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encodeIfPresent(sourceCreatedAt, forKey: .sourceCreatedAt)
        try container.encodeIfPresent(sourceModifiedAt, forKey: .sourceModifiedAt)
        try container.encodeIfPresent(conversationStartedAt, forKey: .conversationStartedAt)
        try container.encodeIfPresent(conversationEndedAt, forKey: .conversationEndedAt)
        try container.encode(firstIndexedAt, forKey: .firstIndexedAt)
        try container.encode(lastObservedAt, forKey: .lastObservedAt)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(sha256, forKey: .sha256)
        try container.encodeIfPresent(sourceDevice, forKey: .sourceDevice)
        try container.encodeIfPresent(sourceInode, forKey: .sourceInode)
        try container.encodeIfPresent(sourceChangedSeconds, forKey: .sourceChangedSeconds)
        try container.encodeIfPresent(sourceChangedNanoseconds, forKey: .sourceChangedNanoseconds)
        try container.encodeIfPresent(sourceContainerByteCount, forKey: .sourceContainerByteCount)
        try container.encodeIfPresent(
            sourceContainerModifiedSeconds,
            forKey: .sourceContainerModifiedSeconds
        )
        try container.encodeIfPresent(
            sourceContainerModifiedNanoseconds,
            forKey: .sourceContainerModifiedNanoseconds
        )
        try container.encodeIfPresent(startOffset, forKey: .startOffset)
        try container.encodeIfPresent(endOffset, forKey: .endOffset)
        try container.encode(availability, forKey: .availability)
        try container.encodeIfPresent(statusDetail, forKey: .statusDetail)
    }
}

/// An index entry paired with a non-persisted direct-read analysis.
public struct AgentCaptureRecord: Identifiable, Equatable, Sendable {
    public var index: AgentSourceIndexEntry
    public var summary: AgentDocumentSummary
    /// Whether `summary` was assembled from the original source during this process.
    /// This flag is transient because `AgentCaptureRecord` is never persisted.
    public var isAnalyzed: Bool

    public init(
        index: AgentSourceIndexEntry,
        summary: AgentDocumentSummary = AgentDocumentSummary(),
        isAnalyzed: Bool = true
    ) {
        self.index = index
        self.summary = summary
        self.isAnalyzed = isAnalyzed
    }

    public var id: String { index.id }
    public var sourceKey: String { index.id }
    public var watchedFolderID: String { index.watchedFolderID }
    public var watchedFolderName: String { index.watchedFolderName }
    public var provider: AgentProvider { index.provider }
    public var sourcePath: String { index.reference.path }
    public var relativePath: String { index.relativePath }
    public var sourceModifiedAt: Date? { index.sourceModifiedAt }
    public var capturedAt: Date { index.lastObservedAt }
    public var byteCount: Int64 { index.byteCount }
    public var sha256: String { index.sha256 }
    public var availability: AgentSourceAvailability { index.availability }

    public var searchableText: String {
        let boundedSummary = summary.boundedForTransientCache()
        return [
            provider.displayName,
            watchedFolderName,
            relativePath,
            boundedSummary.sessionID,
            boundedSummary.title,
            boundedSummary.excerpt,
            boundedSummary.projectPath,
            boundedSummary.models.joined(separator: " "),
            boundedSummary.tools.joined(separator: " "),
            boundedSummary.touchedFiles.joined(separator: " "),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }
}

public struct AgentActivityIndex: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entries: [AgentSourceIndexEntry]
    public var lastFullDiscoveryByFolder: [String: Date]
    public var lastFullDiscoveryAttemptByFolder: [String: Date]
    public var fullDiscoveryFailureCountByFolder: [String: Int]
    public var rootStatusByFolder: [String: AgentFolderRootStatus]
    public var lastHandledSignalByProvider: [String: Date]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 2,
        entries: [AgentSourceIndexEntry] = [],
        lastFullDiscoveryByFolder: [String: Date] = [:],
        lastFullDiscoveryAttemptByFolder: [String: Date] = [:],
        fullDiscoveryFailureCountByFolder: [String: Int] = [:],
        rootStatusByFolder: [String: AgentFolderRootStatus] = [:],
        lastHandledSignalByProvider: [String: Date] = [:],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.lastFullDiscoveryByFolder = lastFullDiscoveryByFolder
        self.lastFullDiscoveryAttemptByFolder = lastFullDiscoveryAttemptByFolder
        self.fullDiscoveryFailureCountByFolder = fullDiscoveryFailureCountByFolder
        self.rootStatusByFolder = rootStatusByFolder
        self.lastHandledSignalByProvider = lastHandledSignalByProvider.filter {
            AgentProvider(rawValue: $0.key) != nil
        }
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entries
        case lastFullDiscoveryByFolder
        case lastFullDiscoveryAttemptByFolder
        case fullDiscoveryFailureCountByFolder
        case rootStatusByFolder
        case lastHandledSignalByProvider
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries =
            try container.decodeIfPresent(
                [AgentSourceIndexEntry].self,
                forKey: .entries
            ) ?? []
        var folderMigration: [String: String] = [:]
        var ambiguousLegacyFolderIDs = Set<String>()
        for entry in decodedEntries {
            guard let legacy = entry.legacyWatchedFolderID else { continue }
            if let existing = folderMigration[legacy], existing != entry.watchedFolderID {
                ambiguousLegacyFolderIDs.insert(legacy)
                folderMigration[legacy] = nil
            } else if !ambiguousLegacyFolderIDs.contains(legacy) {
                folderMigration[legacy] = entry.watchedFolderID
            }
        }
        func normalizedFolderID(_ value: String) -> String {
            if let migrated = folderMigration[value] { return migrated }
            if AgentFolderIdentifier.isPersisted(value) { return value.lowercased() }
            return AgentFolderIdentifier.opaqueLegacy(value)
        }
        func normalizedDates(_ values: [String: Date]) -> [String: Date] {
            values.reduce(into: [:]) { output, item in
                let key = normalizedFolderID(item.key)
                output[key] = max(output[key] ?? .distantPast, item.value)
            }
        }
        func normalizedFailures(_ values: [String: Int]) -> [String: Int] {
            values.reduce(into: [:]) { output, item in
                let key = normalizedFolderID(item.key)
                output[key] = max(output[key] ?? 0, item.value)
            }
        }
        func normalizedRootStatuses(
            _ values: [String: AgentFolderRootStatus]
        ) -> [String: AgentFolderRootStatus] {
            values.reduce(into: [:]) { output, item in
                let key = normalizedFolderID(item.key)
                if output[key].map({ $0.changedAt >= item.value.changedAt }) != true {
                    output[key] = item.value
                }
            }
        }
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2,
            entries: decodedEntries,
            lastFullDiscoveryByFolder: normalizedDates(
                try container.decodeIfPresent(
                    [String: Date].self,
                    forKey: .lastFullDiscoveryByFolder
                ) ?? [:]
            ),
            lastFullDiscoveryAttemptByFolder: normalizedDates(
                try container.decodeIfPresent(
                    [String: Date].self,
                    forKey: .lastFullDiscoveryAttemptByFolder
                ) ?? [:]
            ),
            fullDiscoveryFailureCountByFolder: normalizedFailures(
                try container.decodeIfPresent(
                    [String: Int].self,
                    forKey: .fullDiscoveryFailureCountByFolder
                ) ?? [:]
            ),
            rootStatusByFolder: normalizedRootStatuses(
                try container.decodeIfPresent(
                    [String: AgentFolderRootStatus].self,
                    forKey: .rootStatusByFolder
                ) ?? [:]
            ),
            lastHandledSignalByProvider: (try container.decodeIfPresent(
                [String: Date].self,
                forKey: .lastHandledSignalByProvider
            ) ?? [:]).filter { AgentProvider(rawValue: $0.key) != nil },
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        )
    }
}

public struct AgentActivityOverview: Equatable, Sendable {
    public var day: Date
    public var captures: [AgentCaptureRecord]
    public var sessionCount: Int
    public var analyzedSessionCount: Int
    public var messageCount: Int
    public var visibleMessageCount: Int
    public var toolCallCount: Int
    public var errorCount: Int
    public var sourceBytes: Int64
    public var indexBytes: Int64
    public var lastCaptureAt: Date?

    public init(
        day: Date,
        captures: [AgentCaptureRecord] = [],
        sessionCount: Int = 0,
        analyzedSessionCount: Int = 0,
        messageCount: Int = 0,
        visibleMessageCount: Int = 0,
        toolCallCount: Int = 0,
        errorCount: Int = 0,
        sourceBytes: Int64 = 0,
        indexBytes: Int64 = 0,
        lastCaptureAt: Date? = nil
    ) {
        self.day = day
        self.captures = captures
        self.sessionCount = sessionCount
        self.analyzedSessionCount = analyzedSessionCount
        self.messageCount = messageCount
        self.visibleMessageCount = visibleMessageCount
        self.toolCallCount = toolCallCount
        self.errorCount = errorCount
        self.sourceBytes = sourceBytes
        self.indexBytes = indexBytes
        self.lastCaptureAt = lastCaptureAt
    }
}

public struct AgentScanResult: Equatable, Sendable {
    public var scannedSourceCount: Int
    public var changedSourceCount: Int
    public var skippedSourceCount: Int
    public var statusChangeCount: Int
    public var fullDiscoveryCount: Int
    /// True only while a user-requested content-analysis pass still has bounded follow-up work.
    public var analysisIncomplete: Bool
    /// Number of folders whose source inventory exceeded the configured/serialized index bound.
    /// Their deterministic newest metadata projection is complete, but the provider inventory is
    /// intentionally not represented in full.
    public var capacityLimitedFolderCount: Int
    public var failures: [String]
    public var captures: [AgentCaptureRecord]

    public init(
        scannedSourceCount: Int = 0,
        changedSourceCount: Int = 0,
        skippedSourceCount: Int = 0,
        statusChangeCount: Int = 0,
        fullDiscoveryCount: Int = 0,
        analysisIncomplete: Bool = false,
        capacityLimitedFolderCount: Int = 0,
        failures: [String] = [],
        captures: [AgentCaptureRecord] = []
    ) {
        self.scannedSourceCount = scannedSourceCount
        self.changedSourceCount = changedSourceCount
        self.skippedSourceCount = skippedSourceCount
        self.statusChangeCount = statusChangeCount
        self.fullDiscoveryCount = fullDiscoveryCount
        self.analysisIncomplete = analysisIncomplete
        self.capacityLimitedFolderCount = capacityLimitedFolderCount
        self.failures = failures
        self.captures = captures
    }
}

public struct AgentHookSignal: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var provider: AgentProvider
    public var eventName: String
    public var signaledAt: Date
    public var processIdentifier: Int32
    public var discardedPayloadBytes: Int64

    public init(
        schemaVersion: Int = 1,
        provider: AgentProvider,
        eventName: String,
        signaledAt: Date = Date(),
        processIdentifier: Int32,
        discardedPayloadBytes: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.eventName = eventName
        self.signaledAt = signaledAt
        self.processIdentifier = processIdentifier
        self.discardedPayloadBytes = discardedPayloadBytes
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
