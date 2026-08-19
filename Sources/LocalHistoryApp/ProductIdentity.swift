#if os(macOS)
    import Foundation

    enum ProductIdentity {
        static let fallbackDisplayName = "Go Long History"
        static let internalBundleName = "LocalHistory"
        static let bundleIdentifier = "ai.goalong.localhistory"

        static var displayName: String {
            let candidates = [
                Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            ]
            return candidates
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && $0 != internalBundleName })
                ?? fallbackDisplayName
        }

        static let rollingReleaseTag = "latest-main"
        static let rollingReleasePageURL = URL(
            string: "https://github.com/blancmathis/goalong-history/releases/tag/\(rollingReleaseTag)"
        )!
        static let rollingDMGURL = URL(
            string:
                "https://github.com/blancmathis/goalong-history/releases/download/\(rollingReleaseTag)/LocalHistory-macOS-universal.dmg"
        )!

        static var installationPath: String {
            Bundle.main.bundleURL.path
        }
    }
#endif
