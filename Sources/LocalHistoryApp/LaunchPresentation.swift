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
                     launchProperty: launchProperty(of: event))
        }

        /// The login-item flag comes as an enumerated or a type value, depending on who launched us.
        static func launchProperty(of event: NSAppleEventDescriptor?) -> OSType? {
            guard let property = event?.paramDescriptor(forKeyword: keyAEPropData) else { return nil }
            let code = property.enumCodeValue
            return code != 0 ? code : property.typeCodeValue
        }
    }

    enum LaunchPresentation {
        static let quietRelaunchKey = "goalong.quietRelaunchUntil"
        /// The first minutes of a session are its login items and restored apps. A session starts at boot
        /// or at a login without reboot (logout, then login). An `SMAppService` login item does not always
        /// carry the login-item flag in its launch event, so the session's age decides as well.
        static let sessionQuietPeriod: TimeInterval = 120

        /// True only for a clear member's open: a plain open event, outside the session's first minutes.
        /// Unknown login time = not clear: the window stays closed (a second open still shows it).
        static func isClearMemberOpen(origin: LaunchOrigin, now: Date, systemUptime: TimeInterval,
                                      sessionLogin: Date?) -> Bool {
            guard origin == .member, systemUptime >= sessionQuietPeriod, let sessionLogin else { return false }
            // A login dated in the future (clock set back) also stays quiet.
            return sessionLogin.addingTimeInterval(sessionQuietPeriod) <= now
        }

        /// True when a cold launch must show the dashboard by itself.
        static func showsDashboardAtLaunch(origin: LaunchOrigin, quietRelaunchUntil: Double, now: Date,
                                           systemUptime: TimeInterval, sessionLogin: Date?) -> Bool {
            // Sparkle relaunches through Launch Services like a member's open: it stays quiet.
            if quietRelaunchUntil > now.timeIntervalSince1970 { return false }
            return isClearMemberOpen(origin: origin, now: now, systemUptime: systemUptime, sessionLogin: sessionLogin)
        }

        /// A second copy (Spotlight while the first one starts or right after an update) asks the
        /// running copy to show its window. `activate()` alone shows nothing for a menu-bar app.
        static func showRequestName(bundleIdentifier: String) -> Notification.Name {
            Notification.Name("\(bundleIdentifier).show-dashboard-request")
        }
    }

    /// T-062: when the member's graphical session started (the `console` login in utmpx, as `who` shows it).
    /// A logout then login without reboot writes a new record, so login items after it stay quiet too.
    enum LoginSession {
        struct Record: Equatable {
            var isUserProcess: Bool
            var line: String
            var user: String
            var date: Date
        }

        /// The most recent console login of `user`; nil when there is none.
        static func latestConsoleLogin(_ records: [Record], user: String) -> Date? {
            records.filter { $0.isUserProcess && $0.line == "console" && $0.user == user }.map(\.date).max()
        }

        static func consoleLoginDate(user: String = NSUserName()) -> Date? {
            latestConsoleLogin(readRecords(), user: user)
        }

        private static func readRecords() -> [Record] {
            setutxent()
            defer { endutxent() }
            var records: [Record] = []
            while let entry = getutxent() {
                let raw = entry.pointee
                records.append(Record(
                    isUserProcess: Int32(raw.ut_type) == USER_PROCESS,
                    line: string(raw.ut_line), user: string(raw.ut_user),
                    date: Date(timeIntervalSince1970: TimeInterval(raw.ut_tv.tv_sec)
                        + TimeInterval(raw.ut_tv.tv_usec) / 1_000_000)))
            }
            return records
        }

        private static func string<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }
#endif
