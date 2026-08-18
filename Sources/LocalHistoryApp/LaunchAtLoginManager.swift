#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import ServiceManagement

    @MainActor
    final class LaunchAtLoginManager: ObservableObject {
        enum State: Equatable {
            case enabled
            case disabled
            case requiresApproval
            case unavailable
        }

        @Published private(set) var state: State = .disabled
        @Published private(set) var isChanging = false
        @Published private(set) var message: String?

        init() {
            refresh()
        }

        var isEnabled: Bool {
            state == .enabled
        }

        var isRegistered: Bool {
            state == .enabled || state == .requiresApproval
        }

        var requiresApproval: Bool {
            state == .requiresApproval
        }

        var statusTitle: String {
            switch state {
            case .enabled:
                return "Starts automatically"
            case .requiresApproval:
                return "Approval required"
            case .disabled:
                return "Starts only when opened"
            case .unavailable:
                return "Status unavailable"
            }
        }

        var statusDetail: String {
            switch state {
            case .enabled:
                return "LocalHistory will be ready after each Mac login."
            case .requiresApproval:
                return "Allow LocalHistory in System Settings → General → Login Items."
            case .disabled:
                return "You can still open LocalHistory manually at any time."
            case .unavailable:
                return "macOS could not read the login-item status."
            }
        }

        func refresh() {
            switch SMAppService.mainApp.status {
            case .enabled:
                state = .enabled
            case .requiresApproval:
                state = .requiresApproval
            case .notRegistered:
                state = .disabled
            case .notFound:
                state = .unavailable
            @unknown default:
                state = .unavailable
            }
        }

        @discardableResult
        func setEnabled(_ enabled: Bool) -> Bool {
            isChanging = true
            message = nil
            defer {
                isChanging = false
                refresh()
            }

            do {
                let service = SMAppService.mainApp
                if enabled {
                    switch service.status {
                    case .enabled, .requiresApproval:
                        break
                    case .notRegistered, .notFound:
                        try service.register()
                    @unknown default:
                        try service.register()
                    }
                } else {
                    switch service.status {
                    case .notRegistered, .notFound:
                        break
                    case .enabled, .requiresApproval:
                        try service.unregister()
                    @unknown default:
                        try service.unregister()
                    }
                }
                return true
            } catch {
                message = (error as NSError).localizedDescription
                return false
            }
        }

        func openLoginItemsSettings() {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
#endif
