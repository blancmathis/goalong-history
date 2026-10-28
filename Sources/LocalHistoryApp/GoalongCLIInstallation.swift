#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum GoalongCLIInstallationState: String, Equatable {
        case ready
        case missing
        case conflict
        /// Goalong Dev: ~/.local/bin/goalong belongs to the installed Goalong and is never repointed from here.
        case development
    }

    struct GoalongCLIInstallationReport: Equatable {
        let state: GoalongCLIInstallationState
        let linkPath: String
        let resolvedTargetPath: String?
        let detail: String
        /// Goalong Dev only: its own CLI inside its bundle, which reads LocalHistory-Dev.
        var developmentCLIPath: String? = nil
        /// Missing state only: the one-line Terminal command that creates the link to this app's executable.
        var linkCommand: String? = nil
        /// The CLI page may create the link, or repair one that points to another (old or deleted) Goalong app.
        var canInstall = false
    }

    struct GoalongCLIInstallOutcome: Equatable {
        let succeeded: Bool
        let message: String
    }

    enum GoalongCLIInstallation {
        static var defaultLinkURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/goalong", isDirectory: false)
        }

        /// The DMG and Sparkle never create `~/.local/bin/goalong`; only the source installer does (C14-01).
        /// `ln -s` without `-f` never replaces an item already at the link path.
        static func linkCommand(executableURL: URL, linkURL: URL = defaultLinkURL) -> String {
            let link = linkURL.standardizedFileURL
            return "mkdir -p \(shellQuoted(link.deletingLastPathComponent().path)) && ln -s "
                + "\(shellQuoted(executableURL.standardizedFileURL.path)) \(shellQuoted(link.path))"
        }

        static func shellQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        static func inspect(
            linkURL: URL = defaultLinkURL,
            expectedExecutableURL: URL? = Bundle.main.executableURL,
            fileManager: FileManager = .default,
            isDevelopment: Bool = GoalongBuildChannel.current.isDevelopment
        ) -> GoalongCLIInstallationReport {
            let linkPath = linkURL.standardizedFileURL.path
            // Goalong Dev: the command serves the installed Goalong (its real data). Comparing it with the
            // Dev executable would always report a conflict, and "reinstall" would break the real command.
            if isDevelopment {
                let target = (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)).map { raw in
                    URL(fileURLWithPath: raw, relativeTo: linkURL.deletingLastPathComponent())
                        .standardizedFileURL.resolvingSymlinksInPath().path
                }
                let devCLI = expectedExecutableURL.map {
                    $0.deletingLastPathComponent().appendingPathComponent("goalong", isDirectory: false).path
                }
                return GoalongCLIInstallationReport(
                    state: .development,
                    linkPath: linkPath,
                    resolvedTargetPath: target,
                    detail: "Dans Goalong Dev, la commande goalong et les instructions copiées servent Goalong installé et ses vraies données. Pour les données de Goalong Dev, utilisez son propre exécutable. Ne réinstallez pas le lien depuis Goalong Dev.",
                    developmentCLIPath: devCLI
                )
            }
            let rawDestination: String
            do {
                rawDestination = try fileManager.destinationOfSymbolicLink(atPath: linkPath)
            } catch {
                if fileManager.fileExists(atPath: linkPath) {
                    return GoalongCLIInstallationReport(
                        state: .conflict,
                        linkPath: linkPath,
                        resolvedTargetPath: nil,
                        detail: "Un autre élément occupe déjà l’emplacement de la commande goalong. Goalong ne le remplacera jamais automatiquement."
                    )
                }
                return GoalongCLIInstallationReport(
                    state: .missing,
                    linkPath: linkPath,
                    resolvedTargetPath: nil,
                    detail: "L’installation par l’image disque (DMG) et les mises à jour Sparkle ne créent pas la commande goalong. Cliquez sur « Installer la commande », ou collez cette ligne dans le Terminal :",
                    linkCommand: expectedExecutableURL.map { linkCommand(executableURL: $0, linkURL: linkURL) },
                    canInstall: expectedExecutableURL != nil
                )
            }

            let destinationURL: URL
            if rawDestination.hasPrefix("/") {
                destinationURL = URL(fileURLWithPath: rawDestination, isDirectory: false)
            } else {
                destinationURL = URL(
                    fileURLWithPath: rawDestination,
                    relativeTo: linkURL.deletingLastPathComponent()
                )
            }
            let resolvedTarget = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
            guard let expectedExecutableURL else {
                return GoalongCLIInstallationReport(
                    state: .conflict,
                    linkPath: linkPath,
                    resolvedTargetPath: resolvedTarget.path,
                    detail: "Goalong n’a pas pu identifier son exécutable ; le lien de la commande n’est pas considéré fiable."
                )
            }
            let expectedTarget = expectedExecutableURL.standardizedFileURL.resolvingSymlinksInPath()
            guard resolvedTarget.path == expectedTarget.path else {
                if isGoalongTarget(rawDestination) {
                    return GoalongCLIInstallationReport(
                        state: .conflict,
                        linkPath: linkPath,
                        resolvedTargetPath: resolvedTarget.path,
                        detail: "Le lien de la commande pointe vers une autre copie de Goalong, ancienne ou supprimée. « Installer la commande » le fait pointer vers cette app.",
                        canInstall: true
                    )
                }
                return GoalongCLIInstallationReport(
                    state: .conflict,
                    linkPath: linkPath,
                    resolvedTargetPath: resolvedTarget.path,
                    detail: "Le lien de la commande pointe vers un autre exécutable. Réinstallez Goalong plutôt que d’utiliser cette commande."
                )
            }
            guard fileManager.isExecutableFile(atPath: resolvedTarget.path) else {
                return GoalongCLIInstallationReport(
                    state: .conflict,
                    linkPath: linkPath,
                    resolvedTargetPath: resolvedTarget.path,
                    detail: "Le lien pointe vers l’app Goalong ouverte, mais son exécutable ne peut pas être lancé."
                )
            }
            return GoalongCLIInstallationReport(
                state: .ready,
                linkPath: linkPath,
                resolvedTargetPath: resolvedTarget.path,
                detail: "Le lien de la commande pointe vers cette version installée de Goalong."
            )
        }

        /// Link targets that may be replaced: any Goalong app, even old or deleted (as `scripts/install_cli_link.sh`).
        static func isGoalongTarget(_ rawDestination: String) -> Bool {
            [
                "/Goalong History.app/Contents/MacOS/goalong",
                "/Goalong History Local.app/Contents/MacOS/goalong",
                "/Goalong History.app/Contents/MacOS/Goalong History",
                "/Goalong History Local.app/Contents/MacOS/Goalong History Local",
            ].contains { rawDestination.hasSuffix($0) }
        }

        /// C14-01: the DMG and Sparkle cannot run an install script, so the CLI page creates the link itself,
        /// like VS Code's « Install 'code' command in PATH ». Same rules as `scripts/install_cli_link.sh`:
        /// no administrator rights, and only a link to a Goalong app is ever replaced.
        static func install(
            linkURL: URL = defaultLinkURL,
            executableURL: URL? = Bundle.main.executableURL,
            fileManager: FileManager = .default,
            directoryOnPath: (URL) -> Bool = directoryIsOnShellPath,
            isDevelopment: Bool = GoalongBuildChannel.current.isDevelopment
        ) -> GoalongCLIInstallOutcome {
            let fail = { GoalongCLIInstallOutcome(succeeded: false, message: $0 + " La commande n’a pas été installée.") }
            // Goalong Dev never points the real command at itself (see `inspect`), even if called directly.
            guard !isDevelopment else { return fail("Goalong Dev ne réinstalle pas la commande de Goalong installé.") }
            let link = linkURL.standardizedFileURL, directory = link.deletingLastPathComponent()
            guard let executable = executableURL?.standardizedFileURL,
                  (try? fileManager.attributesOfItem(atPath: executable.path)[.type] as? FileAttributeType) == .typeRegular,
                  fileManager.isExecutableFile(atPath: executable.path)
            else { return fail("Goalong ne trouve pas son propre exécutable.") }
            let shown = abbreviated(link.path), shownDirectory = abbreviated(directory.path)

            if let type = try? fileManager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType {
                guard type == .typeDirectory, fileManager.isWritableFile(atPath: directory.path) else {
                    return fail("\(shownDirectory) existe mais n’est pas un dossier modifiable.")
                }
            } else {
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                } catch { return fail("Impossible de créer \(shownDirectory) : \(error.localizedDescription).") }
            }

            var repaired = false
            if (try? fileManager.attributesOfItem(atPath: link.path)) != nil {
                guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                    return fail("Un fichier qui n’est pas un lien de Goalong occupe déjà \(shown). Goalong ne le remplace jamais.")
                }
                if raw == executable.path {
                    return finish("La commande était déjà installée : \(shown) pointe vers cette app.", link: link, executable: executable, fileManager: fileManager, directoryOnPath: directoryOnPath)
                }
                guard isGoalongTarget(raw) else {
                    return fail("\(shown) pointe vers un autre programme (\(raw)). Goalong ne le remplace jamais.")
                }
                // Atomic replacement of the old Goalong link: a temporary link renamed over it.
                let temporary = directory.appendingPathComponent(".goalong.\(UUID().uuidString).tmp", isDirectory: false)
                do { try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: executable.path) } catch {
                    return fail("Impossible d’écrire dans \(shownDirectory) : \(error.localizedDescription).")
                }
                guard rename(temporary.path, link.path) == 0 else {
                    let reason = String(cString: strerror(errno)); try? fileManager.removeItem(at: temporary)
                    return fail("Impossible de remplacer l’ancien lien \(shown) : \(reason).")
                }
                repaired = true
            } else {
                // `symlink` fails if an item appeared meanwhile: nothing is ever overwritten.
                do { try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: executable.path) } catch {
                    return fail("Impossible de créer \(shown) : \(error.localizedDescription).")
                }
            }
            return finish(repaired
                ? "Commande réparée : \(shown) pointait vers une autre copie de Goalong ; il pointe maintenant vers cette app."
                : "Commande installée : \(shown) pointe vers cette app.",
                link: link, executable: executable, fileManager: fileManager, directoryOnPath: directoryOnPath)
        }

        private static func finish(_ message: String, link: URL, executable: URL, fileManager: FileManager,
                                   directoryOnPath: (URL) -> Bool) -> GoalongCLIInstallOutcome {
            guard inspect(linkURL: link, expectedExecutableURL: executable, fileManager: fileManager, isDevelopment: false).state == .ready else {
                return GoalongCLIInstallOutcome(succeeded: false, message: "Le lien \(abbreviated(link.path)) a été écrit mais ne mène pas à cette app. Utilisez la commande à copier.")
            }
            let directory = link.deletingLastPathComponent()
            guard directoryOnPath(directory) else {
                return GoalongCLIInstallOutcome(succeeded: true, message: message + " Attention : \(abbreviated(directory.path)) n’est pas dans le PATH de votre shell. "
                    + "Tapez le chemin complet \(abbreviated(link.path)), ou ajoutez cette ligne à ~/.zshrc puis ouvrez un nouveau Terminal : export PATH=\"$HOME/.local/bin:$PATH\"")
            }
            return GoalongCLIInstallOutcome(succeeded: true, message: message + " Ouvrez un nouveau Terminal et tapez : goalong status")
        }

        /// The app's own PATH is launchd's, not the shell's: the shell startup files are read for the folder.
        static func directoryIsOnShellPath(_ directory: URL) -> Bool {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let path = directory.standardizedFileURL.path
            let tilde = path.hasPrefix(home.path + "/") ? "/" + path.dropFirst(home.path.count + 1) : path
            if (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(where: { String($0) == path }) { return true }
            let files = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile", ".config/fish/config.fish"]
                .map { home.appendingPathComponent($0) }
                + [URL(fileURLWithPath: "/etc/paths")]
                + ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/etc/paths.d"), includingPropertiesForKeys: nil)) ?? [])
            return files.contains { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf8.count < 1_000_000 else { return false }
                return text.contains(path) || text.contains(tilde)
            }
        }

        private static func abbreviated(_ path: String) -> String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
    }
#endif
