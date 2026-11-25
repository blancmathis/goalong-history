#if os(macOS)
    import AppKit
    import Foundation
    import LocalHistoryQueryCLI

    enum GoalongWorkspaceOpenPurpose: Equatable {
        case localFile
        case systemSettings
        case observedWebsite
        case accountAuthorization
        case updatePage
        case documentation
        case goalongWebsite
        case plannedContext
    }

    /// Single reviewed LaunchServices boundary. The unified app accepts only
    /// local files, Apple's System Settings scheme, reviewed HTTPS purposes and the
    /// explicitly configured Goalong website (HTTPS or development loopback only).
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

            if purpose == .goalongWebsite {
                guard GoalongBuildCapabilities.permitsHTTPWorkspaceOpening,
                      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      parts.path == "/goalong.dc.html", parts.fragment == "sources", parts.query == nil else { return false }
                parts.path = ""
                parts.fragment = nil
                guard let origin = parts.string else { return false }
                return (try? GoalongSiteSubmission.endpoint(origin: origin)) != nil
            }

            // A saved plan link opens only after an explicit click. Custom app schemes have
            // no reviewed handler yet; local Context Room URLs stay on exact loopback hosts.
            if purpose == .plannedContext {
                guard GoalongBuildCapabilities.permitsHTTPWorkspaceOpening,
                      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      parts.user == nil, parts.password == nil,
                      let host = parts.host?.lowercased(), !host.isEmpty,
                      parts.port.map({ (1...65535).contains($0) }) ?? true else { return false }
                if scheme == "https" { return parts.port == nil || parts.port == 443 }
                return scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
            }

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
                return host == "auth.openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com"
            case .updatePage:
                return host == "github.com"
            case .documentation:
                return reviewedDocumentationHosts.contains(host)
            case .localFile, .systemSettings, .goalongWebsite, .plannedContext:
                return false
            }
        }
    }
#endif
