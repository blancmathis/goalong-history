import Foundation

public enum BuildSignatureKind: String, Codable, CaseIterable {
    case adHoc
    case appleDevelopment
    case developerID
    case appStore
    case other
    case unsigned
}

/// Identity facts for the exact executable that is currently running.
///
/// For a certificate-backed Apple build, `teamIdentifier` + `signingIdentifier` are
/// the stable identity inputs expected to survive a rebuild signed by the same team.
/// For an ad-hoc build, the CDHash identifies only that exact code version and must
/// therefore be treated as unstable.
public struct CaptureBuildIdentity: Codable, Equatable {
    public let bundleIdentifier: String
    public let displayVersion: String?
    public let buildNumber: String?
    public let executablePath: String
    public let signatureKind: BuildSignatureKind
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let codeDirectoryHash: String?
    public let designatedRequirement: String?

    public init(
        bundleIdentifier: String,
        displayVersion: String?,
        buildNumber: String?,
        executablePath: String,
        signatureKind: BuildSignatureKind,
        signingIdentifier: String?,
        teamIdentifier: String?,
        codeDirectoryHash: String?,
        designatedRequirement: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayVersion = displayVersion
        self.buildNumber = buildNumber
        self.executablePath = executablePath
        self.signatureKind = signatureKind
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
        self.designatedRequirement = designatedRequirement
    }

    public var isStableAcrossUpdates: Bool {
        signatureKind == .appleDevelopment
            || signatureKind == .developerID
            || signatureKind == .appStore
    }

    /// A conservative identity key used only for diagnostics. It is not a
    /// substitute for macOS code requirement evaluation.
    public var permissionIdentityKey: String {
        switch signatureKind {
        case .appleDevelopment, .developerID, .appStore:
            return [
                signatureKind.rawValue,
                bundleIdentifier,
                teamIdentifier ?? "missing-team",
                signingIdentifier ?? "missing-signing-id",
            ].joined(separator: "|")
        case .adHoc:
            return [
                signatureKind.rawValue,
                bundleIdentifier,
                codeDirectoryHash ?? "missing-cdhash",
            ].joined(separator: "|")
        case .other, .unsigned:
            return [
                signatureKind.rawValue,
                bundleIdentifier,
                signingIdentifier ?? "",
                teamIdentifier ?? "",
                codeDirectoryHash ?? "",
            ].joined(separator: "|")
        }
    }

    public func hasSamePermissionIdentity(as other: CaptureBuildIdentity) -> Bool {
        permissionIdentityKey == other.permissionIdentityKey
    }
}

public struct CapturePermissionObservation: Codable, Equatable {
    /// Result of `AXIsProcessTrusted()`.
    public let accessibilityPreflight: Bool
    /// Whether the process successfully read the focused application through AX.
    public let accessibilityFunctionalProbe: Bool
    /// Result of `CGPreflightListenEventAccess()`; it is not treated as proof that
    /// the recorder's event tap is actually delivering callbacks.
    public let inputMonitoringPreflight: Bool
    public let observedAt: Date

    public init(
        accessibilityPreflight: Bool,
        accessibilityFunctionalProbe: Bool,
        inputMonitoringPreflight: Bool,
        observedAt: Date
    ) {
        self.accessibilityPreflight = accessibilityPreflight
        self.accessibilityFunctionalProbe = accessibilityFunctionalProbe
        self.inputMonitoringPreflight = inputMonitoringPreflight
        self.observedAt = observedAt
    }

    public var accessibilityUsable: Bool {
        accessibilityPreflight && accessibilityFunctionalProbe
    }
}

public enum CaptureEventTapLifecycle: String, Codable, CaseIterable {
    case neverAttempted
    case creationFailed
    case createdDisabled
    case createdEnabled
}

public struct CaptureRecentCounters: Codable, Equatable {
    public let windowSeconds: Int
    public let byEventKind: [String: Int]

    public init(windowSeconds: Int = 300, byEventKind: [String: Int] = [:]) {
        self.windowSeconds = max(1, windowSeconds)
        self.byEventKind = byEventKind
    }

    public subscript(kind: EventKind) -> Int {
        byEventKind[kind.rawValue, default: 0]
    }

    public var inputEventCount: Int {
        [
            EventKind.mouseClick,
            .typingBurst,
            .scrollBurst,
            .keyboardShortcut,
            .keyPressed,
        ].reduce(0) { $0 + self[$1] }
    }
}

public struct CaptureHealthSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let launchedAt: Date
    public let build: CaptureBuildIdentity
    public let lastKnownWorkingBuild: CaptureBuildIdentity?
    public let permissions: CapturePermissionObservation
    public let eventTapLifecycle: CaptureEventTapLifecycle
    public let eventTapLastError: String?
    public let eventTapLastEnabledAt: Date?
    public let eventTapLastDisabledAt: Date?
    public let lastCallbackAt: Date?
    public let lastInputEventAt: Date?
    public let lastClickAt: Date?
    public let lastTypingBurstAt: Date?
    public let lastScrollAt: Date?
    public let lastShortcutAt: Date?
    public let lastAXContextSuccessAt: Date?
    public let lastAXContextFailureAt: Date?
    public let lastURLDetectedAt: Date?
    public let lastSuppressionAt: Date?
    public let lastSuppressionReason: SuppressionReason?
    public let currentSuppressionReason: SuppressionReason?
    public let isManuallyPaused: Bool
    public let recentCounters: CaptureRecentCounters
    /// Set when the user explicitly starts a controlled input validation. It lets
    /// diagnostics distinguish quiet idleness from a tap that failed to deliver an
    /// input the user just produced.
    public let expectedInputAfter: Date?
    /// True only when a real click/key/scroll callback reached the currently running
    /// process. Historical timestamps are retained for diagnostics but never prove
    /// that a newly launched process is receiving input.
    public let inputCallbackObservedThisLaunch: Bool?

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        launchedAt: Date,
        build: CaptureBuildIdentity,
        lastKnownWorkingBuild: CaptureBuildIdentity?,
        permissions: CapturePermissionObservation,
        eventTapLifecycle: CaptureEventTapLifecycle,
        eventTapLastError: String?,
        eventTapLastEnabledAt: Date?,
        eventTapLastDisabledAt: Date?,
        lastCallbackAt: Date?,
        lastInputEventAt: Date?,
        lastClickAt: Date?,
        lastTypingBurstAt: Date?,
        lastScrollAt: Date?,
        lastShortcutAt: Date?,
        lastAXContextSuccessAt: Date?,
        lastAXContextFailureAt: Date?,
        lastURLDetectedAt: Date?,
        lastSuppressionAt: Date?,
        lastSuppressionReason: SuppressionReason?,
        currentSuppressionReason: SuppressionReason?,
        isManuallyPaused: Bool,
        recentCounters: CaptureRecentCounters,
        expectedInputAfter: Date?,
        inputCallbackObservedThisLaunch: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.launchedAt = launchedAt
        self.build = build
        self.lastKnownWorkingBuild = lastKnownWorkingBuild
        self.permissions = permissions
        self.eventTapLifecycle = eventTapLifecycle
        self.eventTapLastError = eventTapLastError
        self.eventTapLastEnabledAt = eventTapLastEnabledAt
        self.eventTapLastDisabledAt = eventTapLastDisabledAt
        self.lastCallbackAt = lastCallbackAt
        self.lastInputEventAt = lastInputEventAt
        self.lastClickAt = lastClickAt
        self.lastTypingBurstAt = lastTypingBurstAt
        self.lastScrollAt = lastScrollAt
        self.lastShortcutAt = lastShortcutAt
        self.lastAXContextSuccessAt = lastAXContextSuccessAt
        self.lastAXContextFailureAt = lastAXContextFailureAt
        self.lastURLDetectedAt = lastURLDetectedAt
        self.lastSuppressionAt = lastSuppressionAt
        self.lastSuppressionReason = lastSuppressionReason
        self.currentSuppressionReason = currentSuppressionReason
        self.isManuallyPaused = isManuallyPaused
        self.recentCounters = recentCounters
        self.expectedInputAfter = expectedInputAfter
        self.inputCallbackObservedThisLaunch = inputCallbackObservedThisLaunch
    }
}

public enum CaptureHealthState: String, Codable, CaseIterable {
    case ready
    case permissionRequired
    case permissionAppearsEnabledButStaleForBuild
    case inputTapUnavailable
    case accessibilityContextUnavailable
    case paused
    case excludedPrivateOrSecure
    case healthyButIdle
    case awaitingInputEvidence

    public var title: String {
        switch self {
        case .ready: return "Ready"
        case .permissionRequired: return "Permission required"
        case .permissionAppearsEnabledButStaleForBuild:
            return "Permission appears enabled but is stale for this build"
        case .inputTapUnavailable: return "Input tap unavailable"
        case .accessibilityContextUnavailable: return "Accessibility context unavailable"
        case .paused: return "Paused"
        case .excludedPrivateOrSecure: return "Excluded, private or secure"
        case .healthyButIdle: return "Capture healthy but currently idle"
        case .awaitingInputEvidence: return "Waiting for the first real input event"
        }
    }
}

public struct CaptureHealthAssessment: Codable, Equatable {
    public let state: CaptureHealthState
    public let detail: String
    public let captureProven: Bool
    public let limitations: [String]

    public init(
        state: CaptureHealthState,
        detail: String,
        captureProven: Bool,
        limitations: [String] = []
    ) {
        self.state = state
        self.detail = detail
        self.captureProven = captureProven
        self.limitations = limitations
    }
}

public enum CaptureHealthEvaluator {
    public static func assess(
        _ snapshot: CaptureHealthSnapshot,
        now: Date = Date(),
        inputIdleThreshold: TimeInterval = 120,
        expectedInputGrace: TimeInterval = 8,
        contextFailureFreshness: TimeInterval = 15
    ) -> CaptureHealthAssessment {
        if snapshot.isManuallyPaused {
            return CaptureHealthAssessment(
                state: .paused,
                detail: "Capture is intentionally paused. Existing history remains readable.",
                captureProven: snapshot.inputCallbackObservedThisLaunch == true
            )
        }

        if let suppression = snapshot.currentSuppressionReason,
            [.excludedApplication, .excludedDomain, .privateBrowserWindow, .secureInput].contains(suppression)
        {
            return CaptureHealthAssessment(
                state: .excludedPrivateOrSecure,
                detail: "Detailed capture is intentionally suppressed: \(suppression.rawValue).",
                captureProven: snapshot.inputCallbackObservedThisLaunch == true
            )
        }

        let buildChanged = snapshot.lastKnownWorkingBuild.map {
            !$0.hasSamePermissionIdentity(as: snapshot.build)
        } ?? false
        let expectedInputMissed: Bool = {
            guard let expected = snapshot.expectedInputAfter,
                now.timeIntervalSince(expected) >= expectedInputGrace
            else { return false }
            guard let input = snapshot.lastInputEventAt else { return true }
            return input < expected
        }()

        if snapshot.build.signatureKind == .adHoc,
            buildChanged,
            snapshot.permissions.accessibilityPreflight,
            (!snapshot.permissions.accessibilityFunctionalProbe || expectedInputMissed)
        {
            return CaptureHealthAssessment(
                state: .permissionAppearsEnabledButStaleForBuild,
                detail: "macOS still shows approval, but this ad-hoc build has a different code identity and the controlled probe did not work.",
                captureProven: false,
                limitations: [
                    "Ad-hoc updates can require a new Accessibility or Input Monitoring approval.",
                    "Existing recorded data remains available.",
                ]
            )
        }

        if !snapshot.permissions.accessibilityPreflight {
            return CaptureHealthAssessment(
                state: .permissionRequired,
                detail: "Accessibility is not enabled for the running app copy.",
                captureProven: false
            )
        }

        switch snapshot.eventTapLifecycle {
        case .creationFailed:
            return CaptureHealthAssessment(
                state: .inputTapUnavailable,
                detail: snapshot.eventTapLastError ?? "The Core Graphics event tap could not be created.",
                captureProven: false
            )
        case .createdDisabled:
            return CaptureHealthAssessment(
                state: .inputTapUnavailable,
                detail: snapshot.eventTapLastError ?? "The Core Graphics event tap is disabled.",
                captureProven: snapshot.inputCallbackObservedThisLaunch == true
            )
        case .neverAttempted:
            return CaptureHealthAssessment(
                state: .inputTapUnavailable,
                detail: "The recorder has not attempted to create its input tap yet.",
                captureProven: false
            )
        case .createdEnabled:
            break
        }

        if !snapshot.permissions.accessibilityFunctionalProbe {
            return CaptureHealthAssessment(
                state: .accessibilityContextUnavailable,
                detail: "Accessibility appears enabled, but the running process cannot read the focused application.",
                captureProven: snapshot.inputCallbackObservedThisLaunch == true
            )
        }

        if let failure = snapshot.lastAXContextFailureAt,
            now.timeIntervalSince(failure) <= contextFailureFreshness,
            (snapshot.lastAXContextSuccessAt == nil || failure > snapshot.lastAXContextSuccessAt!)
        {
            return CaptureHealthAssessment(
                state: .accessibilityContextUnavailable,
                detail: "The latest foreground-context lookup failed even though Accessibility is enabled.",
                captureProven: snapshot.inputCallbackObservedThisLaunch == true
            )
        }

        if expectedInputMissed {
            return CaptureHealthAssessment(
                state: .inputTapUnavailable,
                detail: "A controlled input validation was requested, but no callback arrived afterward.",
                captureProven: false
            )
        }

        guard snapshot.inputCallbackObservedThisLaunch == true,
            let input = snapshot.lastInputEventAt
        else {
            let historical = snapshot.lastInputEventAt.map {
                " The last persisted callback was at \($0), but it came from an earlier launch."
            } ?? ""
            return CaptureHealthAssessment(
                state: .awaitingInputEvidence,
                detail: "The tap exists, but no real input callback has reached this process yet." + historical,
                captureProven: false,
                limitations: ["Tap creation and historical callbacks do not prove this process is receiving input."]
            )
        }

        let idleSeconds = max(0, now.timeIntervalSince(input))
        if idleSeconds > inputIdleThreshold {
            return CaptureHealthAssessment(
                state: .healthyButIdle,
                detail: "A real callback was previously observed; no input has arrived for \(Int(idleSeconds)) seconds.",
                captureProven: true
            )
        }

        return CaptureHealthAssessment(
            state: .ready,
            detail: "Accessibility context and real Core Graphics input callbacks are working for this process.",
            captureProven: true
        )
    }
}

/// Thread-safe, in-memory evidence accumulator. The macOS target can persist its
/// snapshots atomically as `capture-health.json`; keeping this logic in Core makes
/// the state machine deterministic and testable without TCC.
public final class CaptureHealthAccumulator {
    private struct TimedKind {
        let timestamp: Date
        let kind: String
    }

    private let lock = NSLock()
    private let launchedAt: Date
    private let build: CaptureBuildIdentity
    private var lastKnownWorkingBuild: CaptureBuildIdentity?
    private var permissions: CapturePermissionObservation
    private var lifecycle: CaptureEventTapLifecycle = .neverAttempted
    private var tapLastError: String?
    private var tapLastEnabledAt: Date?
    private var tapLastDisabledAt: Date?
    private var lastCallbackAt: Date?
    private var lastInputEventAt: Date?
    private var lastClickAt: Date?
    private var lastTypingBurstAt: Date?
    private var lastScrollAt: Date?
    private var lastShortcutAt: Date?
    private var lastAXSuccessAt: Date?
    private var lastAXFailureAt: Date?
    private var lastURLAt: Date?
    private var lastSuppressionAt: Date?
    private var lastSuppressionReason: SuppressionReason?
    private var currentSuppressionReason: SuppressionReason?
    private var paused = false
    private var expectedInputAfter: Date?
    private var inputCallbackObservedThisLaunch = false
    private var recentKinds: [TimedKind] = []

    public init(
        launchedAt: Date = Date(),
        build: CaptureBuildIdentity,
        lastKnownWorkingBuild: CaptureBuildIdentity? = nil,
        permissions: CapturePermissionObservation,
        restoring previous: CaptureHealthSnapshot? = nil
    ) {
        self.launchedAt = launchedAt
        self.build = build
        self.lastKnownWorkingBuild = lastKnownWorkingBuild
            ?? previous?.lastKnownWorkingBuild
            ?? (previous?.lastInputEventAt == nil ? nil : previous?.build)
        self.permissions = permissions
        lastCallbackAt = previous?.lastCallbackAt
        lastInputEventAt = previous?.lastInputEventAt
        lastClickAt = previous?.lastClickAt
        lastTypingBurstAt = previous?.lastTypingBurstAt
        lastScrollAt = previous?.lastScrollAt
        lastShortcutAt = previous?.lastShortcutAt
        lastAXSuccessAt = previous?.lastAXContextSuccessAt
        lastAXFailureAt = previous?.lastAXContextFailureAt
        lastURLAt = previous?.lastURLDetectedAt
        lastSuppressionAt = previous?.lastSuppressionAt
        lastSuppressionReason = previous?.lastSuppressionReason
        // A prior process is evidence for history and stale-build diagnosis only.
        // The new process must receive its own callback before becoming Ready.
        inputCallbackObservedThisLaunch = false
    }

    public func updatePermissions(_ value: CapturePermissionObservation) {
        withLock { permissions = value }
    }

    public func markTapCreationFailed(_ error: String, at date: Date = Date()) {
        withLock {
            lifecycle = .creationFailed
            tapLastError = error
            tapLastDisabledAt = date
        }
    }

    public func markTapEnabled(at date: Date = Date()) {
        withLock {
            lifecycle = .createdEnabled
            tapLastError = nil
            tapLastEnabledAt = date
        }
    }

    public func markTapDisabled(_ error: String?, at date: Date = Date()) {
        withLock {
            lifecycle = .createdDisabled
            tapLastError = error
            tapLastDisabledAt = date
        }
    }

    public func expectUserInput(after date: Date = Date()) {
        withLock { expectedInputAfter = date }
    }

    /// Records delivery of a real user-input callback without yet claiming that a
    /// grouped event has been persisted. Scroll and typing callbacks may later become
    /// one burst, so counters are updated only by `markRecordedEvent`.
    public func markInputCallback(at date: Date = Date()) {
        withLock {
            lastCallbackAt = date
            lastInputEventAt = date
            inputCallbackObservedThisLaunch = true
            if lifecycle == .createdEnabled { lastKnownWorkingBuild = build }
            if let expectedInputAfter, date >= expectedInputAfter {
                self.expectedInputAfter = nil
            }
            prune(now: date)
        }
    }

    /// Records a control callback such as `tapDisabledByTimeout`. It proves the Mach
    /// port delivered a callback, but not that a click/key/scroll reached the recorder.
    public func markTapControlCallback(at date: Date = Date()) {
        withLock {
            lastCallbackAt = date
            prune(now: date)
        }
    }

    /// Records the event kind actually persisted after grouping and privacy checks.
    public func markRecordedEvent(kind: EventKind, at date: Date = Date()) {
        withLock {
            switch kind {
            case .mouseClick: lastClickAt = date
            case .typingBurst: lastTypingBurstAt = date
            case .scrollBurst: lastScrollAt = date
            case .keyboardShortcut, .keyPressed: lastShortcutAt = date
            default: break
            }
            recentKinds.append(TimedKind(timestamp: date, kind: kind.rawValue))
            prune(now: date)
        }
    }

    /// Convenience for tests and direct, ungrouped events.
    public func markCallback(kind: EventKind?, at date: Date = Date()) {
        markInputCallback(at: date)
        if let kind { markRecordedEvent(kind: kind, at: date) }
    }

    public func markAXSuccess(urlAvailable: Bool, at date: Date = Date()) {
        withLock {
            lastAXSuccessAt = date
            if urlAvailable { lastURLAt = date }
        }
    }

    public func markAXFailure(at date: Date = Date()) {
        withLock { lastAXFailureAt = date }
    }

    public func setSuppression(_ reason: SuppressionReason?, at date: Date = Date()) {
        withLock {
            currentSuppressionReason = reason
            if let reason {
                lastSuppressionAt = date
                lastSuppressionReason = reason
            }
        }
    }

    public func setPaused(_ value: Bool) {
        withLock { paused = value }
    }

    public func snapshot(now: Date = Date(), windowSeconds: Int = 300) -> CaptureHealthSnapshot {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now, windowSeconds: windowSeconds)
        var counts: [String: Int] = [:]
        for item in recentKinds { counts[item.kind, default: 0] += 1 }
        return CaptureHealthSnapshot(
            generatedAt: now,
            launchedAt: launchedAt,
            build: build,
            lastKnownWorkingBuild: lastKnownWorkingBuild,
            permissions: permissions,
            eventTapLifecycle: lifecycle,
            eventTapLastError: tapLastError,
            eventTapLastEnabledAt: tapLastEnabledAt,
            eventTapLastDisabledAt: tapLastDisabledAt,
            lastCallbackAt: lastCallbackAt,
            lastInputEventAt: lastInputEventAt,
            lastClickAt: lastClickAt,
            lastTypingBurstAt: lastTypingBurstAt,
            lastScrollAt: lastScrollAt,
            lastShortcutAt: lastShortcutAt,
            lastAXContextSuccessAt: lastAXSuccessAt,
            lastAXContextFailureAt: lastAXFailureAt,
            lastURLDetectedAt: lastURLAt,
            lastSuppressionAt: lastSuppressionAt,
            lastSuppressionReason: lastSuppressionReason,
            currentSuppressionReason: currentSuppressionReason,
            isManuallyPaused: paused,
            recentCounters: CaptureRecentCounters(windowSeconds: windowSeconds, byEventKind: counts),
            expectedInputAfter: expectedInputAfter,
            inputCallbackObservedThisLaunch: inputCallbackObservedThisLaunch
        )
    }

    private func withLock(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    private func prune(now: Date, windowSeconds: Int = 300) {
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, windowSeconds)))
        recentKinds.removeAll { $0.timestamp < cutoff }
    }
}
