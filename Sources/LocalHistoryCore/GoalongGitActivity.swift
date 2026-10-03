import Foundation
import Darwin

public enum GoalongGitAction: String, Codable, CaseIterable, Sendable {
    case commit, amend, merge, rebase, checkout, reset, pull
    case cherryPick = "cherry-pick"
}
public struct GoalongGitActivity: Equatable, Sendable {
    public struct Action: Equatable, Sendable {
        public let time: Date
        public let kind: GoalongGitAction
    }
    public let project: GoalongDeveloperProject
    public let status: GoalongDeveloperLaneStatus
    public let actions: [Action]
    public var commits: [Date] { actions.filter { $0.kind == .commit || $0.kind == .amend }.map(\.time) }
    public var firstActivity: Date? { actions.first?.time }
    public var lastActivity: Date? { actions.last?.time }
    public let fingerprint: String
}

public enum GoalongGitActivityReader {
    public struct Limits {
        public var maximumFiles = 256
        public var maximumBytesPerFile = 262_144
        public var maximumRows = 20_000
        public var maximumSeconds: TimeInterval = 2
        public init() {}
    }
    private static func logFiles(_ git: URL, maximum: Int, deadline: Date, shouldContinue: () -> Bool) -> ([URL], Bool) {
        var files = [git.appendingPathComponent("logs/HEAD")], partial = false, visited = 0
        let heads = git.appendingPathComponent("logs/refs/heads")
        if FileManager.default.fileExists(atPath: heads.path) {
            if let enumerator = FileManager.default.enumerator(at: heads, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                while let url = enumerator.nextObject() as? URL {
                    guard visited < 4096, files.count < maximum, Date() < deadline, shouldContinue() else { partial = true; break }
                    visited += 1
                    guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { partial = true; continue }
                    if value.isSymbolicLink == true { enumerator.skipDescendants(); partial = true }
                    else if value.isRegularFile == true { files.append(url) }
                }
            } else { partial = true }
        }
        let worktrees = git.appendingPathComponent("worktrees")
        if FileManager.default.fileExists(atPath: worktrees.path) {
            if let enumerator = FileManager.default.enumerator(at: worktrees, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                while let child = enumerator.nextObject() as? URL {
                    enumerator.skipDescendants()
                    guard visited < 4096, files.count < maximum, Date() < deadline, shouldContinue() else { partial = true; break }
                    visited += 1
                    let value = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if value?.isDirectory == true && value?.isSymbolicLink != true { files.append(child.appendingPathComponent("logs/HEAD")) }
                    else { partial = true }
                }
            } else { partial = true }
        }
        return (Array(Set(files)).sorted { $0.path < $1.path }, partial)
    }
    private static func stamp(_ files: [URL], partial: Bool) -> String {
        let stamps = files.map { file -> String in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return "missing" }
            return "\(file.path):\(attributes[.systemFileNumber] ?? 0):\(attributes[.size] ?? 0):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        return GoalongDeveloperProject.identifier(for: URL(fileURLWithPath: "/" + stamps.joined(separator: "|") + "|\(partial)"))
    }
    public static func sourceFingerprint(project: GoalongDeveloperProject) -> String {
        guard let git = GoalongRepositoryResolver.commonGitDirectory(URL(fileURLWithPath: project.rootPath)) else { return "missing-git" }
        let source = logFiles(git, maximum: 256, deadline: Date().addingTimeInterval(2), shouldContinue: { true })
        return stamp(source.0, partial: source.1)
    }
    public static func read(project: GoalongDeveloperProject, day: Date, calendar: Calendar = .current,
                            limits: Limits = Limits(), shouldContinue: () -> Bool = { true }) -> GoalongGitActivity {
        let root = URL(fileURLWithPath: project.rootPath)
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor < 0 && (errno == EACCES || errno == EPERM) { return .init(project: project, status: .permissionDenied, actions: [], fingerprint: "denied") }
        if descriptor >= 0 { close(descriptor) }
        guard let interval = calendar.dateInterval(of: .day, for: day),
              let git = GoalongRepositoryResolver.commonGitDirectory(URL(fileURLWithPath: project.rootPath)) else {
            return .init(project: project, status: .unsupported, actions: [], fingerprint: "missing-git")
        }
        let deadline = Date().addingTimeInterval(max(0, limits.maximumSeconds))
        let source = logFiles(git, maximum: max(1, limits.maximumFiles), deadline: deadline, shouldContinue: shouldContinue)
        let initial = stamp(source.0, partial: source.1)
        var partial = source.1, actions: [GoalongGitActivity.Action] = [], seen = Set<String>(), rows = 0
        for file in source.0 {
            guard Date() < deadline, shouldContinue() else { partial = true; break }
            if !FileManager.default.fileExists(atPath: file.path) { continue }
            do {
                let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                if size > limits.maximumBytesPerFile { partial = true }
                let data = try GoalongDeveloperFileIO.readFile(file, maximumBytes: max(1, limits.maximumBytesPerFile), tail: true)
                for line in data.split(separator: 10) {
                    guard rows < max(1, limits.maximumRows), Date() < deadline, shouldContinue() else { partial = true; break }
                    rows += 1
                    guard let tab = line.firstIndex(of: 9) else { partial = true; continue }
                    let metadata = line[..<tab].split(separator: 32)
                    guard metadata.count >= 5, let seconds = TimeInterval(String(decoding: metadata[metadata.count - 2], as: UTF8.self)) else { partial = true; continue }
                    let date = Date(timeIntervalSince1970: seconds)
                    guard date >= interval.start, date < interval.end else { continue }
                    // Decode only the action prefix before ':', never the subject after it.
                    let actionBytes = line[line.index(after: tab)...].prefix(while: { $0 != 58 }).prefix(32)
                    let word = String(decoding: actionBytes, as: UTF8.self)
                    let kind: GoalongGitAction?
                    if word == "commit (amend)" { kind = .amend }
                    else if word.hasPrefix("commit") { kind = .commit }
                    else { kind = GoalongGitAction(rawValue: word.split(separator: " ").first.map(String.init) ?? "") }
                    guard let kind else { continue }
                    let hash = String(decoding: metadata[1], as: UTF8.self)
                    let key = (kind == .commit || kind == .amend) ? "commit|\(hash)" : "\(kind.rawValue)|\(hash)|\(seconds)"
                    if seen.insert(key).inserted { actions.append(.init(time: date, kind: kind)) }
                }
            } catch { partial = true }
        }
        if stamp(source.0, partial: source.1) != initial { partial = true }
        actions.sort { $0.time == $1.time ? $0.kind.rawValue < $1.kind.rawValue : $0.time < $1.time }
        return .init(project: project, status: partial ? .partial : (actions.isEmpty ? .noData : .ready), actions: actions, fingerprint: initial)
    }
}
