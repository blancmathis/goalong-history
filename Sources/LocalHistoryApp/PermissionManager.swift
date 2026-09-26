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

        // Only a protected AX read from a different process may override a stale preflight.
        // Our own window (or an application role) never proves a macOS grant.
        var accessibilityCrossProcessProbe: Bool = false
        var accessibilityProbeError: Int32? = nil

        var allGranted: Bool { accessibility && inputMonitoring }
        var accessibilityUsable: Bool { accessibility && accessibilityFunctionalProbe }
        var canAttemptInputTap: Bool { accessibility || inputMonitoringDirectlyGranted }

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
            inputMonitoringDirectlyGranted: Bool,
            accessibilityCrossProcessProbe: Bool = false,
            accessibilityProbeError: Int32? = nil
        ) -> PermissionStatus {
            let accessibility = accessibilityPreflight || accessibilityCrossProcessProbe
            let inputMonitoringProvidedByAccessibility =
                accessibility && !inputMonitoringDirectlyGranted
            return PermissionStatus(
                accessibility: accessibility,
                inputMonitoring:
                    inputMonitoringDirectlyGranted || inputMonitoringProvidedByAccessibility,
                accessibilityPreflight: accessibilityPreflight,
                accessibilityFunctionalProbe: accessibilityFunctionalProbe,
                inputMonitoringDirectlyGranted: inputMonitoringDirectlyGranted,
                inputMonitoringProvidedByAccessibility: inputMonitoringProvidedByAccessibility,
                accessibilityCrossProcessProbe: accessibilityCrossProcessProbe,
                accessibilityProbeError: accessibilityProbeError
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
        private var cachedStatus: PermissionStatus
        private var lastRefreshAt: Date
        private var refreshInFlight = false
        private(set) var probeCount = 0

        init(
            statusProbe: @escaping StatusProbe = PermissionManager.liveStatus,
            clock: @escaping () -> Date = Date.init
        ) {
            self.statusProbe = statusProbe
            self.clock = clock
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

        /// Fast when preflight succeeds; on disagreement, verify a bounded protected
        /// attribute on another process. Used by setup and the recording watchdog.
        static func activationStatus() -> PermissionStatus {
            probeStatus(includeFunctionalCheck: false)
        }

        private static func liveStatus() -> PermissionStatus {
            probeStatus(includeFunctionalCheck: true)
        }

        private static func probeStatus(includeFunctionalCheck: Bool) -> PermissionStatus {
            let started = ProcessInfo.processInfo.systemUptime
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            let preflight = AXIsProcessTrustedWithOptions(options)
            let evidence = (!preflight || includeFunctionalCheck) ? crossProcessEvidence() : (false, nil)
            let input = CGPreflightListenEventAccess()
            let status = PermissionStatus.resolved(
                accessibilityPreflight: preflight,
                accessibilityFunctionalProbe: evidence.0,
                inputMonitoringDirectlyGranted: input,
                accessibilityCrossProcessProbe: evidence.0,
                accessibilityProbeError: evidence.1
            )
            var values: [SupportKey: SupportValue] = [
                .accessibilityPreflight: .flag(preflight), .accessibilityFunctional: .flag(evidence.0),
                .accessibilityCrossProcess: .flag(evidence.0), .inputPreflight: .flag(input),
                .state: .state((!preflight || includeFunctionalCheck) ? (evidence.0 ? .ready : .unavailable) : .skipped),
                .elapsedMS: .number((ProcessInfo.processInfo.systemUptime - started) * 1000)
            ]
            if let error = evidence.1 { values[.axError] = .count(Int(error)) }
            SupportDiagnostics.shared.record(.permissionChecked, component: .permissions, values: values)
            return status
        }

        /// Reads only the existence/type of a window list, never its content.
        /// Self-process AX access remains possible without TCC and must be excluded.
        private static func crossProcessEvidence() -> (Bool, Int32?) {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            var candidates: [NSRunningApplication] = []
            if let front = NSWorkspace.shared.frontmostApplication,
               isExternalProbeTarget(pid: front.processIdentifier, ownPID: currentPID) { candidates.append(front) }
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
               isExternalProbeTarget(pid: finder.processIdentifier, ownPID: currentPID),
               !candidates.contains(where: { $0.processIdentifier == finder.processIdentifier }) { candidates.append(finder) }
            var lastError: Int32?
            for candidate in candidates.prefix(2) {
                let app = AXUIElementCreateApplication(candidate.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 0.12)
                var windows: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
                lastError = error.rawValue
                if error == .success, let windows, CFGetTypeID(windows) == CFArrayGetTypeID() { return (true, nil) }
            }
            return (false, lastError)
        }

        static func isExternalProbeTarget(pid: Int32, ownPID: Int32) -> Bool { pid > 1 && pid != ownPID }

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
            // Input Monitoring preflight is reported independently from Accessibility.
            // A successful callback remains the authoritative runtime proof.
            if snapshot.inputMonitoring { return true }
            let requested = CGRequestListenEventAccess()
            _ = refresh(force: true)
            return requested
        }

        func requestAll() {
            let status = refresh(force: true)
            if !status.accessibility {
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
            if !refresh(force: true).inputMonitoring {
                _ = requestInputMonitoring()
            }
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

        static func functionalProbeIsUsable(
            systemWideReadable: Bool,
            frontmostApplicationReadable: Bool
        ) -> Bool {
            systemWideReadable || frontmostApplicationReadable
        }
    }

#endif
