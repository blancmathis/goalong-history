import Foundation
import CryptoKit

/// Independent evidence lanes; none of these durations contribute to Mac active time.
public enum GoalongDeveloperLaneStatus: Equatable, Sendable {
    case disabled, permissionDenied, unsupported, noData, partial, ready
    case failed(String)
    public var label: String {
        switch self {
        case .disabled: return "Désactivé"
        case .permissionDenied: return "Accès refusé"
        case .unsupported: return "Format non pris en charge"
        case .noData: return "Aucune donnée"
        case .partial: return "Données partielles"
        case .ready: return "Disponible"
        case .failed(let reason): return reason
        }
    }
}

public struct GoalongDeveloperProject: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Only explicit project selection persists this path, never the file activity journal.
    public let rootPath: String
    public var watchRootPaths: [String]? = nil
    public var observationRoots: [String] { watchRootPaths ?? [rootPath] }
    public init(root: URL, name: String? = nil) {
        let canonical = GoalongRepositoryResolver.canonicalRoot(root)
        rootPath = canonical.path
        id = Self.identifier(for: canonical)
        self.name = String((name ?? canonical.lastPathComponent).prefix(160))
        let working = GoalongRepositoryResolver.workingRoot(root).path
        if working != canonical.path { watchRootPaths = [working] }
    }
    public static func combining(_ projects: [Self]) -> Self? {
        guard var result = projects.first else { return nil }
        result.watchRootPaths = Array(Set(projects.flatMap(\.observationRoots))).sorted().prefix(16).map { $0 }
        return result
    }
    public static func identifier(for root: URL) -> String {
        SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum GoalongRepositoryResolver {
    public static func workingRoot(_ directory: URL) -> URL {
        let original = directory.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = original
        for _ in 0..<32 {
            if commonGitDirectory(candidate) != nil { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return original
    }
    /// Resolve a linked worktree using gitdir/commondir; never execute Git or inspect history.
    public static func canonicalRoot(_ directory: URL) -> URL {
        let original = directory.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = original
        for _ in 0..<32 {
            if let common = commonGitDirectory(candidate) {
                return common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return original
    }
    public static func commonGitDirectory(_ root: URL) -> URL? {
        let dot = root.appendingPathComponent(".git")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dot.path, isDirectory: &directory) else { return nil }
        var git = dot
        if !directory.boolValue {
            guard let data = try? GoalongDeveloperFileIO.readFile(dot, maximumBytes: 8192),
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
            let path = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            git = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        }
        let commonFile = git.appendingPathComponent("commondir")
        if FileManager.default.fileExists(atPath: commonFile.path) {
            guard let data = try? GoalongDeveloperFileIO.readFile(commonFile, maximumBytes: 8192),
                  let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            git = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : git.appendingPathComponent(path)).standardizedFileURL
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return git.resolvingSymlinksInPath()
    }
}

public enum GoalongDeveloperIntervals {
    public static func clipped(_ interval: DateInterval, to day: DateInterval) -> DateInterval? {
        let start = max(interval.start, day.start), end = min(interval.end, day.end)
        return end > start ? DateInterval(start: start, end: end) : nil
    }
    public static func unionSeconds(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return 0 }
        var seconds: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end { current = DateInterval(start: current.start, end: max(current.end, interval.end)) }
            else { seconds += current.duration; current = interval }
        }
        return seconds + current.duration
    }
    public static func maximumParallel(_ intervals: [DateInterval]) -> Int {
        var points: [(Date, Int)] = []
        for interval in intervals where interval.duration > 0 { points.append((interval.start, 1)); points.append((interval.end, -1)) }
        points.sort { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        var count = 0, maximum = 0
        for point in points { count += point.1; maximum = max(maximum, count) }
        return maximum
    }
}
