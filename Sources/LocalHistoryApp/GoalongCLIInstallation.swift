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
                        detail: "A non-link item already exists at the Goalong CLI path. Goalong will never replace it automatically."
                    )
                }
                return GoalongCLIInstallationReport(
                    state: .missing,
                    linkPath: linkPath,
                    resolvedTargetPath: nil,
                    detail: "The stable Goalong CLI link is missing. Reinstall Goalong to create it safely."
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
                    detail: "Goalong could not identify the executable for this running app. The CLI link was not trusted."
                )
            }
            let expectedTarget = expectedExecutableURL.standardizedFileURL.resolvingSymlinksInPath()
            guard resolvedTarget.path == expectedTarget.path else {
                return GoalongCLIInstallationReport(
                    state: .conflict,
                    linkPath: linkPath,
                    resolvedTargetPath: resolvedTarget.path,
                    detail: "The CLI link targets a different executable. Reinstall Goalong instead of using this command."
                )
            }
            guard fileManager.isExecutableFile(atPath: resolvedTarget.path) else {
                return GoalongCLIInstallationReport(
                    state: .conflict,
                    linkPath: linkPath,
                    resolvedTargetPath: resolvedTarget.path,
                    detail: "The CLI link targets the running Goalong app, but its executable is not runnable."
                )
            }
            return GoalongCLIInstallationReport(
                state: .ready,
                linkPath: linkPath,
                resolvedTargetPath: resolvedTarget.path,
                detail: "The stable CLI link resolves to this exact installed Goalong executable."
            )
        }
    }
#endif
