import Foundation

/// Release or `make dev` copy, read from the bundle's own Info.plist so every relaunch keeps it.
/// Without the keys (every release), paths and behaviour are the historical ones.
public struct GoalongBuildChannel: Equatable {
    public static let channelKey = "GoalongBuildChannel"
    public static let dataModeKey = "GoalongDevDataMode"
    public static let realDirectoryName = "LocalHistory"
    public static let isolatedDirectoryName = "LocalHistory-Dev"

    public enum DataMode: String, Equatable { case real, isolated }

    public let isDevelopment: Bool
    public let dataMode: DataMode

    public init(info: [String: Any]?) {
        isDevelopment = info?[Self.channelKey] as? String == "dev"
        // An unknown mode on a dev bundle stays isolated: never fall back to the real data by accident.
        dataMode = isDevelopment && info?[Self.dataModeKey] as? String != DataMode.real.rawValue ? .isolated : .real
    }

    public static let current = GoalongBuildChannel(info: Bundle.main.infoDictionary)

    public var dataDirectoryName: String { dataMode == .isolated ? Self.isolatedDirectoryName : Self.realDirectoryName }

    /// "Copie de développement · données isolées", or nil in a release.
    public var developmentLabel: String? {
        guard isDevelopment else { return nil }
        return "Copie de développement · " + (dataMode == .isolated ? "données isolées" : "vraies données")
    }

    public func windowTitle(_ title: String) -> String { isDevelopment ? title + " — Dev" : title }

    static var applicationSupportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The real `LocalHistory` folder. Blocking and its stakes always live here, even in a dev copy,
    /// so `make dev` can never become a way around an active block.
    public static var realDataRoot: URL {
        applicationSupportBase.appendingPathComponent(realDirectoryName, isDirectory: true)
    }

    /// Everything else the app writes: `LocalHistory-Dev` in an isolated dev copy.
    public static var dataRoot: URL { current.dataRoot(base: applicationSupportBase) }

    public func dataRoot(base: URL) -> URL { base.appendingPathComponent(dataDirectoryName, isDirectory: true) }
}
