#if os(macOS)
    import AppKit
    import Foundation
    import GoalongGuardCore

    /// T-062: why this process started, and whether the member expects the window.
    /// A member's open (Spotlight, Finder, Dock, Launchpad) shows the dashboard; a login item,
    /// a guard relaunch, an update relaunch or a link launch stays as it was (menu bar only).
    enum LaunchOrigin: Equatable {
        case member, loginItem, serviceItem, guardRelaunch, document, unknown

        static func classify(arguments: [String], eventClass: AEEventClass?, eventID: AEEventID?,
                             launchProperty: OSType?) -> LaunchOrigin {
            if arguments.contains(GuardIdentity.relaunchArgument) { return .guardRelaunch }
            guard let eventClass, let eventID else { return .unknown }
            // A goalong-history:// link (kInternetEventClass) or a document: its own handler decides.
            guard eventClass == AEEventClass(kCoreEventClass),
                  eventID == AEEventID(kAEOpenApplication) || eventID == AEEventID(kAEReopenApplication)
            else { return .document }
            switch launchProperty {
            case OSType(keyAELaunchedAsLogInItem): return .loginItem
            case OSType(keyAELaunchedAsServiceItem): return .serviceItem
            default: return .member
            }
        }

        /// Read inside `applicationDidFinishLaunching`, while AppKit still handles the launch event.
        static func current(_ event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent,
                            arguments: [String] = CommandLine.arguments) -> LaunchOrigin {
            classify(arguments: arguments, eventClass: event?.eventClass, eventID: event?.eventID,
                     launchProperty: event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue)
        }
    }

    enum LaunchPresentation {
        static let quietRelaunchKey = "goalong.quietRelaunchUntil"
        /// The first minutes after boot are the session's login items, even without the login-item flag.
        static let bootQuietPeriod: TimeInterval = 90

        /// True when a cold launch must show the dashboard by itself.
        static func showsDashboardAtLaunch(origin: LaunchOrigin, quietRelaunchUntil: Double, now: Date,
                                           systemUptime: TimeInterval) -> Bool {
            guard origin == .member else { return false }
            // Sparkle relaunches through Launch Services like a member's open: it stays quiet.
            if quietRelaunchUntil > now.timeIntervalSince1970 { return false }
            return systemUptime >= bootQuietPeriod
        }

        /// A second copy (Spotlight while the first one starts or right after an update) asks the
        /// running copy to show its window. `activate()` alone shows nothing for a menu-bar app.
        static func showRequestName(bundleIdentifier: String) -> Notification.Name {
            Notification.Name("\(bundleIdentifier).show-dashboard-request")
        }
    }
#endif
