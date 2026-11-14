#if os(macOS)
    import AppKit
    import AppleScreenTime
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

        /// A short, fixed word for the launch event's property, for the support journal.
        static func flagName(of event: NSAppleEventDescriptor?) -> String {
            switch launchProperty(of: event) {
            case nil: return "none"
            case OSType(keyAELaunchedAsLogInItem): return "loginItem"
            case OSType(keyAELaunchedAsServiceItem): return "serviceItem"
            default: return "other"
            }
        }

        /// A fixed word for the origin, for the support journal.
        var journalName: String {
            switch self {
            case .member: return "member"
            case .loginItem: return "loginItem"
            case .serviceItem: return "serviceItem"
            case .guardRelaunch: return "guardRelaunch"
            case .document: return "document"
            case .unknown: return "unknown"
            }
        }
    }

    /// When the member's graphical session began, and which source said so.
    struct SessionStart: Equatable {
        enum Source: String { case console, loginWindow, boot }
        var date: Date
        var source: Source
    }

    enum LaunchPresentation {
        static let quietRelaunchKey = "goalong.quietRelaunchUntil"
        /// The first minutes of a session are its login items and restored apps. A session starts at boot
        /// or at a login without reboot (logout, then login). An `SMAppService` login item does not always
        /// carry the login-item flag in its launch event, so the session's age decides as well.
        static let sessionQuietPeriod: TimeInterval = 120
        /// How long Sparkle's relaunch stays quiet. The marker is written when the old copy quits.
        static let quietRelaunchDuration: TimeInterval = 120

        /// True only for a clear member's open: a plain open event, outside the session's first minutes.
        /// Unknown session start = not clear: the window stays closed (a second open still shows it).
        static func isClearMemberOpen(origin: LaunchOrigin, now: Date, sessionStart: SessionStart?) -> Bool {
            guard origin == .member, let sessionStart else { return false }
            // A start dated in the future (clock set back) also stays quiet.
            return sessionStart.date.addingTimeInterval(sessionQuietPeriod) <= now
        }

        /// True when a cold launch must show the dashboard by itself. The second copy asks the same
        /// question before it posts its "show window" request.
        static func showsDashboardAtLaunch(origin: LaunchOrigin, quietRelaunchUntil: Double, now: Date,
                                           sessionStart: SessionStart?) -> Bool {
            // Sparkle relaunches through Launch Services like a member's open: it stays quiet.
            if quietRelaunchIsActive(until: quietRelaunchUntil, now: now) { return false }
            return isClearMemberOpen(origin: origin, now: now, sessionStart: sessionStart)
        }

        static func quietRelaunchIsActive(until: Double, now: Date) -> Bool { until > now.timeIntervalSince1970 }

        /// Written when the old copy quits for an update; read by both copies, never consumed by them.
        static func armQuietRelaunch(defaults: UserDefaults = GoalongDefaults.standard, now: Date = Date()) {
            defaults.set(now.addingTimeInterval(quietRelaunchDuration).timeIntervalSince1970, forKey: quietRelaunchKey)
        }

        /// Cleared when Sparkle aborts, when the copy quits for another reason, and when it is stale.
        static func clearQuietRelaunch(defaults: UserDefaults = GoalongDefaults.standard) {
            defaults.removeObject(forKey: quietRelaunchKey)
        }

        static func quietRelaunchUntil(defaults: UserDefaults = GoalongDefaults.standard) -> Double {
            defaults.double(forKey: quietRelaunchKey)
        }

        /// A second copy (Spotlight while the first one starts or right after an update) asks the
        /// running copy to show its window. `activate()` alone shows nothing for a menu-bar app.
        static func showRequestName(bundleIdentifier: String) -> Notification.Name {
            Notification.Name("\(bundleIdentifier).show-dashboard-request")
        }

        /// One record per cold launch (first or second copy): why the window opens or stays closed.
        static func recordLaunch(origin: LaunchOrigin, eventFlag: String, sessionStart: SessionStart?,
                                 quietRelaunchUntil: Double, now: Date, shows: Bool, secondCopy: Bool) {
            var values: [SupportKey: SupportValue] = [
                .launchOrigin: .symbol(origin.journalName),
                .launchEventFlag: .symbol(eventFlag),
                .quietRelaunch: .flag(quietRelaunchIsActive(until: quietRelaunchUntil, now: now)),
                .windowShown: .flag(shows),
                .secondCopy: .flag(secondCopy),
                .sessionSource: .symbol(sessionStart?.source.rawValue ?? "unknown"),
            ]
            if let sessionStart { values[.sessionAgeSeconds] = .count(Int(now.timeIntervalSince(sessionStart.date))) }
            SupportDiagnostics.shared.record(.launchPresented, component: .app, values: values)
        }
    }

    /// T-062: when the member's graphical session started. Chain: the `console` login in utmpx (as `who`
    /// shows it), then the launch time of `loginwindow`, then the boot time. A logout then login without
    /// reboot writes a new console record, so login items after it stay quiet too.
    enum LoginSession {
        struct Record: Equatable {
            var isUserProcess: Bool
            var line: String
            var user: String
            var date: Date
            /// The uid of `user` (getpwnam), so a record under another spelling of the account still counts.
            var uid: UInt32? = nil
        }

        /// The most recent console login of the member; nil when there is none. A record matches by
        /// account name or by uid.
        static func latestConsoleLogin(_ records: [Record], user: String, uid: UInt32? = nil) -> Date? {
            records.filter {
                $0.isUserProcess && $0.line == "console"
                    && ($0.user == user || (uid != nil && $0.uid == uid))
            }.map(\.date).max()
        }

        /// Pure part of the chain. A console record older than the boot is a leftover: the next source decides.
        static func sessionStart(records: [Record], user: String, uid: UInt32?,
                                 loginWindowLaunch: Date?, bootTime: Date?) -> SessionStart? {
            if let console = latestConsoleLogin(records, user: user, uid: uid),
               bootTime.map({ $0 <= console }) ?? true {
                return SessionStart(date: console, source: .console)
            }
            if let loginWindowLaunch { return SessionStart(date: loginWindowLaunch, source: .loginWindow) }
            if let bootTime { return SessionStart(date: bootTime, source: .boot) }
            return nil
        }

        static func current(user: String = NSUserName(), uid: UInt32 = UInt32(getuid())) -> SessionStart? {
            sessionStart(records: readRecords(), user: user, uid: uid,
                         loginWindowLaunch: loginWindowLaunchDate(), bootTime: bootTime())
        }

        static func bootTime() -> Date? {
            var value = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
        }

        /// `loginwindow` starts with the graphical session; the most recent one is the current session's.
        static func loginWindowLaunchDate() -> Date? {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow")
                .compactMap(\.launchDate).max()
        }

        private static func readRecords() -> [Record] {
            setutxent()
            defer { endutxent() }
            var records: [Record] = []
            while let entry = getutxent() {
                let raw = entry.pointee
                let user = string(raw.ut_user)
                records.append(Record(
                    isUserProcess: Int32(raw.ut_type) == USER_PROCESS,
                    line: string(raw.ut_line), user: user,
                    date: Date(timeIntervalSince1970: TimeInterval(raw.ut_tv.tv_sec)
                        + TimeInterval(raw.ut_tv.tv_usec) / 1_000_000),
                    uid: user.isEmpty ? nil : getpwnam(user)?.pointee.pw_uid))
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
