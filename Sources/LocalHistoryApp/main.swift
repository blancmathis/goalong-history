#if os(macOS)
    import AgentActivity
    import AppKit
    import Darwin
    import Foundation
    import LocalHistoryQueryCLI
    import ServiceManagement

    // The color-restoration child never starts the app, its migration or observers.
    if CommandLine.arguments.dropFirst().first == "--braise-guardian" {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let expected = AppPaths.applicationSupportDirectory.appendingPathComponent("Braise", isDirectory: true).standardizedFileURL
        guard path.deletingLastPathComponent() == expected, path.lastPathComponent.hasPrefix("display-recovery-"),
              path.pathExtension == "json" else { exit(2) }
        GammaController.guardianMain(path: path.path)
    }

    if URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent == "goalong" {
        GoalongQueryCLI.main()
        exit(0)
    }

    if let hookIndex = CommandLine.arguments.firstIndex(of: "--agent-hook-ingest") {
        guard CommandLine.arguments.indices.contains(hookIndex + 2) else {
            let message = "Goalong History agent hook requires a provider and event name.\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            try? FileHandle.standardOutput.write(contentsOf: Data("{}\n".utf8))
            exit(0)
        }

        let provider = AgentProvider(rawValue: CommandLine.arguments[hookIndex + 1]) ?? .custom
        let eventName = CommandLine.arguments[hookIndex + 2]
        let discardedPayloadBytes = AgentHookInputDrainer.discard(
            fromFileDescriptor: FileHandle.standardInput.fileDescriptor
        )
        do {
            let signalRoot = try AppPaths.prepareAgentActivityHookStorage()
            try AgentHookSignalWriter.write(
                rootDirectory: signalRoot,
                provider: provider,
                eventName: eventName,
                discardedPayloadBytes: discardedPayloadBytes,
                processIdentifier: getppid()
            )
            try? FileHandle.standardOutput.write(contentsOf: Data("{}\n".utf8))
            exit(0)
        } catch {
            let message = "Goalong History agent hook failed: \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            try? FileHandle.standardOutput.write(contentsOf: Data("{}\n".utf8))
            exit(0)
        }
    }

    if CommandLine.arguments.contains("--unregister-login-item") {
        // Goalong Dev owns no login item: never touch the installed Goalong's one.
        guard GoalongLoginItemGate.isAllowed else { exit(0) }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            try? SMAppService.mainApp.unregister()
        case .notRegistered, .notFound:
            break
        @unknown default:
            try? SMAppService.mainApp.unregister()
        }
        exit(0)
    }

    // Called by uninstall.sh before it deletes the bundles: removes Goalong's hooks from the
    // agents' configuration files. Best effort; only entries with Goalong's marker are touched.
    if CommandLine.arguments.contains("--uninstall-agent-integrations") {
        let installer = AgentIntegrationInstaller(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0])
        )
        for kind in AgentIntegrationKind.allCases {
            try? installer.uninstall(kind)
        }
        exit(0)
    }

    if CommandLine.arguments.contains("--reset-onboarding") {
        UserDefaults.standard.removeObject(forKey: "didShowLocalHistoryConsentOnboardingV5")
        exit(0)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    if InstallationLocationManager.handleTransientLaunchIfNeeded() {
        exit(0)
    }

    let delegate = AppDelegate()
    application.delegate = delegate
    Task { @MainActor in JevMonitor.shared.start() }
    application.run()
#else
    import Foundation
    fputs("Goalong History is a macOS-only application.\n", stderr)
#endif
