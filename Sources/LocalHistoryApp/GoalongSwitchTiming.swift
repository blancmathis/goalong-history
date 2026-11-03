#if os(macOS)
import Foundation
import os

/// R13a: one light line per view change, at debug level (not kept on disk). Read it live with
/// `log stream --level debug --predicate 'category == "view-switch"'`.
/// It carries a view name from a fixed list and a duration, never any content.
enum GoalongSwitchTiming {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                                       category: "view-switch")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started: [String: TimeInterval] = [:]

    /// The click: `view` is a section raw value or `activite-<n>j`.
    static func begin(_ view: String) {
        lock.withLock { started[view] = ProcessInfo.processInfo.systemUptime }
    }

    /// The user left `view` before its measure closed: nothing is logged for it.
    static func cancel(_ view: String) {
        lock.withLock { started[view] = nil }
    }

    /// `shown` when the page appears, `data` when its data are in. `last` closes the measure.
    static func end(_ view: String, stage: String, last: Bool) {
        let start: TimeInterval? = lock.withLock {
            defer { if last { started[view] = nil } }
            return started[view]
        }
        guard let start else { return }
        let ms = Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded())
        logger.debug("switch \(view, privacy: .public) \(stage, privacy: .public) \(ms, privacy: .public) ms")
    }
}
#endif
