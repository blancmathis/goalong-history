import Foundation
import CryptoKit

public struct GoalongDeveloperConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var projects: [GoalongDeveloperProject] = []
    public init() {}
}
public struct GoalongFileModificationBucket: Codable, Equatable, Sendable {
    public let projectID: String
    public let start: Date
    public let modifiedFiles: Int
    /// Replayed events have no original timestamp; counted at receipt, explicitly estimated.
    public let estimated: Bool
    public let lastEventID: UInt64
    public init(projectID: String, start: Date, modifiedFiles: Int, estimated: Bool, lastEventID: UInt64) {
        self.projectID = projectID; self.start = start; self.modifiedFiles = modifiedFiles
        self.estimated = estimated; self.lastEventID = lastEventID
    }
}
public struct GoalongFileModificationsDay: Equatable, Sendable {
    public let status: GoalongDeveloperLaneStatus
    public let buckets: [GoalongFileModificationBucket]
    public init(status: GoalongDeveloperLaneStatus, buckets: [GoalongFileModificationBucket]) { self.status = status; self.buckets = buckets }
    /// Sum of distinct files per five-minute bucket. A file may occur in several buckets.
    public var fileChanges: Int { buckets.reduce(0) { $0 + $1.modifiedFiles } }
}
public struct GoalongDeveloperCursor: Codable, Equatable, Sendable {
    public var version = 1
    public let projectSignature: String
    public let lastEventID: UInt64
    public init(projectSignature: String, lastEventID: UInt64) { self.projectSignature = projectSignature; self.lastEventID = lastEventID }
}

public final class GoalongDeveloperStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func configuration() throws -> GoalongDeveloperConfiguration {
        let file = root.appendingPathComponent("developer-projects.json")
        if !FileManager.default.fileExists(atPath: file.path) { return .init() }
        let data = try GoalongDeveloperFileIO.readOwned(name: "developer-projects.json", root: root, maximumBytes: 262_144)
        let value = try JSONDecoder().decode(GoalongDeveloperConfiguration.self, from: data)
        guard value.version == 1, value.projects.count <= 64,
              Set(value.projects.map(\.id)).count == value.projects.count,
              value.projects.allSatisfy({ $0.rootPath.hasPrefix("/") && $0.rootPath.utf8.count <= 4096 && $0.name.count <= 160 && $0.id == GoalongDeveloperProject.identifier(for: URL(fileURLWithPath: $0.rootPath)) && !$0.observationRoots.isEmpty && $0.observationRoots.count <= 16 && $0.observationRoots.allSatisfy { $0.hasPrefix("/") && $0.utf8.count <= 4096 } }) else { throw GoalongDeveloperFileIO.Failure.invalid }
        return value
    }
    public func add(_ directory: URL, name: String? = nil) throws {
        var config = try configuration()
        let project = GoalongDeveloperProject(root: directory, name: name)
        guard GoalongRepositoryResolver.commonGitDirectory(URL(fileURLWithPath: project.rootPath)) != nil else { throw GoalongDeveloperFileIO.Failure.invalid }
        if let index = config.projects.firstIndex(where: { $0.id == project.id }) {
            let previous = config.projects[index]
            let roots = Set(previous.observationRoots + project.observationRoots)
            guard roots.count <= 16 else { throw GoalongDeveloperFileIO.Failure.tooLarge }
            if roots == Set(previous.observationRoots) { return }
            config.projects[index] = GoalongDeveloperProject.combining([previous, project])!
            try save(config); return
        }
        guard config.projects.count < 64 else { throw GoalongDeveloperFileIO.Failure.tooLarge }
        config.projects.append(project)
        try save(config)
    }
    public func remove(projectID: String) throws {
        var config = try configuration(); config.projects.removeAll { $0.id == projectID }; try save(config)
    }
    private func save(_ config: GoalongDeveloperConfiguration) throws {
        try GoalongDeveloperFileIO.write(JSONEncoder().encode(config), name: "developer-projects.json", directory: root)
        NotificationCenter.default.post(name: .goalongDeveloperProjectsDidChange, object: root.path)
    }
    public var projectSignature: String { get throws {
        let text = try configuration().projects.map { $0.id + ":" + $0.observationRoots.sorted().joined(separator: ":") }.sorted().joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    } }
    public func cursor() throws -> GoalongDeveloperCursor? {
        let url = root.appendingPathComponent("developer-cursor.json")
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        let cursor = try JSONDecoder().decode(GoalongDeveloperCursor.self, from: GoalongDeveloperFileIO.readOwned(name: "developer-cursor.json", root: root, maximumBytes: 8192))
        guard cursor.version == 1 else { throw GoalongDeveloperFileIO.Failure.invalid }
        return cursor
    }
    public func saveCursor(_ cursor: GoalongDeveloperCursor) throws {
        try GoalongDeveloperFileIO.write(JSONEncoder().encode(cursor), name: "developer-cursor.json", directory: root)
    }
    public func append(_ buckets: [GoalongFileModificationBucket], day: Date, calendar: Calendar = .current) throws {
        guard buckets.count <= 64, buckets.allSatisfy({ $0.modifiedFiles >= 0 && $0.modifiedFiles <= 10_000 && $0.projectID.count == 64 && $0.projectID.allSatisfy(\.isHexDigit) }) else { throw GoalongDeveloperFileIO.Failure.invalid }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for bucket in buckets { data.append(try encoder.encode(bucket)); data.append(10) }
        try GoalongDeveloperFileIO.write(data, name: dayName(day, calendar: calendar) + ".jsonl", directory: root, childDirectory: "developer", append: true)
    }
    public func read(day: Date, calendar: Calendar = .current) -> GoalongFileModificationsDay {
        let file = root.appendingPathComponent("developer/" + dayName(day, calendar: calendar) + ".jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init(status: .noData, buckets: []) }
        do {
            let data = try GoalongDeveloperFileIO.readOwned(name: dayName(day, calendar: calendar) + ".jsonl", root: root, childDirectory: "developer", maximumBytes: 2_097_152)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let interval = calendar.dateInterval(of: .day, for: day) else { throw GoalongDeveloperFileIO.Failure.invalid }
            var values: [String: GoalongFileModificationBucket] = [:], partial = false
            for line in data.split(separator: 10) {
                guard values.count < 20_000, let row = try? decoder.decode(GoalongFileModificationBucket.self, from: Data(line)),
                      row.projectID.count == 64, row.projectID.allSatisfy(\.isHexDigit), row.modifiedFiles >= 0, row.modifiedFiles <= 10_000,
                      row.start >= interval.start, row.start < interval.end else { partial = true; continue }
                let key = row.projectID + "|\(row.start.timeIntervalSince1970)"
                // Cumulative snapshots replace one bucket rather than double-count every flush.
                values[key] = row
                partial = partial || row.estimated
            }
            return .init(status: partial ? .partial : (values.isEmpty ? .noData : .ready), buckets: values.values.sorted { $0.start < $1.start })
        } catch { return .init(status: .failed("Les compteurs de fichiers sont illisibles."), buckets: []) }
    }
    public func remove(day: Date, calendar: Calendar = .current) throws {
        let file = root.appendingPathComponent("developer/" + dayName(day, calendar: calendar) + ".jsonl")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func dayName(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
public extension Notification.Name {
    static let goalongDeveloperProjectsDidChange = Notification.Name("goalong.developer-projects.changed")
}
