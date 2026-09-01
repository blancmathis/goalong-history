#if os(macOS)
    import AgentActivity
    import AppKit
    import Darwin
    import Foundation
    import LocalHistoryQueryCLI
    import ServiceManagement

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

    if CommandLine.arguments.contains("--reset-onboarding") {
        UserDefaults.standard.removeObject(forKey: "didShowLocalHistoryConsentOnboardingV5")
        exit(0)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    if InstallationLocationManager.handleTransientLaunchIfNeeded() {
        exit(0)
    }

    LegacyInstallationMigrator.run()

    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
#else
    import Foundation
    fputs("Goalong History is a macOS-only application.\n", stderr)
#endif
