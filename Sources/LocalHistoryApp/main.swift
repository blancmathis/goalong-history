#if os(macOS)
    import AppKit
    import Darwin
    import ServiceManagement

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
