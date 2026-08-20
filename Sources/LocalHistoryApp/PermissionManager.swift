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
    }

    /// Reads macOS TCC state and owns the guided permission experience.
    ///
    /// Reports macOS Accessibility and direct Input Monitoring preflights independently.
    /// Neither switch nor event-tap creation is treated as proof of capture: the recorder health
    /// state requires a functional AX read and a real click/key/scroll callback in this process.
    final class PermissionManager {
        private var guideController: PermissionGuideController?

        var currentStatus: PermissionStatus {
            let accessibilityPreflight = AXIsProcessTrusted()
            let accessibilityFunctionalProbe = Self.canReadFocusedApplication()
            let accessibility = accessibilityPreflight || accessibilityFunctionalProbe
            let directInputMonitoring = CGPreflightListenEventAccess()

            return PermissionStatus(
                accessibility: accessibility,
                inputMonitoring: directInputMonitoring,
                accessibilityPreflight: accessibilityPreflight,
                accessibilityFunctionalProbe: accessibilityFunctionalProbe,
                inputMonitoringDirectlyGranted: directInputMonitoring,
                inputMonitoringProvidedByAccessibility: false
            )
        }

        @discardableResult
        func requestAccessibility() -> Bool {
            let options =
                [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }

        @discardableResult
        func requestInputMonitoring() -> Bool {
            // Input Monitoring preflight is reported independently from Accessibility.
            // A successful callback remains the authoritative runtime proof.
            if currentStatus.inputMonitoring { return true }
            return CGRequestListenEventAccess()
        }

        func requestAll() {
            let status = currentStatus
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
            return result == .success && focusedApplication != nil
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
            startPolling()
        }

        func windowWillClose(_ notification: Notification) {
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
            model.status = permissionManager.currentStatus

            guard model.isGranted, !wasGranted else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.close()
            }
            closeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: workItem)
        }

        private func startPolling() {
            stopPolling()
            let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
                self?.refreshStatus()
            }
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
