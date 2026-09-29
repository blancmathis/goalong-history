#if os(macOS)
    import Foundation

    enum GoalongCLIInstallationState: String, Equatable {
        case ready
        case missing
        case conflict
    }

    struct GoalongCLIInstallationReport: Equatable {
        let state: GoalongCLIInstallationState
        let linkPath: String
        let resolvedTargetPath: String?
        let detail: String
    }

    enum GoalongCLIInstallation {
        static var defaultLinkURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/goalong", isDirectory: false)
        }

        static func inspect(
            linkURL: URL = defaultLinkURL,
            expectedExecutableURL: URL? = Bundle.main.executableURL,
            fileManager: FileManager = .default
        ) -> GoalongCLIInstallationReport {
            let linkPath = linkURL.standardizedFileURL.path
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
