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

        func requestAll() {
            let options =
                [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                _ = CGRequestListenEventAccess()
            }
        }

        func openAccessibilitySettings() {
            openSettingsPane("Privacy_Accessibility")
        }

        func openInputMonitoringSettings() {
            openSettingsPane("Privacy_ListenEvent")
        }

        private func openSettingsPane(_ anchor: String) {
            let candidates = [
                "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            ]

            for candidate in candidates {
                if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                    return
                }
            }
        }
    }
#endif
