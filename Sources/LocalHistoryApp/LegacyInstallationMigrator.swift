#if os(macOS)
    import AppKit
    import Foundation

    enum LegacyInstallationMigrator {
        private static let bundleIdentifier = "ai.goalong.localhistory"

        static func run() {
            migrateOnboardingState()

            let currentPID = ProcessInfo.processInfo.processIdentifier
            let otherInstances = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.processIdentifier != currentPID && !$0.isTerminated }

            for application in otherInstances {
                _ = application.terminate()
            }

            if !otherInstances.isEmpty {
                let deadline = Date().addingTimeInterval(1.2)
                while Date() < deadline, otherInstances.contains(where: { !$0.isTerminated }) {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }

            removeLegacyLaunchAgent()
            removeDuplicateUserApplicationIfSafe()
        }

        private static func migrateOnboardingState() {
            let defaults = UserDefaults.standard
            let migrationKey = "didPrepareLocalHistoryOnboardingV4"
            guard !defaults.bool(forKey: migrationKey) else { return }
            defaults.removeObject(forKey: "didShowLocalHistoryOnboardingV3")
            defaults.set(true, forKey: migrationKey)
        }

        private static func removeLegacyLaunchAgent() {
            let fileManager = FileManager.default
            let legacyURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(bundleIdentifier).plist")
            try? fileManager.removeItem(at: legacyURL)
        }

        private static func removeDuplicateUserApplicationIfSafe() {
            let fileManager = FileManager.default
            let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
            let oldURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/LocalHistory.app")
                .standardizedFileURL

            guard currentBundleURL != oldURL,
                fileManager.fileExists(atPath: oldURL.path),
                Bundle(url: oldURL)?.bundleIdentifier == bundleIdentifier
            else {
                return
            }

            try? fileManager.removeItem(at: oldURL)
        }
    }
#endif
