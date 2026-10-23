import Foundation

/// Closed table of the copies that may own a blocking guard. Every name the guard uses (launchd label,
/// Mach service, embedded plist, data root, relaunched bundle) derives from the copy's own bundle id,
/// so the installed Goalong's guard never sees Goalong Dev, and the reverse.
public struct GuardIdentity: Equatable, Sendable {
    public static let releaseBundleIdentifier = "ai.goalong.localhistory"
    public static let developmentBundleIdentifier = "ai.goalong.localhistory.dev"
    /// Distinct from the retired LifeOS `goalong-guard.sh`.
    public static let executableName = "goalong-blocking-guard"
    /// Passed to the app the guard relaunches: no window, no banner.
    public static let relaunchArgument = "--guard-relaunch"
    /// Exit code asking launchd to start the replaced binary.
    public static let replacedExitCode: Int32 = 75

    public let bundleIdentifier: String
    /// `<bundle id>.blocking-guard`: label, Mach service and plist name. Never the bundle id itself.
    public let label: String
    /// Folder under `~/Library/Application Support`: `LocalHistory` or `LocalHistory-Dev`.
    public let dataDirectoryName: String

    /// Info.plist key that sends a copy to `LocalHistory-Dev` (same key as `GoalongBuildChannel`).
    public static let channelKey = "GoalongBuildChannel"

    /// `channel` is the bundle's `GoalongBuildChannel` value. The app picks its data folder from the
    /// channel; the guard requires the bundle id to agree, otherwise it acts on nothing (fail open).
    public init?(bundleIdentifier: String?, channel: String? = nil) {
        switch (bundleIdentifier, channel == "dev") {
        case (Self.releaseBundleIdentifier?, false): dataDirectoryName = "LocalHistory"
        case (Self.developmentBundleIdentifier?, true): dataDirectoryName = "LocalHistory-Dev"
        default: return nil
        }
        self.bundleIdentifier = bundleIdentifier!
        label = bundleIdentifier! + ".blocking-guard"
    }

    public var machServiceName: String { label }
    public var plistName: String { label + ".plist" }
    public var logSubsystem: String { label }

    public func dataRoot(base: URL) -> URL { base.appendingPathComponent(dataDirectoryName, isDirectory: true) }
    public func blockingDirectory(base: URL) -> URL { dataRoot(base: base).appendingPathComponent("Blocking", isDirectory: true) }

    /// `~/Library/Application Support` of the user running this process (honours CFFIXED_USER_HOME in tests),
    /// with symlinks resolved once: GuardFiles then opens every component without following links.
    public static var applicationSupportBase: URL {
        GuardSystem.realPath(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
}

/// Paths of one installed copy, all derived from the bundle that contains the guard.
public struct GuardBundle: Equatable, Sendable {
    public let appURL: URL
    public let identity: GuardIdentity
    public let executableName: String

    /// Validates `…/X.app/Contents/MacOS/goalong-blocking-guard` inside a known, non-translocated Goalong.
    public init?(guardExecutable: URL, info: (URL) -> [String: Any]? = { NSDictionary(contentsOf: $0) as? [String: Any] }) {
        let macOS = guardExecutable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard guardExecutable.lastPathComponent == GuardIdentity.executableName, macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents", app.pathExtension == "app",
              !app.path.contains("/AppTranslocation/"),
              let plist = info(contents.appendingPathComponent("Info.plist")),
              let identity = GuardIdentity(bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                                           channel: plist[GuardIdentity.channelKey] as? String),
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/")
        else { return nil }
        appURL = app; self.identity = identity; executableName = executable
    }

    public var infoPlist: URL { appURL.appendingPathComponent("Contents/Info.plist") }
    public var appExecutable: URL { appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName) }
    /// Sparkle's installer inside this very bundle: proof of an update lease.
    public var autoupdate: URL { appURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate") }
    /// The permission relauncher inside this very bundle: proof of a permission-restart lease.
    public var relauncher: URL { appURL.appendingPathComponent("Contents/MacOS/goalong-relauncher") }

    /// The process that must be alive for a lease with this reason to be honoured.
    public func proofPath(for reason: String) -> String? {
        switch reason {
        case GuardLease.update: return autoupdate.path
        case GuardLease.permissionRestart: return relauncher.path
        default: return nil
        }
    }
}
