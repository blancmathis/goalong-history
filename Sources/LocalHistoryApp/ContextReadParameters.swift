#if os(macOS)
import AppKit
import Carbon
import ApplicationServices
import Foundation
import LocalHistoryCore

/// An atomic view taken by the main-owned workspace bridge. Readers receive no
/// NSRunningApplication and never need to synchronize with the main queue.
struct ForegroundAXApplication: Equatable {
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
    var secureInputEnabled: Bool = false
    var permissionRevision: UInt64 = 0
    /// Explicit blocking rules only. The history reader never uses this field.
    var blockingKeywords: [String] = []

    func hasSameAuthority(as other: Self) -> Bool {
        foregroundApplication == other.foregroundApplication && config == other.config
            && accessibilityAvailable == other.accessibilityAvailable
            && blockingAXTrusted == other.blockingAXTrusted
            && sessionAvailable == other.sessionAvailable
            && secureInputEnabled == other.secureInputEnabled
            && privacy == other.privacy && pauseRevision == other.pauseRevision
            && permissionRevision == other.permissionRevision
    }
}

/// All effects of a context read are values applied by the facade continuation.
struct ContextReadResult {
    let snapshot: ContextSnapshot?
    let privateWindowUpdate: Bool?
    let provedExternalAX: Bool
    let discoveredBrowser: AppSnapshot?
    var boundary: AXReadBoundary? = nil
}

/// Internal evidence, never encoded into history. Retains equality identities;
/// a title, PID or CFHash is not used as the identity of a window.
final class AXReadBoundary: Equatable {
    private let window: AXUIElement
    private let pid: pid_t
    init(window: AXUIElement, pid: pid_t) { self.window = window; self.pid = pid }
    static func == (lhs: AXReadBoundary, rhs: AXReadBoundary) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.window, rhs.window)
    }
    func matchesFocusedWindow(allowMainWindow: Bool = false) -> Bool {
        let app = AXAccess.application(pid)
        guard let current = AXReader.focusedWindow(for: app)
            ?? (allowMainWindow ? AXReader.element(app, attribute: kAXMainWindowAttribute as CFString) : nil) else { return false }
        return CFEqual(window, current)
    }
}

struct AXContextEvidence {
    let snapshot: ContextSnapshot
    let boundary: AXReadBoundary?
}

struct AXInputRead {
    let suppression: SuppressionReason?
    let element: ElementSnapshot?
}
#endif
