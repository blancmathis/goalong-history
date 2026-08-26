import Foundation

public enum EventKind: String, Codable, CaseIterable {
    case recorderStarted
    case recorderStopped
    case recordingPaused
    case recordingResumed
    case permissionStatus
    case recorderHealth
    case applicationActivated
    case windowChanged
    case focusChanged
    case semanticSnapshot
    case urlChanged
    case mouseClick
    case keyboardShortcut
    case keyPressed
    case typingBurst
    case scrollBurst
    case heartbeat
    case captureSuppressed
    case captureResumed
    case secureInputSuppressed
    case secureInputResumed
    case sessionLocked
    case sessionUnlocked
    case systemSleep
    case systemWake
    case historyCleared
    case agentArtifactCaptured
    case diagnostic
}

public enum SuppressionReason: String, Codable, Equatable {
    case privateBrowserWindow
    case excludedApplication
    case excludedDomain
    case secureInput
    case sessionUnavailable
    case manualPause
    case accessibilityUnavailable
}

public struct AppSnapshot: Codable, Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32

    public init(name: String, bundleIdentifier: String?, processIdentifier: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

public struct WindowSnapshot: Codable, Equatable {
    public let title: String?
    public let role: String?
    public let subrole: String?

    public init(title: String?, role: String?, subrole: String?) {
        self.title = title
        self.role = role
        self.subrole = subrole
    }
}

public struct ElementSnapshot: Codable, Equatable {
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let label: String?
    public let identifier: String?
    public let isSecure: Bool

    public init(
        role: String?,
        subrole: String?,
        title: String?,
        label: String?,
        identifier: String?,
        isSecure: Bool
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.identifier = identifier
        self.isSecure = isSecure
    }
}

public struct URLSnapshot: Codable, Equatable {
    public let value: String
    public let host: String?
    public let redactionApplied: Bool

    public init(value: String, host: String?, redactionApplied: Bool) {
        self.value = value
        self.host = host
        self.redactionApplied = redactionApplied
    }
}

public struct PointerSnapshot: Codable, Equatable {
    public let button: String
    public let x: Double
    public let y: Double
    public let clickCount: Int

    public init(button: String, x: Double, y: Double, clickCount: Int) {
        self.button = button
        self.x = x
        self.y = y
        self.clickCount = clickCount
    }
}

public struct KeyboardSnapshot: Codable, Equatable {
    public let category: String
    public let key: String?
    public let modifiers: [String]
    public let isRepeat: Bool

    public init(category: String, key: String?, modifiers: [String], isRepeat: Bool) {
        self.category = category
        self.key = key
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

public struct ScrollSnapshot: Codable, Equatable {
    public let deltaX: Double
    public let deltaY: Double
    public let eventCount: Int

    public init(deltaX: Double, deltaY: Double, eventCount: Int) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.eventCount = eventCount
    }
}

public enum InputOriginAssessment: String, Codable, Equatable {
    /// Core Graphics attributed the event to a userspace process. This is an anti-cheat signal, not proof of fraud.
    case softwareAttributed
    /// The event was observed in HID-like state with no attributable userspace PID. Still not proof of a human.
    case hidLike
    case unknown
}

public struct InputOriginSnapshot: Codable, Equatable {
    public let sourceProcessIdentifier: Int64?
    public let sourceUserIdentifier: Int64?
    public let sourceStateID: Int64?
    public let sourceProcessName: String?
    public let sourceBundleIdentifier: String?
    public let assessment: InputOriginAssessment

    public init(
        sourceProcessIdentifier: Int64?,
        sourceUserIdentifier: Int64?,
        sourceStateID: Int64?,
        sourceProcessName: String?,
        sourceBundleIdentifier: String?,
        assessment: InputOriginAssessment
    ) {
        self.sourceProcessIdentifier = sourceProcessIdentifier
        self.sourceUserIdentifier = sourceUserIdentifier
        self.sourceStateID = sourceStateID
        self.sourceProcessName = sourceProcessName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.assessment = assessment
    }
}

public struct LocalClassification: Codable, Equatable {
    public let category: String
    public let isWork: Bool?
    public let confidence: Double
    public let classifierVersion: String

    public init(category: String, isWork: Bool?, confidence: Double, classifierVersion: String) {
        self.category = category
        self.isWork = isWork
        self.confidence = confidence
        self.classifierVersion = classifierVersion
    }
}

public enum EventIntegrityStorageFormat: Equatable {
    case fullCommitments
    case compactSalts
}

public struct EventIntegrity: Codable, Equatable {
    public let sequence: UInt64
    public let previousEventHash: String
    public let eventRoot: String
    public let eventHash: String
    public let fieldCommitments: [LocalFieldCommitment]
    /// Controls only the next HistoryEvent JSON encoding. It is deliberately not
    /// part of EventIntegrity's standalone Codable representation.
    public let storageFormat: EventIntegrityStorageFormat

    public init(
        sequence: UInt64,
        previousEventHash: String,
        eventRoot: String,
        eventHash: String,
        fieldCommitments: [LocalFieldCommitment],
        storageFormat: EventIntegrityStorageFormat = .fullCommitments
    ) {
        self.sequence = sequence
        self.previousEventHash = previousEventHash
        self.eventRoot = eventRoot
        self.eventHash = eventHash
        self.fieldCommitments = fieldCommitments
        self.storageFormat = storageFormat
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case previousEventHash
        case eventRoot
        case eventHash
        case fieldCommitments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        previousEventHash = try container.decode(String.self, forKey: .previousEventHash)
        eventRoot = try container.decode(String.self, forKey: .eventRoot)
        eventHash = try container.decode(String.self, forKey: .eventHash)
        fieldCommitments = try container.decode([LocalFieldCommitment].self, forKey: .fieldCommitments)
        storageFormat = .fullCommitments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(previousEventHash, forKey: .previousEventHash)
        try container.encode(eventRoot, forKey: .eventRoot)
        try container.encode(eventHash, forKey: .eventHash)
        try container.encode(fieldCommitments, forKey: .fieldCommitments)
    }
}

public struct ContextSnapshot: Equatable {
    public let app: AppSnapshot
    public let window: WindowSnapshot?
    public let focusedElement: ElementSnapshot?
    public let url: URLSnapshot?
    public let suppressionReason: SuppressionReason?

    public init(
        app: AppSnapshot,
        window: WindowSnapshot?,
        focusedElement: ElementSnapshot?,
        url: URLSnapshot?,
        suppressionReason: SuppressionReason?
    ) {
        self.app = app
        self.window = window
        self.focusedElement = focusedElement
        self.url = url
        self.suppressionReason = suppressionReason
    }

    public var fingerprint: String {
        var parts: [String] = []
        parts.append(app.bundleIdentifier ?? app.name)
        parts.append(window?.title ?? "")
        parts.append(focusedElement?.role ?? "")
        parts.append(focusedElement?.identifier ?? "")
        parts.append(focusedElement?.title ?? "")
        parts.append(focusedElement?.label ?? "")
        parts.append(url?.value ?? "")
        parts.append(suppressionReason?.rawValue ?? "")
        return parts.joined(separator: "|")
    }
}

public struct HistoryEvent: Codable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let sessionID: String
    public let timestamp: Date
    public let kind: EventKind
    public let app: AppSnapshot?
    public let window: WindowSnapshot?
    public let element: ElementSnapshot?
    public let url: URLSnapshot?
    public let pointer: PointerSnapshot?
    public let keyboard: KeyboardSnapshot?
    public let scroll: ScrollSnapshot?
    public let inputOrigin: InputOriginSnapshot?
    public let semanticContext: SemanticContextReference?
    public let classification: LocalClassification?
    public let suppressionReason: SuppressionReason?
    public let message: String?
    public let metadata: [String: String]?
    public let integrity: EventIntegrity?

    public init(
        schemaVersion: Int = 2,
        id: String = UUID().uuidString,
        sessionID: String,
        timestamp: Date = Date(),
        kind: EventKind,
        app: AppSnapshot? = nil,
        window: WindowSnapshot? = nil,
        element: ElementSnapshot? = nil,
        url: URLSnapshot? = nil,
        pointer: PointerSnapshot? = nil,
        keyboard: KeyboardSnapshot? = nil,
        scroll: ScrollSnapshot? = nil,
        inputOrigin: InputOriginSnapshot? = nil,
        semanticContext: SemanticContextReference? = nil,
        classification: LocalClassification? = nil,
        suppressionReason: SuppressionReason? = nil,
        message: String? = nil,
        metadata: [String: String]? = nil,
        integrity: EventIntegrity? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.kind = kind
        self.app = app
        self.window = window
        self.element = element
        self.url = url
        self.pointer = pointer
        self.keyboard = keyboard
        self.scroll = scroll
        self.inputOrigin = inputOrigin
        self.semanticContext = semanticContext
        self.classification = classification
        self.suppressionReason = suppressionReason
        self.message = message
        self.metadata = metadata
        self.integrity = integrity
    }

    public func replacingIntegrity(_ integrity: EventIntegrity?) -> HistoryEvent {
        HistoryEvent(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: sessionID,
            timestamp: timestamp,
            kind: kind,
            app: app,
            window: window,
            element: element,
            url: url,
            pointer: pointer,
            keyboard: keyboard,
            scroll: scroll,
            inputOrigin: inputOrigin,
            semanticContext: semanticContext,
            classification: classification,
            suppressionReason: suppressionReason,
            message: message,
            metadata: metadata,
            integrity: integrity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case sessionID
        case timestamp
        case kind
        case app
        case window
        case element
        case url
        case pointer
        case keyboard
        case scroll
        case inputOrigin
        case semanticContext
        case classification
        case suppressionReason
        case message
        case metadata
        case integrity
    }

    private struct CompactEventIntegrity: Codable {
        static let currentFormat = "salts-v1"

        let format: String
        let sequence: UInt64
        let previousEventHash: String
        let eventRoot: String
        let eventHash: String
        let fieldSalts: [String]
        let rawEventDigest: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let id = try container.decode(String.self, forKey: .id)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let kind = try container.decode(EventKind.self, forKey: .kind)
        let app = try container.decodeIfPresent(AppSnapshot.self, forKey: .app)
        let window = try container.decodeIfPresent(WindowSnapshot.self, forKey: .window)
        let element = try container.decodeIfPresent(ElementSnapshot.self, forKey: .element)
        let url = try container.decodeIfPresent(URLSnapshot.self, forKey: .url)
        let pointer = try container.decodeIfPresent(PointerSnapshot.self, forKey: .pointer)
        let keyboard = try container.decodeIfPresent(KeyboardSnapshot.self, forKey: .keyboard)
        let scroll = try container.decodeIfPresent(ScrollSnapshot.self, forKey: .scroll)
        let inputOrigin = try container.decodeIfPresent(InputOriginSnapshot.self, forKey: .inputOrigin)
        let semanticContext = try container.decodeIfPresent(
            SemanticContextReference.self,
            forKey: .semanticContext
        )
        let classification = try container.decodeIfPresent(
            LocalClassification.self,
            forKey: .classification
        )
        let suppressionReason = try container.decodeIfPresent(
            SuppressionReason.self,
            forKey: .suppressionReason
        )
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        let metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)

        let base = HistoryEvent(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: sessionID,
            timestamp: timestamp,
            kind: kind,
            app: app,
            window: window,
            element: element,
            url: url,
            pointer: pointer,
            keyboard: keyboard,
            scroll: scroll,
            inputOrigin: inputOrigin,
            semanticContext: semanticContext,
            classification: classification,
            suppressionReason: suppressionReason,
            message: message,
            metadata: metadata,
            integrity: nil
        )

        let integrity: EventIntegrity?
        if schemaVersion >= 5,
            let compact = try? container.decode(CompactEventIntegrity.self, forKey: .integrity),
            compact.format == CompactEventIntegrity.currentFormat
        {
            guard let commitments = EventIntegrityMaterial.rehydrateFieldCommitments(
                for: base,
                saltBase64Values: compact.fieldSalts,
                rawEventDigest: compact.rawEventDigest
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .integrity,
                    in: container,
                    debugDescription: "Compact event integrity salts are incomplete or invalid."
                )
            }
            integrity = EventIntegrity(
                sequence: compact.sequence,
                previousEventHash: compact.previousEventHash,
                eventRoot: compact.eventRoot,
                eventHash: compact.eventHash,
                fieldCommitments: commitments,
                storageFormat: .compactSalts
            )
        } else {
            integrity = try container.decodeIfPresent(EventIntegrity.self, forKey: .integrity)
        }

        self.init(
            schemaVersion: schemaVersion,
            id: id,
            sessionID: sessionID,
            timestamp: timestamp,
            kind: kind,
            app: app,
            window: window,
            element: element,
            url: url,
            pointer: pointer,
            keyboard: keyboard,
            scroll: scroll,
            inputOrigin: inputOrigin,
            semanticContext: semanticContext,
            classification: classification,
            suppressionReason: suppressionReason,
            message: message,
            metadata: metadata,
            integrity: integrity
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(app, forKey: .app)
        try container.encodeIfPresent(window, forKey: .window)
        try container.encodeIfPresent(element, forKey: .element)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(pointer, forKey: .pointer)
        try container.encodeIfPresent(keyboard, forKey: .keyboard)
        try container.encodeIfPresent(scroll, forKey: .scroll)
        try container.encodeIfPresent(inputOrigin, forKey: .inputOrigin)
        try container.encodeIfPresent(semanticContext, forKey: .semanticContext)
        try container.encodeIfPresent(classification, forKey: .classification)
        try container.encodeIfPresent(suppressionReason, forKey: .suppressionReason)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(metadata, forKey: .metadata)

        guard let integrity else { return }
        guard schemaVersion >= 5, integrity.storageFormat == .compactSalts else {
            try container.encode(integrity, forKey: .integrity)
            return
        }

        let order = IntegrityDomains.eventFieldOrder(for: schemaVersion)
        var commitmentsByName: [String: LocalFieldCommitment] = [:]
        commitmentsByName.reserveCapacity(integrity.fieldCommitments.count)
        for commitment in integrity.fieldCommitments {
            guard commitmentsByName.updateValue(commitment, forKey: commitment.name) == nil else {
                throw EncodingError.invalidValue(
                    integrity,
                    EncodingError.Context(
                        codingPath: container.codingPath + [CodingKeys.integrity],
                        debugDescription: "Event integrity contains duplicate field commitments."
                    )
                )
            }
        }
        guard commitmentsByName.count == order.count else {
            throw EncodingError.invalidValue(
                integrity,
                EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.integrity],
                    debugDescription: "Compact event integrity is missing a required field commitment."
                )
            )
        }
        let fieldSalts = try order.map { name -> String in
            guard let value = commitmentsByName[name]?.opening.saltBase64,
                let salt = Data(base64Encoded: value),
                salt.count == 32
            else {
                throw EncodingError.invalidValue(
                    integrity,
                    EncodingError.Context(
                        codingPath: container.codingPath + [CodingKeys.integrity],
                        debugDescription: "Compact event integrity contains an invalid field salt."
                    )
                )
            }
            return value
        }
        guard let rawEventDigest = commitmentsByName["raw_digest"]?
            .opening.fields["sha256"],
            EventIntegrityMaterial.isLowercaseSHA256(rawEventDigest)
        else {
            throw EncodingError.invalidValue(
                integrity,
                EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.integrity],
                    debugDescription: "Compact event integrity contains no raw-event digest."
                )
            )
        }
        try container.encode(
            CompactEventIntegrity(
                format: CompactEventIntegrity.currentFormat,
                sequence: integrity.sequence,
                previousEventHash: integrity.previousEventHash,
                eventRoot: integrity.eventRoot,
                eventHash: integrity.eventHash,
                fieldSalts: fieldSalts,
                rawEventDigest: rawEventDigest
            ),
            forKey: .integrity
        )
    }
}
