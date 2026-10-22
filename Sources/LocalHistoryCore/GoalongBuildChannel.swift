import Foundation

/// Bundle identifiers of the Goalong family. "Me" (single instance, relaunch, permission recovery,
/// support) is the running copy's own identifier; "a Goalong app" (never blocked, never recorded)
/// is the whole family, so Goalong Dev and the installed Goalong never act on each other.
public enum GoalongBundleIdentity {
    public static let release = "ai.goalong.localhistory"
    public static let development = "ai.goalong.localhistory.dev"
    public static let family: [String] = [release, development]

    /// True for the installed Goalong and for Goalong Dev (case-insensitive, like bundle IDs).
    public static func isGoalong(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return family.contains { $0.caseInsensitiveCompare(identifier) == .orderedSame }
    }

    /// The running copy's own identifier. A process outside the family (tests, tools) is the release.
    public static func resolve(_ identifier: String?) -> String {
        guard let identifier, let own = family.first(where: { $0 == identifier }) else { return release }
        return own
    }

    public static let current = resolve(Bundle.main.bundleIdentifier)
}

/// Release or `make dev` copy (Goalong Dev), read from the bundle's own Info.plist so every relaunch keeps it.
/// Without the keys (every release), paths and behaviour are the historical ones.
public struct GoalongBuildChannel: Equatable {
    public static let channelKey = "GoalongBuildChannel"
    public static let dataModeKey = "GoalongDevDataMode"
    public static let sourceBranchKey = "GoalongDevSourceBranch"
    public static let sourceCommitKey = "GoalongDevSourceCommit"
    public static let builtAtKey = "GoalongDevBuiltAt"
    public static let serverKey = "GoalongDevServer"
    public static let realDirectoryName = "LocalHistory"
    public static let isolatedDirectoryName = "LocalHistory-Dev"

    public let isDevelopment: Bool
    /// How `make dev` seeded the dev data (`clone`, `keep`, `fresh`); nil in a release. Display only:
    /// a dev copy always uses `LocalHistory-Dev`, whatever this says.
    public let devDataMode: String?
    public let sourceBranch: String?
    public let sourceCommit: String?
    public let builtAt: String?
    /// `make dev SERVER=on`: the dev copy may talk to Goalong's servers. Never true by default.
    public let devServerEnabled: Bool

    public init(info: [String: Any]?) {
        let development = info?[Self.channelKey] as? String == "dev"
        isDevelopment = development
        func text(_ key: String) -> String? {
            guard development, let value = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        devDataMode = text(Self.dataModeKey)
        sourceBranch = text(Self.sourceBranchKey)
        sourceCommit = text(Self.sourceCommitKey)
        builtAt = text(Self.builtAtKey)
        devServerEnabled = development && (info?[Self.serverKey] as? Bool == true || info?[Self.serverKey] as? String == "on")
    }

    public static let current = GoalongBuildChannel(info: Bundle.main.infoDictionary)

    /// A dev copy never reads or writes the real `LocalHistory` folder.
    public var dataDirectoryName: String { isDevelopment ? Self.isolatedDirectoryName : Self.realDirectoryName }

    /// Releases always may; Goalong Dev only with `make dev SERVER=on`.
    public var allowsServerTraffic: Bool { !isDevelopment || devServerEnabled }

    /// Goalong Dev never registers or removes a login item: that belongs to the installed Goalong.
    public var allowsLoginItems: Bool { !isDevelopment }

    /// "Goalong Dev · main · 4cb75dc · données clone", or nil in a release.
    public var developmentLabel: String? {
        guard isDevelopment else { return nil }
        var parts = ["Goalong Dev"]
        if let sourceBranch { parts.append(sourceBranch) }
        if let sourceCommit { parts.append(sourceCommit) }
        parts.append("données " + (devDataMode ?? "isolées"))
        if devServerEnabled { parts.append("serveur actif") }
        return parts.joined(separator: " · ")
    }

    public func windowTitle(_ title: String) -> String { isDevelopment ? title + " — Dev" : title }

    /// Distinct menu bar autosave names, so Control Centre keeps one placement per copy.
    public func menuBarAutosaveName(_ base: String) -> String { isDevelopment ? base + "-dev" : base }

    static var applicationSupportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The real `LocalHistory` folder of the installed Goalong. Only used to recognise it, never written by Goalong Dev.
    public static var realDataRoot: URL {
        applicationSupportBase.appendingPathComponent(realDirectoryName, isDirectory: true)
    }

    /// Everything the app writes, Blocking and Focus included: `LocalHistory-Dev` in Goalong Dev.
    public static var dataRoot: URL { current.dataRoot(base: applicationSupportBase) }

    public func dataRoot(base: URL) -> URL { base.appendingPathComponent(dataDirectoryName, isDirectory: true) }
}

/// Thrown before any network operation when Goalong Dev runs without `make dev SERVER=on`.
public struct GoalongDevServerDisabledError: LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? {
        "Goalong Dev n’envoie rien aux serveurs (relancer avec make dev SERVER=on). Aucun envoi n’a été effectué."
    }

    /// Throws in Goalong Dev without SERVER=on; does nothing in a release.
    public static func check(_ channel: GoalongBuildChannel = .current) throws {
        guard channel.allowsServerTraffic else { throw GoalongDevServerDisabledError() }
    }
}
