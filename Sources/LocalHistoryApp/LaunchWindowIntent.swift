#if os(macOS)
import AppKit
import Foundation

/// T-062: a person who opens Goalong (Spotlight, Finder, Dock, Launchpad) expects its window.
/// A login item, a launchd job or the blocking guard starts it quietly in the menu bar.
/// Before T-062 every cold launch was quiet: the first Spotlight launch only started the
/// recorder, and the person had to launch it a second time (a reopen) to see the window.
enum LaunchWindowIntent: Equatable {
    case showWindow
    case quiet

    /// `oapp` with `keyAEPropData` = launched as login item (`lgit`) or service item (`lgsi`) is quiet.
    /// No launch event (process started by launchd or a shell) is quiet. Another `oapp` is a person.
    static func classify(eventClass: AEEventClass?, eventID: AEEventID?, launchedAs: OSType?,
                         isGuardRelaunch: Bool) -> LaunchWindowIntent {
        guard !isGuardRelaunch, eventClass == AEEventClass(kCoreEventClass),
              eventID == AEEventID(kAEOpenApplication) else { return .quiet }
        if let launchedAs, [OSType(keyAELaunchedAsLogInItem), OSType(keyAELaunchedAsServiceItem)].contains(launchedAs) {
            return .quiet
        }
        return .showWindow
    }

    /// Reads the event that launched the process. Call from `applicationWillFinishLaunching`.
    static func current(isGuardRelaunch: Bool = GoalongGuardFiles.isGuardRelaunch) -> LaunchWindowIntent {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAs = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        return classify(eventClass: event?.eventClass, eventID: event?.eventID, launchedAs: launchedAs,
                        isGuardRelaunch: isGuardRelaunch)
    }

    /// A second copy asks the running one to show its window. Activating an accessory app shows nothing.
    static let showWindowNotification = Notification.Name("\(ProductIdentity.bundleIdentifier).t062.show-window")

    static func askRunningCopyToShowWindow(center: DistributedNotificationCenter = .default()) {
        // Delivered even when the running copy is inactive (AppKit suspends delivery otherwise).
        center.postNotificationName(showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
#endif
