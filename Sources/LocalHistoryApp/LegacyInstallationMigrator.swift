#if os(macOS)
    import AppKit
    import Foundation
    import ServiceManagement

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
            removeLegacyApplicationCopiesIfSafe()
        }

        private static func migrateOnboardingState() {
            let defaults = UserDefaults.standard
            let migrationKey = "didPrepareLocalHistoryConsentOnboardingV5"
            guard !defaults.bool(forKey: migrationKey) else { return }
            defaults.removeObject(forKey: "didShowLocalHistoryConsentOnboardingV5")
            defaults.set(false, forKey: "chatgptRecap.automaticEnabled")
            defaults.set(false, forKey: ActivityAnalysisPreferences.richContextEnabledKey)
            defaults.set(false, forKey: "launchAtLoginPreference")
            if SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval
            {
                try? SMAppService.mainApp.unregister()
            }
            defaults.set(true, forKey: migrationKey)
        }

        private static func removeLegacyLaunchAgent() {
            let fileManager = FileManager.default
            let legacyURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(bundleIdentifier).plist")
            try? fileManager.removeItem(at: legacyURL)
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
                    Bundle(url: legacyURL)?.bundleIdentifier == bundleIdentifier
                else {
                    continue
                }
                try? fileManager.removeItem(at: legacyURL)
            }
        }
    }
#endif
