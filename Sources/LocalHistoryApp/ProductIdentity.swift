#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum ProductIdentity {
        static let canonicalDisplayName = "Goalong History"
        static let fallbackDisplayName = canonicalDisplayName
        static let internalBundleName = "LocalHistory"
        /// This copy's own bundle ID: the release, or `ai.goalong.localhistory.dev` in Goalong Dev.
        static let bundleIdentifier = GoalongBundleIdentity.current
        /// True for any Goalong copy (release or Dev): never blocked, recorded or offered as a rule target.
        static func isGoalong(_ identifier: String) -> Bool { GoalongBundleIdentity.isGoalong(identifier) }

        private static let legacyOrTechnicalNames: Set<String> = [
            internalBundleName,
            "Go Long History",
            "GoLong History",
        ]

        #if DEBUG
        /// Test gallery only: a fixed name, version and bundle path, so renders do not show "xctest".
        struct GalleryIdentity: Equatable {
            var displayName = "Goalong"
            var version = "0.6.82 (galerie)"
            var bundlePath = "/Applications/Goalong.app"
        }
        static var galleryOverride: GalleryIdentity?
        #endif

        static var displayName: String {
            #if DEBUG
            if let galleryOverride { return galleryOverride.displayName }
            #endif
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
        static var installationPath: String { bundleURL.path }

        /// This copy's bundle (the gallery shows a fixed path).
        static var bundleURL: URL {
            #if DEBUG
            if let galleryOverride { return URL(fileURLWithPath: galleryOverride.bundlePath, isDirectory: true) }
            #endif
            return Bundle.main.bundleURL
        }

        /// Marketing version shown in the app (`CFBundleShortVersionString`).
        static var shortVersion: String? {
            #if DEBUG
            if let galleryOverride { return galleryOverride.version }
            #endif
            return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }
    }
#endif
