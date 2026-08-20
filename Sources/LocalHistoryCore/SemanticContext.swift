import Foundation

/// The bounded source categories that may contribute to an authorized semantic snapshot.
/// They describe where macOS Accessibility exposed text; they do not assert authorship.
public enum SemanticContextSource: String, Codable, CaseIterable {
    case selectedText
    case focusedValue
    case visibleText
    case mixed
    case legacyMetadata
}

/// Integrity-safe metadata stored with a `semanticSnapshot` event. The plaintext lives in
/// a separately retained semantic payload file so detailed events can outlive or be deleted
/// independently from authorized visible text.
public struct SemanticContextReference: Codable, Equatable {
    public let snapshotID: String
    public let capturedAt: Date
    public let source: SemanticContextSource
    public let contentSHA256: String
    public let characterCount: Int
    public let redacted: Bool
    public let truncated: Bool

    public init(
        snapshotID: String,
        capturedAt: Date,
        source: SemanticContextSource,
        contentSHA256: String,
        characterCount: Int,
        redacted: Bool,
        truncated: Bool
    ) {
        self.snapshotID = snapshotID
        self.capturedAt = capturedAt
        self.source = source
        self.contentSHA256 = contentSHA256
        self.characterCount = max(0, characterCount)
        self.redacted = redacted
        self.truncated = truncated
    }
}

/// Separately retained, local-only plaintext captured through macOS Accessibility after
/// explicit consent. The context is deliberately duplicated here so a payload remains
/// auditable even when viewed independently from the event journal.
public struct SemanticContextPayload: Codable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let capturedAt: Date
    public let application: AppSnapshot
    public let window: WindowSnapshot?
    public let url: URLSnapshot?
    public let focusedRole: String?
    public let source: SemanticContextSource
    public let text: String
    public let contentSHA256: String
    public let redacted: Bool
    public let truncated: Bool

    public init(
        schemaVersion: Int = 1,
        id: String,
        capturedAt: Date,
        application: AppSnapshot,
        window: WindowSnapshot?,
        url: URLSnapshot?,
        focusedRole: String?,
        source: SemanticContextSource,
        text: String,
        contentSHA256: String,
        redacted: Bool,
        truncated: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.capturedAt = capturedAt
        self.application = application
        self.window = window
        self.url = url
        self.focusedRole = focusedRole
        self.source = source
        self.text = text
        self.contentSHA256 = contentSHA256
        self.redacted = redacted
        self.truncated = truncated
    }

    public var reference: SemanticContextReference {
        SemanticContextReference(
            snapshotID: id,
            capturedAt: capturedAt,
            source: source,
            contentSHA256: contentSHA256,
            characterCount: text.count,
            redacted: redacted,
            truncated: truncated
        )
    }
}

public enum SemanticContextValidationIssue: String, Codable, CaseIterable {
    case identifierMismatch
    case hashMismatch
    case characterCountMismatch
    case secureElementReferenced
    case suppressedEventReferenced
    case legacyPlaintextInModernEvent
}

/// Pure validation that can run before persistence and in migration tests. Hash generation
/// remains the responsibility of the app's existing SHA-256 implementation.
public enum SemanticContextValidator {
    public static func issues(
        event: HistoryEvent,
        payload: SemanticContextPayload?
    ) -> [SemanticContextValidationIssue] {
        var issues: [SemanticContextValidationIssue] = []
        if event.suppressionReason != nil, event.semanticContext != nil {
            issues.append(.suppressedEventReferenced)
        }
        if event.element?.isSecure == true, event.semanticContext != nil {
            issues.append(.secureElementReferenced)
        }
        if event.schemaVersion >= 4,
            event.metadata?["analysis.semantic_text"]?.isEmpty == false
        {
            issues.append(.legacyPlaintextInModernEvent)
        }
        guard let reference = event.semanticContext, let payload else { return issues }
        if reference.snapshotID != payload.id { issues.append(.identifierMismatch) }
        let computedHash = SHA256Digest.hashHex(payload.text)
        if payload.contentSHA256 != computedHash || reference.contentSHA256 != computedHash {
            issues.append(.hashMismatch)
        }
        if reference.characterCount != payload.text.count { issues.append(.characterCountMismatch) }
        return issues
    }
}

public enum SemanticContextResolver {
    /// Resolves a semantic payload only when its source event and reference validate.
    /// Legacy inline metadata remains readable for migration, but new schema-v4
    /// events are expected to use the separate semantic store.
    public static func text(
        for event: HistoryEvent,
        semanticSnapshots: [String: SemanticContextPayload] = [:],
        includeLegacyInlineMetadata: Bool = true
    ) -> String? {
        if let reference = event.semanticContext,
            let payload = semanticSnapshots[reference.snapshotID],
            SemanticContextValidator.issues(event: event, payload: payload).isEmpty
        {
            let value = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        guard includeLegacyInlineMetadata else { return nil }
        let keys = [
            "analysis.semantic_text",
            "semantic.text",
            "rich_context.text",
        ]
        for key in keys {
            if let value = event.metadata?[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            {
                return value
            }
        }
        return nil
    }
}
