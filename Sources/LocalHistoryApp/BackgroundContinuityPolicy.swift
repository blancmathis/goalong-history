import Foundation

/// Availability preferences never grant a recording or sharing capability.
struct BackgroundContinuityPreferences {
    static let keepRunningKey = "goalong.keepRunningInBackground.v1"
    static let manualPauseKey = "goalong.recordingManuallyPaused.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var keepRunning: Bool {
        get { defaults.object(forKey: Self.keepRunningKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.keepRunningKey) }
    }

    var manuallyPaused: Bool {
        get { defaults.bool(forKey: Self.manualPauseKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.manualPauseKey) }
    }

    static func suggestedLoginPreference(
        storedPreference: Bool?, consentEnabled: Bool, consentWasRecorded: Bool,
        systemEnabled: Bool
    ) -> Bool {
        if consentWasRecorded { return consentEnabled }
        if let storedPreference { return storedPreference }
        if consentEnabled || systemEnabled { return true }
        // A visible, preselected onboarding choice, not a registration side effect.
        return true
    }

    static func shouldConfirmQuit(keepRunning: Bool, hasEnabledSources: Bool) -> Bool {
        keepRunning && hasEnabledSources
    }
}

/// One bounded, local technical record. It contains no captured activity and cannot
/// distinguish a crash from a power loss or forced termination.
struct BackgroundSessionJournal {
    static let runningKey = "goalong.runtime.sessionOpen.v1"
    static let heartbeatKey = "goalong.runtime.lastHeartbeat.v1"
    static let exitReasonKey = "goalong.runtime.lastExitReason.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func begin(now: Date = Date()) -> Bool {
        let interrupted = defaults.bool(forKey: Self.runningKey)
        defaults.set(true, forKey: Self.runningKey)
        heartbeat(now: now)
        return interrupted
    }

    func heartbeat(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.heartbeatKey)
    }

    func finish(reason: String, now: Date = Date()) {
        heartbeat(now: now)
        defaults.set(false, forKey: Self.runningKey)
        defaults.set(reason, forKey: Self.exitReasonKey)
    }
}
