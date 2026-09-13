#if os(macOS)
    import AppKit
    import ApplicationServices
    import CoreGraphics

    enum MacPermissionKind: String, Identifiable {
        case accessibility
        case inputMonitoring

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var symbol: String {
            switch self {
            case .accessibility: return "accessibility"
            case .inputMonitoring: return "keyboard"
            }
        }

        var settingsAnchor: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .inputMonitoring: return "Privacy_ListenEvent"
            }
        }

        var explanation: String {
            switch self {
            case .accessibility:
                return "Allows the app to read the foreground application, window and permitted interface context."
            case .inputMonitoring:
                return "Allows the app to observe clicks, scrolling and coarse keyboard activity without reading characters or exact keys."
            }
        }
    }

    struct PermissionStatus: Equatable {
        let accessibility: Bool
        let inputMonitoring: Bool
        let accessibilityPreflight: Bool
        let accessibilityFunctionalProbe: Bool
        let inputMonitoringDirectlyGranted: Bool
        let inputMonitoringProvidedByAccessibility: Bool

        var allGranted: Bool { accessibility && inputMonitoring }
        var accessibilityUsable: Bool { accessibilityPreflight && accessibilityFunctionalProbe }
        var canAttemptInputTap: Bool { accessibilityPreflight || inputMonitoringDirectlyGranted }

        func isGranted(_ permission: MacPermissionKind) -> Bool {
            switch permission {
            case .accessibility: return accessibility
            case .inputMonitoring: return inputMonitoring
            }
        }

        var inputMonitoringStatusLabel: String {
            if inputMonitoringDirectlyGranted { return "on" }
            if inputMonitoringProvidedByAccessibility { return "via Accessibility" }
            return "off"
        }

        static func resolved(
            accessibilityPreflight: Bool,
            accessibilityFunctionalProbe: Bool,
            inputMonitoringDirectlyGranted: Bool
        ) -> PermissionStatus {
            // A read of our own AX window can succeed after a TCC revocation. It is
            // health evidence, never an authorization grant. All UI and activation
            // paths must agree with AXIsProcessTrusted for this running process.
            let accessibility = accessibilityPreflight
            let inputMonitoringProvidedByAccessibility =
                accessibilityPreflight && !inputMonitoringDirectlyGranted
            return PermissionStatus(
                accessibility: accessibility,
                inputMonitoring:
                    inputMonitoringDirectlyGranted || inputMonitoringProvidedByAccessibility,
                accessibilityPreflight: accessibilityPreflight,
                accessibilityFunctionalProbe: accessibilityFunctionalProbe,
                inputMonitoringDirectlyGranted: inputMonitoringDirectlyGranted,
                inputMonitoringProvidedByAccessibility: inputMonitoringProvidedByAccessibility
            )
        }
    }

    enum PermissionWatchdogPolicy {
        static let healthyInterval: TimeInterval = 60
        static let recoveryInterval: TimeInterval = 3

        static func interval(status: PermissionStatus, eventTapRunning: Bool) -> TimeInterval {
            let accessibilityHealthy = status.accessibilityUsable
            let inputPathAvailable = status.canAttemptInputTap
            return accessibilityHealthy && inputPathAvailable && eventTapRunning
                ? healthyInterval
                : recoveryInterval
        }
    }

    /// Reads macOS TCC state and owns the guided permission experience.
    ///
    /// Reports macOS Accessibility and direct Input Monitoring preflights independently.
    /// Neither switch nor event-tap creation is treated as proof of capture: the recorder health
    /// state requires a functional AX read and a real click/key/scroll callback in this process.
    final class PermissionManager {
        typealias StatusProbe = () -> PermissionStatus

        private let statusLock = NSLock()
        private let statusProbe: StatusProbe
        private let clock: () -> Date
        private let inputAccessRequest: () -> Bool
        private var cachedStatus: PermissionStatus
        private var lastRefreshAt: Date
        private var refreshInFlight = false
        private(set) var probeCount = 0

        init(
            statusProbe: @escaping StatusProbe = PermissionManager.liveStatus,
            clock: @escaping () -> Date = Date.init,
            inputAccessRequest: @escaping () -> Bool = { CGRequestListenEventAccess() }
        ) {
            self.statusProbe = statusProbe
            self.clock = clock
            self.inputAccessRequest = inputAccessRequest
            let initial = statusProbe()
            cachedStatus = initial
            lastRefreshAt = clock()
            probeCount = 1
        }

        /// Shared, zero-probe snapshot used by AX readers, dashboard and menu.
        var snapshot: PermissionStatus {
            statusLock.lock()
            defer { statusLock.unlock() }
            return cachedStatus
        }

        /// Compatibility accessor. Reading it never calls TCC or Accessibility.
        var currentStatus: PermissionStatus { snapshot }

        @discardableResult
        func refresh(
            force: Bool = false,
            minimumInterval: TimeInterval = 1.0
        ) -> PermissionStatus {
            let now = clock()
            statusLock.lock()
            if refreshInFlight
                || (!force && now.timeIntervalSince(lastRefreshAt) < max(0, minimumInterval))
            {
                let value = cachedStatus
                statusLock.unlock()
                return value
            }
            refreshInFlight = true
            statusLock.unlock()

            let value = statusProbe()

            statusLock.lock()
            cachedStatus = value
            lastRefreshAt = clock()
            refreshInFlight = false
            probeCount += 1
            statusLock.unlock()
            return value
        }

        private static func liveStatus() -> PermissionStatus {
            let accessibilityPreflight = AXIsProcessTrusted()
            let accessibilityFunctionalProbe = accessibilityPreflight && Self.canReadFocusedApplication()
            let directInputMonitoring = CGPreflightListenEventAccess()
            return .resolved(
                accessibilityPreflight: accessibilityPreflight,
                accessibilityFunctionalProbe: accessibilityFunctionalProbe,
                inputMonitoringDirectlyGranted: directInputMonitoring
            )
        }

        @discardableResult
        func requestAccessibility() -> Bool {
            let options =
                [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
            let requested = AXIsProcessTrustedWithOptions(options)
            _ = refresh(force: true)
            return requested
        }

        @discardableResult
        func requestInputMonitoring() -> Bool {
            // An explicit Input Monitoring request must consult its own preflight.
            // Accessibility may permit trying a tap, but does not mean the separate
            // Input Monitoring entry is registered or enabled in System Settings.
            if refresh(force: true).inputMonitoringDirectlyGranted { return true }
            let requested = inputAccessRequest()
            _ = refresh(force: true)
            return requested
        }

        func requestAll() {
            let status = refresh(force: true)
            if !status.accessibilityPreflight {
                _ = requestAccessibility()
            } else if !status.inputMonitoring {
                _ = requestInputMonitoring()
            }
        }

        func openAccessibilitySettings() {
            if !refresh(force: true).accessibilityPreflight {
                _ = requestAccessibility()
            }
            openSettingsDirectly(for: .accessibility)
        }

        func openInputMonitoringSettings() {
            _ = requestInputMonitoring()
            openSettingsDirectly(for: .inputMonitoring)
        }

        func openPrivacySettings() {
            openPrivacySettingsDirectly()
        }

        func openFullDiskAccessSettings() {
            let candidates = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            ]
            for candidate in candidates {
                if let url = URL(string: candidate),
                    GoalongWorkspaceOpenPolicy.open(url, purpose: .systemSettings)
                {
                    return
                }
            }
            openPrivacySettingsDirectly()
        }

        private func openSettingsDirectly(for permission: MacPermissionKind) {
            openSettingsPaneDirectly(permission.settingsAnchor)
        }

        private func openPrivacySettingsDirectly() {
            let candidates = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                "x-apple.systempreferences:com.apple.preference.security?Privacy",
            ]

            for candidate in candidates {
                if let url = URL(string: candidate),
                    GoalongWorkspaceOpenPolicy.open(url, purpose: .systemSettings)
                {
                    return
                }
            }
        }

        private func openSettingsPaneDirectly(_ anchor: String) {
            let candidates = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
                "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            ]

            for candidate in candidates {
                if let url = URL(string: candidate),
                    GoalongWorkspaceOpenPolicy.open(url, purpose: .systemSettings)
                {
                    return
                }
            }

            openPrivacySettingsDirectly()
        }

        private static func canReadFocusedApplication() -> Bool {
            let systemWide = AXUIElementCreateSystemWide()
            // Setting a timeout on the system-wide element would change the
            // default for every AX client in this process, not just this probe.
            var focusedApplication: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedApplicationAttribute as CFString,
                &focusedApplication
            )
            let systemWideReadable = result == .success && focusedApplication != nil
            guard !systemWideReadable,
                AXIsProcessTrusted(),
                let frontmost = NSWorkspace.shared.frontmostApplication
            else { return systemWideReadable }

            // macOS can transiently refuse the system-wide focused-application
            // attribute during app activation even though app-scoped AX reads work.
            // Reading the foreground application's role is a bounded, content-free
            // functional fallback and avoids reporting a false permission failure.
            let application = AXUIElementCreateApplication(frontmost.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.12)
            var role: CFTypeRef?
            let appResult = AXUIElementCopyAttributeValue(
                application,
                kAXRoleAttribute as CFString,
                &role
            )
            return functionalProbeIsUsable(
                systemWideReadable: systemWideReadable,
                frontmostApplicationReadable: appResult == .success && role != nil
            )
        }

        static func functionalProbeIsUsable(
            systemWideReadable: Bool,
            frontmostApplicationReadable: Bool
        ) -> Bool {
            systemWideReadable || frontmostApplicationReadable
        }
    }

#endif
