#if os(macOS)
    import Foundation

    enum GoalongBuildEdition: String, Codable, CaseIterable {
        case unified

        var displayName: String {
            "Single app"
        }
    }

    /// Compile-time capability inventory for the single public application.
    /// Sparkle and Goalong's first-party HTTP uploader are physically absent. The
    /// optional ChatGPT feature delegates transport and credentials to the user's
    /// separately installed Codex runtime after an explicit Goalong consent.
    enum GoalongBuildCapabilities {
        static let edition: GoalongBuildEdition = .unified
        static let permitsFirstPartyNetworking = false
        static let permitsRemoteVerification = false
        static let permitsRemoteAnalysis = true
        static let permitsAutomaticUpdates = false
        static let permitsHTTPWorkspaceOpening = true

        static var summary: String {
            "One Goalong app · local collection off by default · no Sparkle or first-party HTTP uploader"
        }
    }
#endif
