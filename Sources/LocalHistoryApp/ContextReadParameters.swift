#if os(macOS)
import AppKit
import Foundation
import LocalHistoryCore

/// An atomic view taken by the main-owned workspace bridge. Readers receive no
/// NSRunningApplication and never need to synchronize with the main queue.
struct ForegroundAXApplication {
    let processIdentifier: pid_t
    let localizedName: String?
    let bundleIdentifier: String?
    let instanceStartedAt: Date?
    let isTerminated: Bool
    let regular: Bool

    init(_ application: NSRunningApplication) {
        processIdentifier = application.processIdentifier
        localizedName = application.localizedName
        bundleIdentifier = application.bundleIdentifier
        instanceStartedAt = application.launchDate
        isTerminated = application.isTerminated
        regular = application.activationPolicy == .regular
    }

    init(pid: pid_t, name: String, bundleIdentifier: String?, instanceStartedAt: Date? = nil,
         isTerminated: Bool = false, regular: Bool = true) {
        self.processIdentifier = pid
        self.localizedName = name
        self.bundleIdentifier = bundleIdentifier
        self.instanceStartedAt = instanceStartedAt
        self.isTerminated = isTerminated
        self.regular = regular
    }
}

struct ContextReadParameters {
    let foregroundApplication: ForegroundAXApplication?
    let applications: [pid_t: ForegroundAXApplication]
    let config: RecorderConfig
    let accessibilityAvailable: Bool
    let blockingAXTrusted: Bool
    let sessionAvailable: Bool
    let idleSeconds: TimeInterval
    let privacy: GoalongPrivacyPolicy
    let pauseRevision: String?
}

/// All effects of a context read are values applied by the facade continuation.
struct ContextReadResult {
    let snapshot: ContextSnapshot?
    let privateWindowUpdate: Bool?
    let provedExternalAX: Bool
    let discoveredBrowser: AppSnapshot?
}
#endif
