#if os(macOS)
    import AppKit
    import ApplicationServices
    import Combine
    import CoreGraphics
    import SwiftUI

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
                return "Allows the app to observe clicks, scrolling, shortcuts and typing activity without reading typed characters."
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
            inputMonitoringDirectlyGranted: Bool
        ) -> PermissionStatus {
            let accessibility = accessibilityPreflight || accessibilityFunctionalProbe
            let inputMonitoringProvidedByAccessibility =
                accessibility && !inputMonitoringDirectlyGranted
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

        private var guideController: PermissionGuideController?
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

        private static func liveStatus() -> PermissionStatus {
            let accessibilityPreflight = AXIsProcessTrusted()
            let accessibilityFunctionalProbe = Self.canReadFocusedApplication()
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
            presentGuide(for: .accessibility)
        }

        func openInputMonitoringSettings() {
            presentGuide(for: .inputMonitoring)
        }

        func openPrivacySettings() {
            openPrivacySettingsDirectly()
        }

        private func presentGuide(for permission: MacPermissionKind) {
            if !Thread.isMainThread {
                DispatchQueue.main.async { [weak self] in
                    self?.presentGuide(for: permission)
                }
                return
            }

            if guideController == nil {
                guideController = PermissionGuideController(permissionManager: self)
            }
            guideController?.present(permission)
        }

        fileprivate func request(_ permission: MacPermissionKind) {
            switch permission {
            case .accessibility:
                _ = requestAccessibility()
            case .inputMonitoring:
                _ = requestInputMonitoring()
            }
        }

        fileprivate func openSettingsDirectly(for permission: MacPermissionKind) {
            openSettingsPaneDirectly(permission.settingsAnchor)
        }

        private func openPrivacySettingsDirectly() {
            let candidates = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                "x-apple.systempreferences:com.apple.preference.security?Privacy",
            ]

            for candidate in candidates {
                if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
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
                if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                    return
                }
            }

            openPrivacySettingsDirectly()
        }

        private static func canReadFocusedApplication() -> Bool {
            let systemWide = AXUIElementCreateSystemWide()
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

    private final class PermissionGuideModel: ObservableObject {
        @Published var permission: MacPermissionKind = .accessibility
        @Published var status = PermissionStatus(
            accessibility: false,
            inputMonitoring: false,
            accessibilityPreflight: false,
            accessibilityFunctionalProbe: false,
            inputMonitoringDirectlyGranted: false,
            inputMonitoringProvidedByAccessibility: false
        )

        var isGranted: Bool { status.isGranted(permission) }

        var statusTitle: String {
            if isGranted {
                return "Permission granted"
            }
            return "Waiting for macOS"
        }

        var statusDetail: String {
            if isGranted {
                return "macOS reports this permission for the current app copy. Runtime health still requires a functional AX probe and a real input callback."
            }
            return "Turn on the switch beside the current copy of \(ProductIdentity.displayName). This status refreshes automatically."
        }
    }

    private final class PermissionGuideController: NSObject, NSWindowDelegate {
        private unowned let permissionManager: PermissionManager
        private let model = PermissionGuideModel()
        private var panel: NSPanel?
        private var pollingTimer: Timer?
        private var closeWorkItem: DispatchWorkItem?

        init(permissionManager: PermissionManager) {
            self.permissionManager = permissionManager
            super.init()
        }

        deinit {
            closeWorkItem?.cancel()
            stopPolling()
        }

        func present(_ permission: MacPermissionKind) {
            closeWorkItem?.cancel()
            model.permission = permission
            refreshStatus()

            if !model.isGranted {
                permissionManager.request(permission)
                permissionManager.openSettingsDirectly(for: permission)
            }

            let panel = makePanelIfNeeded()
            position(panel)
            panel.orderFrontRegardless()
            if model.isGranted {
                scheduleClose()
            } else {
                startPolling()
            }
        }

        func windowWillClose(_ notification: Notification) {
            closeWorkItem?.cancel()
            closeWorkItem = nil
            stopPolling()
        }

        private func makePanelIfNeeded() -> NSPanel {
            if let panel { return panel }

            let size = NSSize(width: 420, height: 430)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "\(ProductIdentity.displayName) permissions"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.delegate = self

            let root = PermissionGuideView(
                model: model,
                openSettings: { [weak self] in self?.openSettings() },
                checkAgain: { [weak self] in self?.refreshStatus() },
                close: { [weak self] in self?.close() }
            )
            panel.contentViewController = NSHostingController(rootView: root)
            self.panel = panel
            return panel
        }

        private func position(_ panel: NSPanel) {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                panel.center()
                return
            }
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(
                NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 24)
            )
        }

        private func openSettings() {
            permissionManager.request(model.permission)
            permissionManager.openSettingsDirectly(for: model.permission)
            panel?.orderFrontRegardless()
            startPolling()
        }

        private func refreshStatus() {
            let wasGranted = model.isGranted
            // The guide is the only intentionally fast poller while the user is
            // actively changing a TCC switch.
            model.status = permissionManager.refresh(force: true)

            guard model.isGranted, !wasGranted else { return }
            stopPolling()
            scheduleClose()
        }

        private func scheduleClose() {
            closeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.close()
            }
            closeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: workItem)
        }

        private func startPolling() {
            stopPolling()
            guard !model.isGranted else {
                scheduleClose()
                return
            }
            let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
                self?.refreshStatus()
            }
            timer.tolerance = 0.15
            RunLoop.main.add(timer, forMode: .common)
            pollingTimer = timer
        }

        private func stopPolling() {
            pollingTimer?.invalidate()
            pollingTimer = nil
        }

        private func close() {
            closeWorkItem?.cancel()
            closeWorkItem = nil
            stopPolling()
            panel?.orderOut(nil)
        }
    }

    private struct PermissionGuideView: View {
        @ObservedObject var model: PermissionGuideModel
        let openSettings: () -> Void
        let checkAgain: () -> Void
        let close: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: model.permission.symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isGranted ? "\(ProductIdentity.displayName) is ready" : "Allow \(model.permission.title)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(model.permission.explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.isGranted ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.isGranted ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.statusTitle)
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.statusDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(13)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

                if !model.isGranted {
                    VStack(alignment: .leading, spacing: 11) {
                        guideStep(1, "System Settings is open on the correct privacy page.")
                        guideStep(2, "Find \(ProductIdentity.displayName) and turn its switch on.")
                        guideStep(3, "If an older duplicate is enabled, enable the entry matching the path below. Toggle it off and on once if macOS kept stale approval.")
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("CURRENT APP")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(ProductIdentity.installationPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    if !model.isGranted {
                        Button("Open System Settings", action: openSettings)
                            .buttonStyle(.borderedProminent)
                        Button("Check again", action: checkAgain)
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button(model.isGranted ? "Done" : "Close", action: close)
                        .buttonStyle(.bordered)
                }
            }
            .padding(22)
            .frame(width: 420, height: 430)
            .background(Color(nsColor: .windowBackgroundColor))
        }

        private func guideStep(_ number: Int, _ text: String) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background(Color.accentColor, in: Circle())
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
#endif
