import Foundation

public enum EventKind: String, Codable, CaseIterable {
    case recorderStarted
    case recorderStopped
    case recordingPaused
    case recordingResumed
    case permissionStatus
    case applicationActivated
    case windowChanged
    case focusChanged
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

public struct EventIntegrity: Codable, Equatable {
    public let sequence: UInt64
    public let previousEventHash: String
    public let eventRoot: String
    public let eventHash: String
    public let fieldCommitments: [LocalFieldCommitment]

    public init(
        sequence: UInt64,
        previousEventHash: String,
        eventRoot: String,
        eventHash: String,
        fieldCommitments: [LocalFieldCommitment]
    ) {
        self.sequence = sequence
        self.previousEventHash = previousEventHash
        self.eventRoot = eventRoot
        self.eventHash = eventHash
        self.fieldCommitments = fieldCommitments
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
            classification: classification,
            suppressionReason: suppressionReason,
            message: message,
            metadata: metadata,
            integrity: integrity
        )
    }
}
