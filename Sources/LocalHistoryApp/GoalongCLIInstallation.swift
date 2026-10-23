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
    }

    enum GoalongCLIInstallation {
        static var defaultLinkURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/goalong", isDirectory: false)
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
                    detail: "Le lien de la commande goalong est absent. Réinstallez Goalong pour le créer en toute sécurité."
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
    }
#endif
