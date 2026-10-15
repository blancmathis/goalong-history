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
            alert.messageText = "Terminer l’installation de Goalong History"
            alert.informativeText =
                "Goalong History doit se trouver dans Applications pour que les autorisations, l’ouverture à la connexion et les mises à jour fonctionnent de façon fiable. Le déplacer maintenant ?"
            alert.addButton(withTitle: "Déplacer et continuer")
            alert.addButton(withTitle: "Quitter")

            guard alert.runModal() == .alertFirstButtonReturn else { return true }

            var attemptedDestination: URL?
            do {
                let destination = try preferredDestination()
                attemptedDestination = destination
                if replacementDecision(source: source, destination: destination) == .alreadyInstalled {
                    let installed = NSAlert()
                    installed.alertStyle = .informational
                    installed.messageText = "Goalong History est déjà dans Applications"
                    installed.informativeText =
                        "Cette fenêtre est une copie temporaire de macOS. Ouvrez Goalong History depuis votre dossier Applications."
                    installed.addButton(withTitle: "Afficher dans le Finder")
                    installed.addButton(withTitle: "Quitter")
                    if installed.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                    return true
                }
                guard try quitOtherInstances(RunningInstances.others()) else { return true }
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
                    "\(error.localizedDescription) Copiez Goalong History dans votre dossier Applications, puis ouvrez cette copie. Vos données ne sont pas modifiées."
                failure.addButton(withTitle: "Afficher Applications")
                failure.addButton(withTitle: "Quitter")
                if failure.runModal() == .alertFirstButtonReturn {
                    GoalongWorkspaceOpenPolicy.open(
                        revealFolder(attempted: attemptedDestination?.deletingLastPathComponent()),
                        purpose: .localFile
                    )
                }
                return true
            }
        }

        /// The folder the "Afficher Applications" button opens: the one the install aimed at,
        /// or /Applications when it is unknown or missing. Never creates a folder.
        static func revealFolder(attempted: URL?, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
            if let attempted, exists(attempted) { return attempted }
            return URL(fileURLWithPath: "/Applications", isDirectory: true)
        }

        enum ReplacementDecision: Equatable { case replace, alreadyInstalled }

        /// A translocated copy of the version that is already installed must never delete it.
        static func replacementDecision(
            source: URL, destination: URL, fileManager: FileManager = .default
        ) -> ReplacementDecision {
            guard source.path.contains("/AppTranslocation/"),
                  fileManager.fileExists(atPath: destination.path),
                  let installed = Bundle(url: destination), installed.bundleIdentifier == bundleIdentifier,
                  let current = Bundle(url: source), current.bundleIdentifier == bundleIdentifier,
                  let installedVersion = installed.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  installedVersion == current.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            else { return .replace }
            return .alreadyInstalled
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

        /// Copies `source` next to `destination`, removes the download quarantine from that new copy
        /// only (the user launched this very bundle and chose to move it), then swaps it in. A failure
        /// at any step leaves the existing installation untouched and no temporary copy behind.
        static func replaceApplication(
            at destination: URL, with source: URL,
            fileManager: FileManager = .default,
            temporaryName: () -> String = { UUID().uuidString }
        ) throws {
            let exists = fileManager.fileExists(atPath: destination.path)
            if exists {
                guard Bundle(url: destination)?.bundleIdentifier == bundleIdentifier else {
                    throw InstallationError.destinationOccupied
                }
            }
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(appName).installing-\(temporaryName())", isDirectory: true)
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: source, to: temporary)
            stripQuarantine(at: temporary, fileManager: fileManager)
            if exists {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        }

        /// Removes only `com.apple.quarantine`, on every entry under `root` (symlinks themselves, not targets).
        static func stripQuarantine(at root: URL, fileManager: FileManager = .default) {
            var paths = [root.path]
            if let enumerator = fileManager.enumerator(atPath: root.path) {
                for case let relative as String in enumerator { paths.append(root.appendingPathComponent(relative).path) }
            }
            for path in paths where removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
                Diagnostics.write("Could not remove the quarantine attribute (errno \(errno))")
            }
        }

        /// Asks the user to let other running copies quit, then waits for them for a short time.
        /// Returns false when the install must stop (user declined or a copy did not quit).
        /// The quit is a normal quit request: a copy that refuses (for example, a locked block) stays open.
        static func quitOtherInstances(
            _ others: [any RunningInstance], timeout: TimeInterval = 10,
            confirm: () -> Bool = {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Goalong History est déjà ouvert"
                alert.informativeText = "Pour installer cette version, l’autre copie doit d’abord se fermer. La fermer maintenant ?"
                alert.addButton(withTitle: "Fermer et continuer")
                alert.addButton(withTitle: "Quitter")
                return alert.runModal() == .alertFirstButtonReturn
            },
            sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        ) throws -> Bool {
            let running = others.filter { !$0.isTerminated }
            guard !running.isEmpty else { return true }
            guard confirm() else { return false }
            running.forEach { _ = $0.terminate() }
            var waited: TimeInterval = 0
            while waited < timeout, running.contains(where: { !$0.isTerminated }) {
                sleep(0.1); waited += 0.1
            }
            if running.contains(where: { !$0.isTerminated }) { throw InstallationError.otherInstanceStillRunning }
            return true
        }
    }

    protocol RunningInstance {
        var isTerminated: Bool { get }
        func terminate() -> Bool
    }

    extension NSRunningApplication: RunningInstance {}

    enum RunningInstances {
        static func others() -> [any RunningInstance] {
            NSRunningApplication.runningApplications(withBundleIdentifier: "ai.goalong.localhistory")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        }
    }

    enum InstallationError: LocalizedError {
        case destinationOccupied
        case couldNotRelaunch
        case otherInstanceStillRunning

        var errorDescription: String? {
            switch self {
            case .destinationOccupied:
                return "Une autre application occupe déjà l’emplacement de Goalong History."
            case .couldNotRelaunch:
                return "La copie de l’application n’a pas pu être ouverte."
            case .otherInstanceStillRunning:
                return "Goalong History est encore ouvert et ne s’est pas fermé."
            }
        }
    }
#endif
