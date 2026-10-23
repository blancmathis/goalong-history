#if os(macOS)
    import AppKit
    import Foundation
    import LocalHistoryCore

    enum InstallationLocationManager {
        private static let appName = "Goalong History.app"
        private static let bundleIdentifier = "ai.goalong.localhistory"

        /// Returns true when the current process should exit because the user quit
        /// or a relocated copy was launched.
        static func handleTransientLaunchIfNeeded() -> Bool {
            let source = Bundle.main.bundleURL.standardizedFileURL
            // Goalong Dev is installed by make dev and never moves itself into Applications.
            guard !GoalongBuildChannel.current.isDevelopment, isTransient(source) else { return false }

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
                let others = RunningInstances.others()
                let (decision, existing) = aggregateDecision(
                    source: source,
                    candidates: existingCandidates(destination: destination, running: others)
                )
                let revealTarget = existing ?? destination
                if decision == .installedIsNewer {
                    let newer = NSAlert()
                    newer.alertStyle = .informational
                    newer.messageText = "Une version plus récente est déjà dans Applications"
                    newer.informativeText =
                        "Cette copie est plus ancienne que celle installée. Ouvrez Goalong History depuis votre dossier Applications."
                    newer.addButton(withTitle: "Afficher dans le Finder")
                    newer.addButton(withTitle: "Quitter")
                    if newer.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([revealTarget])
                    }
                    return true
                }
                if decision == .alreadyInstalled {
                    let installed = NSAlert()
                    installed.alertStyle = .informational
                    installed.messageText = "Goalong History est déjà dans Applications"
                    installed.informativeText =
                        "Cette fenêtre est une copie temporaire de macOS. Ouvrez Goalong History depuis votre dossier Applications."
                    installed.addButton(withTitle: "Afficher dans le Finder")
                    installed.addButton(withTitle: "Quitter")
                    if installed.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([revealTarget])
                    }
                    return true
                }
                guard try quitOtherInstances(others) else { return true }
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

        enum ReplacementDecision: Equatable { case replace, alreadyInstalled, installedIsNewer }

        /// A copy of the installed version must never delete it (translocated sources only), and an
        /// older copy must never replace a newer install. Unreadable versions keep `.replace`.
        static func replacementDecision(
            source: URL, destination: URL, fileManager: FileManager = .default
        ) -> ReplacementDecision {
            guard fileManager.fileExists(atPath: destination.path),
                  let installed = Bundle(url: destination), installed.bundleIdentifier == bundleIdentifier,
                  let current = Bundle(url: source), current.bundleIdentifier == bundleIdentifier,
                  let installedVersion = installed.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  let sourceVersion = current.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            else { return .replace }
            switch installedVersion.compare(sourceVersion, options: .numeric) {
            case .orderedDescending: return .installedIsNewer
            case .orderedSame where source.path.contains("/AppTranslocation/"): return .alreadyInstalled
            default: return .replace
            }
        }

        /// Every place a Goalong copy may already be installed or running: the chosen destination,
        /// both Applications folders and the bundles of the other running copies.
        static func existingCandidates(
            destination: URL, running: [any RunningInstance],
            fileManager: FileManager = .default
        ) -> [URL] {
            let all = [
                destination,
                URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(appName, isDirectory: true),
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true)
                    .appendingPathComponent(appName, isDirectory: true),
            ] + running.compactMap(\.bundleURL)
            var seen = Set<String>()
            return all.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        }

        /// Applies `replacementDecision` to every existing copy. A newer copy anywhere wins, then an
        /// identical installed copy (translocated source). The URL is the copy to show to the user.
        static func aggregateDecision(
            source: URL, candidates: [URL], fileManager: FileManager = .default
        ) -> (ReplacementDecision, URL?) {
            let decisions = candidates.map {
                ($0, replacementDecision(source: source, destination: $0, fileManager: fileManager))
            }
            if let newer = decisions.first(where: { $0.1 == .installedIsNewer }) { return (.installedIsNewer, newer.0) }
            if let same = decisions.first(where: { $0.1 == .alreadyInstalled }) { return (.alreadyInstalled, same.0) }
            return (.replace, nil)
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
            // NSRunningApplication state only refreshes on a turn of the main run loop,
            // and this runs before application.run(), so the wait must spin the run loop.
            sleep: (TimeInterval) -> Void = { RunLoop.current.run(until: Date().addingTimeInterval($0)) }
        ) throws -> Bool {
            let running = others.filter { !$0.isTerminated }
            guard !running.isEmpty else { return true }
            guard confirm() else { return false }
            running.forEach { _ = $0.terminate() }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
                sleep(0.1)
            }
            if running.contains(where: { !$0.isTerminated }) { throw InstallationError.otherInstanceStillRunning }
            return true
        }
    }

    protocol RunningInstance {
        var isTerminated: Bool { get }
        var bundleURL: URL? { get }
        func terminate() -> Bool
    }

    extension RunningInstance {
        var bundleURL: URL? { nil }
    }

    extension NSRunningApplication: RunningInstance {}

    enum RunningInstances {
        static func others() -> [any RunningInstance] {
            NSRunningApplication.runningApplications(withBundleIdentifier: ProductIdentity.bundleIdentifier)
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
