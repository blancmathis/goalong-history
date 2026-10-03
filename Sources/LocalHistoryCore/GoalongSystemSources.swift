import Foundation
import Darwin

/// Each lane describes its own evidence; none contributes to foreground active time.
public enum GoalongSystemSourceStatus: Codable, Equatable, Sendable {
    case disabled, permissionDenied, unsupported, noData, partial, ready
    case failed(String)
}

public enum GoalongSourceIntervals {
    public static func unionSeconds(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard var last = sorted.first else { return 0 }
        var total: TimeInterval = 0
        for value in sorted.dropFirst() {
            if value.start <= last.end { last = DateInterval(start: last.start, end: max(last.end, value.end)) }
            else { total += last.duration; last = value }
        }
        return total + last.duration
    }
    public static func clipped(_ start: Date, _ end: Date, to day: DateInterval) -> DateInterval? {
        let lower = max(start, day.start), upper = min(end, day.end)
        return upper > lower ? DateInterval(start: lower, end: upper) : nil
    }
}

/// Small private stores. Paths are fixed by the caller, leaf names validated, links refused,
/// bytes bounded and stable reads verified. No source directory is created by a read.
public enum GoalongSystemSourceFiles {
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private static func checked(_ name: String) throws {
        guard !name.isEmpty, name.count <= 80, !name.contains("/"), !name.hasPrefix("."),
              name != ".." else { throw CocoaError(.fileReadInvalidFileName) }
    }
    private static func directory(root: URL, folder: String, create: Bool) throws -> Int32 {
        try checked(folder)
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CocoaError(errno == ENOENT ? .fileNoSuchFile : .fileReadNoPermission) }
        defer { close(parent) }
        if create, mkdirat(parent, folder, 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteNoPermission) }
        let fd = openat(parent, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(errno == ENOENT ? .fileNoSuchFile : .fileReadNoPermission) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd); throw CocoaError(.fileReadNoPermission)
        }
        return fd
    }
    public static func read(root: URL, folder: String, name: String, maximumBytes: Int) throws -> Data? {
        try checked(name)
        let dir: Int32
        do { dir = try directory(root: root, folder: folder, create: false) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return nil }
        defer { close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_uid == getuid(),
              before.st_mode & 0o777 == 0o600, before.st_size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw CocoaError(.fileReadUnknown) }
            if n == 0 { break }
            guard data.count + n <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(n))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, data.count == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    public static func write(_ data: Data, root: URL, folder: String, name: String, append: Bool = false, maximumBytes: Int) throws {
        try checked(name)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let dir = try directory(root: root, folder: folder, create: true); defer { close(dir) }
        let leaf = append ? name : "source-\(UUID().uuidString)"
        let fd = openat(dir, leaf, O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (append ? O_APPEND | O_CREAT : O_CREAT | O_EXCL), 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd); if !append { unlinkat(dir, leaf, 0) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, !append || info.st_size + Int64(data.count) <= maximumBytes else { throw CocoaError(.fileWriteNoPermission) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw CocoaError(.fileWriteUnknown) }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        if !append { guard renameat(dir, leaf, dir, name) == 0 else { throw CocoaError(.fileWriteUnknown) } }
    }
    public static func remove(root: URL, folder: String, name: String) throws {
        try checked(name)
        let dir: Int32
        do { dir = try directory(root: root, folder: folder, create: false) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        defer { close(dir) }
        guard unlinkat(dir, name, 0) == 0 || errno == ENOENT else { throw CocoaError(.fileWriteNoPermission) }
    }
}

public struct GoalongDayNote: Codable, Equatable, Sendable {
    public let version: Int
    public let day: String
    public let text: String
}
public enum GoalongDayNoteStore {
    public static let maximumCharacters = 280
    public static func get(root: URL, day: Date) throws -> String? {
        let key = GoalongSystemSourceFiles.dayKey(day)
        guard let bytes = try GoalongSystemSourceFiles.read(root: root, folder: "notes", name: key + ".json", maximumBytes: 4096) else { return nil }
        let note = try JSONDecoder().decode(GoalongDayNote.self, from: bytes)
        guard note.version == 1, note.day == key, note.text.count <= maximumCharacters else { throw CocoaError(.fileReadCorruptFile) }
        return note.text
    }
    public static func set(_ text: String, root: URL, day: Date) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= maximumCharacters else { throw NSError(domain: "GoalongDayNote", code: 280, userInfo: [NSLocalizedDescriptionKey: "Limite : 280 caractères."]) }
        if value.isEmpty { try delete(root: root, day: day); return }
        let key = GoalongSystemSourceFiles.dayKey(day)
        try GoalongSystemSourceFiles.write(JSONEncoder().encode(GoalongDayNote(version: 1, day: key, text: value)),
            root: root, folder: "notes", name: key + ".json", maximumBytes: 4096)
    }
    public static func delete(root: URL, day: Date) throws {
        try GoalongSystemSourceFiles.remove(root: root, folder: "notes", name: GoalongSystemSourceFiles.dayKey(day) + ".json")
    }
}

public struct GoalongCallInterval: Codable, Equatable, Sendable, Identifiable {
    public let start: Date
    public let end: Date
    public let bundleIdentifier: String?
    public let application: String?
    public let microphone: Bool
    public let camera: Bool
    public var interrupted: Bool = false
    public var id: String { "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(bundleIdentifier ?? "device")|\(microphone)|\(camera)" }
    public init(start: Date, end: Date, bundleIdentifier: String?, application: String?, microphone: Bool, camera: Bool, interrupted: Bool = false) {
        self.start = start; self.end = end; self.bundleIdentifier = bundleIdentifier; self.application = application
        self.microphone = microphone; self.camera = camera; self.interrupted = interrupted
    }
}
public struct GoalongCallLane: Equatable, Sendable {
    public let status: GoalongSystemSourceStatus
    public let intervals: [GoalongCallInterval]
    public var unionSeconds: TimeInterval { GoalongSourceIntervals.unionSeconds(intervals.map { DateInterval(start: $0.start, end: $0.end) }) }
    public var secondsPerApplication: [String: TimeInterval] {
        Dictionary(grouping: intervals, by: { $0.bundleIdentifier ?? $0.application ?? "unknown" })
            .mapValues { GoalongSourceIntervals.unionSeconds($0.map { DateInterval(start: $0.start, end: $0.end) }) }
    }
    public init(status: GoalongSystemSourceStatus, intervals: [GoalongCallInterval] = []) { self.status = status; self.intervals = intervals }
}
public enum GoalongCallStore {
    public static let maximumBytes = 2 * 1024 * 1024
    public static func save(_ value: GoalongCallInterval, root: URL, calendar: Calendar = .current) throws {
        guard value.end >= value.start, value.end.timeIntervalSince(value.start) <= 31 * 86400 else { throw CocoaError(.fileWriteUnknown) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var cursor = value.start
        repeat {
            guard let day = calendar.dateInterval(of: .day, for: cursor) else { return }
            let end = min(value.end, day.end)
            let row = GoalongCallInterval(start: cursor, end: end, bundleIdentifier: value.bundleIdentifier,
                application: value.application, microphone: value.microphone, camera: value.camera, interrupted: value.interrupted)
            try GoalongSystemSourceFiles.write(encoder.encode(row) + Data([10]), root: root, folder: "calls",
                name: GoalongSystemSourceFiles.dayKey(cursor, calendar: calendar) + ".jsonl", append: true, maximumBytes: maximumBytes)
            cursor = end
        } while cursor < value.end
    }
    public static func load(root: URL, day: Date, enabled: Bool, live: [GoalongCallInterval] = [], privacy: GoalongPrivacyPolicy = .init()) -> GoalongCallLane {
        guard enabled else { return .init(status: .disabled) }
        guard !privacy.blocked else { return .init(status: .failed("Exclusions illisibles.")) }
        do {
            let bytes = try GoalongSystemSourceFiles.read(root: root, folder: "calls", name: GoalongSystemSourceFiles.dayKey(day) + ".jsonl", maximumBytes: maximumBytes)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var rows = live
            if let bytes {
                guard bytes.isEmpty || bytes.last == 10 else { throw CocoaError(.fileReadCorruptFile) }
                let lines = bytes.split(separator: 10); guard lines.count <= 10_000 else { throw CocoaError(.fileReadTooLarge) }
                rows += try lines.map { try decoder.decode(GoalongCallInterval.self, from: Data($0)) }
            }
            guard let interval = Calendar.current.dateInterval(of: .day, for: day) else { return .init(status: .failed("Date invalide.")) }
            let interrupted = rows.contains { $0.interrupted }
            var clipped: [GoalongCallInterval] = []
            for row in rows {
                guard row.end >= row.start, row.end.timeIntervalSince(row.start) <= 31 * 86400,
                      (row.application?.count ?? 0) <= 256, (row.bundleIdentifier?.count ?? 0) <= 256 else { throw CocoaError(.fileReadCorruptFile) }
                guard !privacy.excludes(appID: row.bundleIdentifier, name: row.application),
                      let range = GoalongSourceIntervals.clipped(row.start, row.end, to: interval) else { continue }
                clipped.append(.init(start: range.start, end: range.end, bundleIdentifier: row.bundleIdentifier,
                                     application: row.application, microphone: row.microphone, camera: row.camera, interrupted: row.interrupted))
            }
            return .init(status: interrupted ? .partial : clipped.isEmpty ? .noData : .ready, intervals: clipped)
        } catch { return .init(status: .failed("Lecture des usages micro/caméra incomplète.")) }
    }
}
