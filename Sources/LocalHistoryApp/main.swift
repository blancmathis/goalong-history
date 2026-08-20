#if os(macOS)
    import AgentActivity
    import AppKit
    import Darwin
    import ServiceManagement

    if let hookIndex = CommandLine.arguments.firstIndex(of: "--agent-hook-ingest") {
        guard CommandLine.arguments.indices.contains(hookIndex + 2) else {
            let message = "LocalHistory agent hook requires a provider and event name.\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            try? FileHandle.standardOutput.write(contentsOf: Data("{}\n".utf8))
            exit(0)
        }

        let provider = AgentProvider(rawValue: CommandLine.arguments[hookIndex + 1]) ?? .custom
        let eventName = CommandLine.arguments[hookIndex + 2]
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        do {
            try AppPaths.prepare()
            try AgentHookInboxWriter.write(
                rootDirectory: AppPaths.agentActivityDirectory,
                provider: provider,
                eventName: eventName,
                payload: payload,
                processIdentifier: getppid()
            )
            try? FileHandle.standardOutput.write(contentsOf: Data("{}\n".utf8))
            exit(0)
        } catch {
            let message = "LocalHistory agent hook failed: \(error.localizedDescription)\n"
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
        UserDefaults.standard.removeObject(forKey: "didShowLocalHistoryOnboardingV3")
        exit(0)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    if InstallationLocationManager.handleTransientLaunchIfNeeded() {
        exit(0)
    }

    LegacyInstallationMigrator.run()

    let updateObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didFinishLaunchingNotification,
        object: application,
        queue: .main
    ) { _ in
        Task { @MainActor in
            SoftwareUpdateManager.shared.start()
        }
    }

    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
    NotificationCenter.default.removeObserver(updateObserver)
#else
    import Foundation
    fputs("LocalHistory is a macOS-only application.\n", stderr)
#endif
