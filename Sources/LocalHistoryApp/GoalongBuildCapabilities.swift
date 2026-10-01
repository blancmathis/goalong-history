#if os(macOS)
    import Foundation

    enum GoalongBuildEdition: String, Codable, CaseIterable {
        case unified

        var displayName: String {
            "App unique"
        }
    }

    /// Compile-time capability inventory for the single public application.
    /// Sparkle authenticates release feeds and archives; the retired commitment uploader is absent. The only
    /// first-party HTTP transport is the explicitly requested website submission. The
    /// optional ChatGPT feature delegates transport and credentials to the user's
    /// separately installed Codex runtime after an explicit Goalong consent.
    enum GoalongBuildCapabilities {
        static let edition: GoalongBuildEdition = .unified
        static let permitsFirstPartyNetworking = true
        static let permitsRemoteVerification = false
        static let permitsRemoteAnalysis = true
        static let permitsAutomaticUpdates = true
        static let permitsHTTPWorkspaceOpening = true

        static var summary: String {
            "Une seule app Goalong · collecte locale désactivée par défaut · envois au site sur demande ou programmés · mises à jour signées, installées avec votre accord"
        }
    }
#endif
