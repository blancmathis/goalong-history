#if os(macOS)
    import Foundation

    enum GoalongBuildEdition: String, Codable, CaseIterable {
        case unified

        var displayName: String {
            "Single app"
        }
    }

    /// Compile-time capability inventory for the single public application.
    /// Sparkle and the retired commitment uploader are physically absent. The only
    /// first-party HTTP transport is the explicitly requested website submission. The
    /// optional ChatGPT feature delegates transport and credentials to the user's
    /// separately installed Codex runtime after an explicit Goalong consent.
    enum GoalongBuildCapabilities {
        static let edition: GoalongBuildEdition = .unified
        static let permitsFirstPartyNetworking = true
        static let permitsRemoteVerification = false
        static let permitsRemoteAnalysis = true
        static let permitsAutomaticUpdates = false
        static let permitsHTTPWorkspaceOpening = true

        static var summary: String {
            "One Goalong app · local collection off by default · explicit website sends · no automatic sync or Sparkle"
        }
    }
#endif
