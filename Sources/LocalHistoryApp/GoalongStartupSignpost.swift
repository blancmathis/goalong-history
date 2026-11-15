#if os(macOS)
    import Foundation
    import os

    /// T-064 lot 10: startup intervals (category « startup ») so a launch can be measured in Instruments
    /// (« os_signpost ») or with `log stream --signpost`. Names only, never a path or a value.
    enum GoalongStartupSignpost {
        static let signposter = OSSignposter(
            subsystem: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory", category: "startup")

        @discardableResult
        static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
            let state = signposter.beginInterval(name)
            defer { signposter.endInterval(name, state) }
            return try body()
        }
    }
#endif
