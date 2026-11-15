import AppleScreenTime
#if os(macOS)
    import AppKit
    import Foundation
    import LocalHistoryCore
    import ServiceManagement

    enum LegacyInstallationMigrator {
        private static let bundleIdentifier = GoalongBundleIdentity.release

        static func run() {
            // Local iteration shares the production identity/data, never installation cleanup.
            guard Bundle.main.object(forInfoDictionaryKey: "GoalongDevelopmentBuild") as? Bool != true else { return }
            migrateOnboardingState()

            removeLegacyLaunchAgent()
            removeLegacyApplicationCopiesIfSafe()
        }

        private static func migrateOnboardingState() {
            let defaults = GoalongDefaults.standard
            let migrationKey = "didPrepareLocalHistoryConsentOnboardingV5"
            guard !defaults.bool(forKey: migrationKey) else { return }
            defaults.removeObject(forKey: "didShowLocalHistoryConsentOnboardingV5")
            defaults.set(false, forKey: "chatgptRecap.automaticEnabled")
            if !GoalongRecordingSetup.hasReviewedChoices(defaults: defaults) {
                defaults.set(false, forKey: ActivityAnalysisPreferences.richContextEnabledKey)
            }
            // Refresh privacy onboarding without revoking the existing native login item.
            defaults.set(true, forKey: migrationKey)
        }

        private static func removeLegacyLaunchAgent() {
            let fileManager = FileManager.default
            let legacyURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(bundleIdentifier).plist")
            // No launchctl bootout here: the privacy audit bans spawning tools from this file
            // (T-064 question: allow a fixed /bin/launchctl bootout boundary?).
            try? fileManager.removeItem(at: legacyURL)
        }

        /// True when `candidate` is not newer than `current`, comparing dotted numeric build numbers
        /// component by component. An unreadable version is never "not newer" (keep the copy).
        static func isNotNewer(candidate: String?, than current: String?) -> Bool {
            func parts(_ raw: String?) -> [Int]? {
                guard let raw, !raw.isEmpty else { return nil }
                let numbers = raw.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
                return numbers.contains(where: { $0 == nil }) ? nil : numbers.compactMap { $0 }
            }
            guard let lhs = parts(candidate), let rhs = parts(current) else { return false }
            for index in 0..<max(lhs.count, rhs.count) {
                let l = index < lhs.count ? lhs[index] : 0
                let r = index < rhs.count ? rhs[index] : 0
                if l != r { return l < r }
            }
            return true
        }

        private static func isRunning(bundleURL: URL) -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains { $0.bundleURL?.standardizedFileURL == bundleURL }
        }

        private static func removeLegacyApplicationCopiesIfSafe() {
            let fileManager = FileManager.default
            let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
            let legacyURLs = [
                URL(fileURLWithPath: "/Applications/LocalHistory.app", isDirectory: true),
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/LocalHistory.app", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Go Long History.app", isDirectory: true),
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Go Long History.app", isDirectory: true),
                URL(fileURLWithPath: "/Applications/GoLong History.app", isDirectory: true),
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/GoLong History.app", isDirectory: true),
            ]

            for legacyURL in legacyURLs.map(\.standardizedFileURL) {
                guard currentBundleURL != legacyURL,
                    fileManager.fileExists(atPath: legacyURL.path),
                    let legacyBundle = Bundle(url: legacyURL),
                    legacyBundle.bundleIdentifier == bundleIdentifier,
                    isNotNewer(
                        candidate: legacyBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                        than: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
                    !isRunning(bundleURL: legacyURL)
                else {
                    continue
                }
                try? fileManager.removeItem(at: legacyURL)
            }
        }
    }
#endif
