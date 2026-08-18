#if os(macOS)
    import AppKit
    import ApplicationServices
    import CoreGraphics

    struct PermissionStatus: Equatable {
        let accessibility: Bool
        let inputMonitoring: Bool

        var allGranted: Bool { accessibility && inputMonitoring }
    }

    final class PermissionManager {
        var currentStatus: PermissionStatus {
            PermissionStatus(
                accessibility: AXIsProcessTrusted(),
                inputMonitoring: CGPreflightListenEventAccess()
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
            CGRequestListenEventAccess()
        }

        func requestAll() {
            _ = requestAccessibility()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                _ = self?.requestInputMonitoring()
            }
        }

        func openAccessibilitySettings() {
            openSettingsPane("Privacy_Accessibility")
        }

        func openInputMonitoringSettings() {
            openSettingsPane("Privacy_ListenEvent")
        }

        func openPrivacySettings() {
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

        private func openSettingsPane(_ anchor: String) {
            let candidates = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
                "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            ]

            for candidate in candidates {
                if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                    return
                }
            }

            openPrivacySettings()
        }
    }
#endif
