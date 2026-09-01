#if os(macOS)
    import AppKit
    import Foundation

    enum InstallationLocationManager {
        private static let appName = "Goalong History.app"
        private static let bundleIdentifier = "ai.goalong.localhistory"

        /// Returns true when the current process should exit because the user quit
        /// or a relocated copy was launched.
        static func handleTransientLaunchIfNeeded() -> Bool {
            let source = Bundle.main.bundleURL.standardizedFileURL
            guard isTransient(source) else { return false }

            NSApplication.shared.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Finish installing Goalong History"
            alert.informativeText =
                "Goalong History should live in Applications so permissions, start-at-login, and updates keep working reliably. Move it there now?"
            alert.addButton(withTitle: "Move and Continue")
            alert.addButton(withTitle: "Quit")

            guard alert.runModal() == .alertFirstButtonReturn else { return true }

            do {
                let destination = try preferredDestination()
                try replaceApplication(at: destination, with: source)
                guard GoalongWorkspaceOpenPolicy.open(destination, purpose: .localFile) else {
                    throw InstallationError.couldNotRelaunch
                }
                return true
            } catch {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "Goalong History could not be moved"
                failure.informativeText =
                    "\(error.localizedDescription) Copy Goalong History to your Applications folder, then open that copy. No data has been created yet."
                failure.addButton(withTitle: "Show Applications")
                failure.addButton(withTitle: "Quit")
                if failure.runModal() == .alertFirstButtonReturn {
                    GoalongWorkspaceOpenPolicy.open(
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                        purpose: .localFile
                    )
                }
                return true
            }
        }

        private static func isTransient(_ bundleURL: URL) -> Bool {
            let path = bundleURL.path
            return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
        }

        private static func preferredDestination() throws -> URL {
            let fileManager = FileManager.default
            let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let systemTarget = systemApplications.appendingPathComponent(appName, isDirectory: true)

            if fileManager.isWritableFile(atPath: systemApplications.path), canReplace(systemTarget) {
                return systemTarget
            }

            let userApplications = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
            try fileManager.createDirectory(
                at: userApplications,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            return userApplications.appendingPathComponent(appName, isDirectory: true)
        }

        private static func canReplace(_ destination: URL) -> Bool {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: destination.path) else { return true }
            return Bundle(url: destination)?.bundleIdentifier == bundleIdentifier
                && fileManager.isWritableFile(atPath: destination.path)
        }

        private static func replaceApplication(at destination: URL, with source: URL) throws {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                guard Bundle(url: destination)?.bundleIdentifier == bundleIdentifier else {
                    throw InstallationError.destinationOccupied
                }
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private enum InstallationError: LocalizedError {
        case destinationOccupied
        case couldNotRelaunch

        var errorDescription: String? {
            switch self {
            case .destinationOccupied:
                return "Another application already uses the Goalong History destination."
            case .couldNotRelaunch:
                return "The copied application could not be opened."
            }
        }
    }
#endif
