import Foundation
import CryptoKit
import Darwin

/// A disposable checkpoint, never a retained account of a day. Its bounded event
/// window expires with detailed events; final summaries keep their separate policy.
public struct GoalongActivityCheckpointStore: Sendable {
    public static let suffix = ".resume.plist"
    public static let maximumBytes = 8 * 1_024 * 1_024
    private static let schema = "goalong.activity-resume.v1"
    public let root: URL
    public init(root: URL) { self.root = root }

    private struct Prefix: Codable {
        let name: String
        let device: Int64
        let inode: UInt64
        let count: Int64
        let digest: Data
    }
    private struct Envelope: Codable {
        let schema: String
        let method: String
        let payload: Data
        let digest: Data
        let prefixes: [Prefix]
    }

    /// ctime also detects an in-place edit whose mtime was restored. Capture before
    /// loading the source; a write is refused if anything changed before publication.
    public func sourceRevision(day: Date, calendar: Calendar = .current) -> String {
        let name = GoalongActivityDayStore.dayKey(day, calendar: calendar) + ".jsonl"
        var info = stat()
        guard lstat(root.appendingPathComponent("events/" + name).path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else { return "unavailable" }
        return "\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)|"
            + calendar.timeZone.identifier
    }

    public func read(day: Date, calendar: Calendar = .current,
                     shouldContinue: () -> Bool = { true }) throws -> GoalongLocalAnalytics.ResumableDayState {
        let store = GoalongActivityDayStore(root: root)
        let bytes = try store.readPrivateFile(name: name(day, calendar: calendar), maximumBytes: Self.maximumBytes)
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: bytes)
        guard envelope.schema == Self.schema, envelope.method == GoalongLocalAnalytics.method,
              Data(SHA256.hash(data: envelope.payload)) == envelope.digest else { throw GoalongActivityDayStore.Failure.invalidSummary }
        let state = try PropertyListDecoder().decode(GoalongLocalAnalytics.ResumableDayState.self, from: envelope.payload)
        guard state.isValidCheckpoint(day: day, calendar: calendar), let cursor = state.cursor,
              !cursor.files.isEmpty, cursor.files.count == envelope.prefixes.count else { throw GoalongActivityDayStore.Failure.invalidSummary }
        for (file, expected) in zip(cursor.files, envelope.prefixes) {
            guard file.name == expected.name, file.device == expected.device,
                  file.inode == expected.inode, file.consumedBytes == expected.count,
                  try prefix(file, shouldContinue: shouldContinue).digest == expected.digest else {
                throw GoalongActivityDayStore.Failure.sourceChanged
            }
        }
        return state
    }

    public func write(_ state: GoalongLocalAnalytics.ResumableDayState, day: Date, sourceRevision: String,
                      calendar: Calendar = .current, shouldContinue: () -> Bool = { true }) throws {
        guard state.isValidCheckpoint(day: day, calendar: calendar), let cursor = state.cursor,
              !cursor.files.isEmpty, shouldContinue(), sourceRevision == self.sourceRevision(day: day, calendar: calendar) else {
            throw GoalongActivityDayStore.Failure.sourceChanged
        }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload = try encoder.encode(state)
        guard payload.count <= Self.maximumBytes else { throw GoalongActivityDayStore.Failure.invalidSummary }
        let prefixes = try cursor.files.map { try prefix($0, shouldContinue: shouldContinue) }
        let bytes = try encoder.encode(Envelope(schema: Self.schema, method: GoalongLocalAnalytics.method,
            payload: payload, digest: Data(SHA256.hash(data: payload)), prefixes: prefixes))
        guard bytes.count <= Self.maximumBytes, shouldContinue(),
              sourceRevision == self.sourceRevision(day: day, calendar: calendar) else { throw GoalongActivityDayStore.Failure.sourceChanged }
        try GoalongActivityDayStore(root: root).writePrivateFile(bytes, name: name(day, calendar: calendar))
    }

    private func name(_ day: Date, calendar: Calendar) -> String {
        GoalongActivityDayStore.dayKey(day, calendar: calendar) + Self.suffix
    }

    private func prefix(_ file: HistoryLocalAnalyticsCursor.File, shouldContinue: () -> Bool) throws -> Prefix {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw GoalongActivityDayStore.Failure.unsafePath }
        defer { close(rootFD) }
        var info = stat()
        guard fstat(rootFD, &info) == 0, info.st_uid == getuid() else { throw GoalongActivityDayStore.Failure.unsafePath }
        let directory = openat(rootFD, "events", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw GoalongActivityDayStore.Failure.unsafePath }
        defer { close(directory) }
        let descriptor = openat(directory, file.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw GoalongActivityDayStore.Failure.unsafePath }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              Int64(info.st_dev) == file.device, UInt64(info.st_ino) == file.inode,
              info.st_size >= file.consumedBytes else { throw GoalongActivityDayStore.Failure.sourceChanged }
        var hash = SHA256(), offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while offset < file.consumedBytes {
            guard shouldContinue() else { throw GoalongActivityDayStore.Failure.sourceChanged }
            let count = pread(descriptor, &buffer, min(buffer.count, Int(file.consumedBytes - offset)), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GoalongActivityDayStore.Failure.sourceChanged }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            offset += Int64(count)
        }
        var after = stat(), path = stat()
        guard fstat(descriptor, &after) == 0, fstatat(directory, file.name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec,
              path.st_dev == info.st_dev, path.st_ino == info.st_ino else { throw GoalongActivityDayStore.Failure.sourceChanged }
        return Prefix(name: file.name, device: file.device, inode: file.inode, count: file.consumedBytes, digest: Data(hash.finalize()))
    }
}
