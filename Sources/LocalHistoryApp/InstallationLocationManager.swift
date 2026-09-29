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
                "Goalong History doit se trouver dans Applications pour que les autorisations, l’ouverture à la connexion et les mises à jour fonctionnent de façon fiable. Le déplacer maintenant ?"
            alert.addButton(withTitle: "Déplacer et continuer")
            alert.addButton(withTitle: "Quitter")

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
                failure.messageText = "Goalong History n’a pas pu être déplacé"
                failure.informativeText =
                    "\(error.localizedDescription) Copiez Goalong History dans votre dossier Applications, puis ouvrez cette copie. Aucune donnée n’a encore été créée."
                failure.addButton(withTitle: "Afficher Applications")
                failure.addButton(withTitle: "Quitter")
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
                return "Une autre application occupe déjà l’emplacement de Goalong History."
            case .couldNotRelaunch:
                return "La copie de l’application n’a pas pu être ouverte."
            }
        }
    }
#endif
