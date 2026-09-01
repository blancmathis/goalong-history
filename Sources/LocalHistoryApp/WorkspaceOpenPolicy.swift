#if os(macOS)
    import AppKit
    import Foundation

    enum GoalongWorkspaceOpenPurpose: Equatable {
        case localFile
        case systemSettings
        case observedWebsite
        case accountAuthorization
        case updatePage
        case documentation
    }

    /// Single reviewed LaunchServices boundary. The unified app accepts only
    /// local files and Apple's System Settings scheme; HTTP(S) is rejected before
    /// it reaches NSWorkspace.
    enum GoalongWorkspaceOpenPolicy {
        private static let systemSettingsScheme = "x-apple.systempreferences"
        private static let reviewedDocumentationHosts: Set<String> = [
            "developer.apple.com",
            "developers.openai.com",
            "github.com",
            "support.apple.com",
        ]

        @discardableResult
        static func open(_ url: URL, purpose: GoalongWorkspaceOpenPurpose) -> Bool {
            guard permits(url, purpose: purpose) else { return false }
            return NSWorkspace.shared.open(url)
        }

        static func permits(_ url: URL, purpose: GoalongWorkspaceOpenPurpose) -> Bool {
            if url.isFileURL { return purpose == .localFile }

            let scheme = url.scheme?.lowercased()
            if scheme == systemSettingsScheme { return purpose == .systemSettings }

            guard GoalongBuildCapabilities.permitsHTTPWorkspaceOpening,
                scheme == "https",
                url.user == nil,
                url.password == nil,
                url.port == nil || url.port == 443,
                let host = url.host?.lowercased(),
                !host.isEmpty
            else { return false }

            switch purpose {
            case .observedWebsite:
                return true
            case .accountAuthorization:
                return host == "auth.openai.com" || host.hasSuffix(".openai.com")
            case .updatePage:
                return host == "github.com"
            case .documentation:
                return reviewedDocumentationHosts.contains(host)
            case .localFile, .systemSettings:
                return false
            }
        }
    }
#endif
