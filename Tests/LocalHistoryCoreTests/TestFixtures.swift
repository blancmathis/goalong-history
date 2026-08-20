import Foundation
@testable import LocalHistoryCore

let fixtureStart = Date(timeIntervalSince1970: 1_800_000_000)

func fixtureBuild(
    signature: BuildSignatureKind = .adHoc,
    cdHash: String = "hash-a",
    team: String? = nil
) -> CaptureBuildIdentity {
    CaptureBuildIdentity(
        bundleIdentifier: "ai.goalong.localhistory",
        displayVersion: "1.0",
        buildNumber: "1",
        executablePath: "/Applications/LocalHistory.app/Contents/MacOS/LocalHistory",
        signatureKind: signature,
        signingIdentifier: signature == .developerID ? "ai.goalong.localhistory" : nil,
        teamIdentifier: team,
        codeDirectoryHash: cdHash,
        designatedRequirement: signature == .developerID
            ? "anchor apple generic and identifier ai.goalong.localhistory"
            : "cdhash H\"\(cdHash)\""
    )
}

func fixturePermissions(
    preflight: Bool = true,
    functional: Bool = true,
    input: Bool = false,
    at: Date = fixtureStart
) -> CapturePermissionObservation {
    CapturePermissionObservation(
        accessibilityPreflight: preflight,
        accessibilityFunctionalProbe: functional,
        inputMonitoringPreflight: input,
        observedAt: at
    )
}

func fixtureHealth(
    now: Date = fixtureStart,
    build: CaptureBuildIdentity = fixtureBuild(),
    lastWorking: CaptureBuildIdentity? = nil,
    permissions: CapturePermissionObservation = fixturePermissions(),
    lifecycle: CaptureEventTapLifecycle = .createdEnabled,
    callback: Date? = nil,
    AXSuccess: Date? = fixtureStart,
    AXFailure: Date? = nil,
    suppression: SuppressionReason? = nil,
    paused: Bool = false,
    expected: Date? = nil,
    counters: [String: Int] = [:]
) -> CaptureHealthSnapshot {
    CaptureHealthSnapshot(
        generatedAt: now,
        launchedAt: now.addingTimeInterval(-120),
        build: build,
        lastKnownWorkingBuild: lastWorking,
        permissions: permissions,
        eventTapLifecycle: lifecycle,
        eventTapLastError: lifecycle == .creationFailed ? "permission denied" : nil,
        eventTapLastEnabledAt: lifecycle == .createdEnabled ? now.addingTimeInterval(-60) : nil,
        eventTapLastDisabledAt: lifecycle == .createdDisabled ? now.addingTimeInterval(-10) : nil,
        lastCallbackAt: callback,
        lastInputEventAt: callback,
        lastClickAt: callback,
        lastTypingBurstAt: nil,
        lastScrollAt: nil,
        lastShortcutAt: nil,
        lastAXContextSuccessAt: AXSuccess,
        lastAXContextFailureAt: AXFailure,
        lastURLDetectedAt: AXSuccess,
        lastSuppressionAt: suppression == nil ? nil : now,
        lastSuppressionReason: suppression,
        currentSuppressionReason: suppression,
        isManuallyPaused: paused,
        recentCounters: CaptureRecentCounters(byEventKind: counters),
        expectedInputAfter: expected,
        inputCallbackObservedThisLaunch: callback != nil
    )
}

func fixtureApp(_ name: String = "Safari") -> AppSnapshot {
    AppSnapshot(
        name: name,
        bundleIdentifier: name == "Safari" ? "com.apple.Safari" : "com.example.\(name.lowercased())",
        processIdentifier: 42
    )
}

func fixtureIntegrity(_ sequence: UInt64) -> EventIntegrity {
    EventIntegrity(
        sequence: sequence,
        previousEventHash: "prev-\(sequence)",
        eventRoot: "root-\(sequence)",
        eventHash: "hash-\(sequence)",
        fieldCommitments: []
    )
}

func fixtureEvent(
    id: String,
    sequence: UInt64,
    offset: TimeInterval,
    kind: EventKind,
    app: AppSnapshot? = fixtureApp(),
    windowTitle: String? = "Go Long History",
    host: String? = "example.com",
    suppression: SuppressionReason? = nil,
    message: String? = nil,
    metadata: [String: String]? = nil,
    semanticContext: SemanticContextReference? = nil,
    keyboard: KeyboardSnapshot? = nil,
    pointer: PointerSnapshot? = nil,
    scroll: ScrollSnapshot? = nil,
    secureElement: Bool = false,
    schemaVersion: Int = 4
) -> HistoryEvent {
    HistoryEvent(
        schemaVersion: schemaVersion,
        id: id,
        sessionID: "session",
        timestamp: fixtureStart.addingTimeInterval(offset),
        kind: kind,
        app: app,
        window: windowTitle.map { WindowSnapshot(title: $0, role: "AXWindow", subrole: nil) },
        element: ElementSnapshot(
            role: secureElement ? "AXSecureTextField" : "AXButton",
            subrole: nil,
            title: "Submit",
            label: "Submit",
            identifier: "submit",
            isSecure: secureElement
        ),
        url: host.map { URLSnapshot(value: "https://\($0)/page", host: $0, redactionApplied: true) },
        pointer: pointer,
        keyboard: keyboard,
        scroll: scroll,
        inputOrigin: nil,
        semanticContext: semanticContext,
        classification: LocalClassification(
            category: "development",
            isWork: true,
            confidence: 0.9,
            classifierVersion: "test"
        ),
        suppressionReason: suppression,
        message: message,
        metadata: metadata,
        integrity: fixtureIntegrity(sequence)
    )
}

func fixtureSemanticPayload(
    id: String = "semantic-1",
    text: String = "Please explain the current implementation.",
    hash: String? = nil
) -> SemanticContextPayload {
    SemanticContextPayload(
        id: id,
        capturedAt: fixtureStart.addingTimeInterval(15),
        application: fixtureApp(),
        window: WindowSnapshot(title: "Chat", role: "AXWindow", subrole: nil),
        url: URLSnapshot(value: "https://chatgpt.com/c/123", host: "chatgpt.com", redactionApplied: true),
        focusedRole: "AXTextArea",
        source: .mixed,
        text: text,
        contentSHA256: hash ?? SHA256Digest.hashHex(text),
        redacted: false,
        truncated: false
    )
}
