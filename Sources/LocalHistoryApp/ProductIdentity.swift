#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum ProductIdentity {
        static let canonicalDisplayName = "Goalong History"
        static let fallbackDisplayName = canonicalDisplayName
        static let internalBundleName = "LocalHistory"
        static let bundleIdentifier = "ai.goalong.localhistory"

        private static let legacyOrTechnicalNames: Set<String> = [
            internalBundleName,
            "Go Long History",
            "GoLong History",
        ]

        static var displayName: String {
            let candidates = [
                Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            ]
            return candidates
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && !legacyOrTechnicalNames.contains($0) })
                ?? canonicalDisplayName
        }

        /// Window titles end with " — Dev" in the `make dev` copy only.
        static func windowTitle(_ title: String) -> String { GoalongBuildChannel.current.windowTitle(title) }
        static var mainWindowTitle: String {
            GoalongBuildChannel.current.isDevelopment ? windowTitle(canonicalDisplayName) : displayName
        }

        static let rollingReleaseTag = "latest-main"
        static let rollingReleasePageURL = URL(
            string: "https://github.com/blancmathis/goalong-history/releases/tag/\(rollingReleaseTag)"
        )!
        static let guideURL = URL(string: "https://github.com/blancmathis/goalong-history/blob/main/GUIDE_FR.md")!
        static var installationPath: String {
            Bundle.main.bundleURL.path
        }
    }
#endif
