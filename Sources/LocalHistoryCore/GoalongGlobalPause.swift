import Foundation

public extension Notification.Name {
    static let goalongGlobalPauseDidChange = Notification.Name("goalong.global-pause.changed")
}

/// Persistent runtime pause, independent of source and sharing preferences.
public struct GoalongGlobalPause: Codable, Equatable {
    public var version = 1
    public var paused = false
    public var revision = "initial"
    public var changedAt: Date?
    public var recordingWasPaused = false
    public var invalid = false
    public init() {}
    public var blocksActivity: Bool { paused || invalid }
    public static var defaultRoot: URL {
        GoalongBuildChannel.dataRoot
    }
    public static func file(in root: URL) -> URL { root.appendingPathComponent("global-pause.json") }
    private static let lock = NSLock()
    private struct Entry { let stamp: String; let value: GoalongGlobalPause }
    private static var cache: [String: Entry] = [:]
    private static var unavailable: Self {
        var value = Self(); value.paused = true; value.invalid = true; value.revision = "invalid"; return value
    }
    public static func load(in root: URL = defaultRoot) -> Self {
        let url = file(in: root)
        // Read on every recorded event: a bare lstat costs ~1 µs, attributesOfItem ~36 µs.
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return errno == ENOENT ? Self() : unavailable }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size > 0, status.st_size <= 8192 else { return unavailable }
        let stamp = "\(status.st_ino)-\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)-\(status.st_size)"
        lock.lock(); defer { lock.unlock() }
        if let entry = cache[url.path], entry.stamp == stamp { return entry.value }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return unavailable }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 8193), bytes.count <= 8192,
              let value = try? JSONDecoder().decode(Self.self, from: bytes), value.version == 1,
              !value.revision.isEmpty else { return unavailable }
        if cache.count > 32 { cache.removeAll() }
        cache[url.path] = Entry(stamp: stamp, value: value)
        return value
    }
    public static func isPaused(in root: URL = defaultRoot) -> Bool { load(in: root).blocksActivity }
    public static func admit(in root: URL = defaultRoot) throws -> String {
        let value = load(in: root)
        guard !value.blocksActivity else { throw PauseError.active }
        return value.revision
    }
    public static func revalidate(_ revision: String, in root: URL = defaultRoot) throws {
        let current = load(in: root)
        guard !current.blocksActivity, current.revision == revision else { throw PauseError.changed }
    }
    @discardableResult public static func setPaused(_ paused: Bool, in root: URL = defaultRoot,
                                                   recordingWasPaused: Bool? = nil) throws -> Self {
        let previous = load(in: root)
        guard !previous.invalid else { throw PauseError.unreadable }
        if previous.paused == paused { return previous }
        var next = previous
        next.paused = paused; next.revision = UUID().uuidString; next.changedAt = Date()
        if paused { next.recordingWasPaused = recordingWasPaused ?? false }
        try write(next, in: root)
        NotificationCenter.default.post(name: .goalongGlobalPauseDidChange, object: root.standardizedFileURL.path)
        return next
    }
    private static func write(_ next: Self, in root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = file(in: root), temporary = root.appendingPathComponent(".pause-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(next), attributes: [.posixPermissions: 0o600]) else { throw PauseError.writeFailed }
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: target) }
        lock.lock(); cache.removeValue(forKey: target.path); lock.unlock()
        guard load(in: root) == next else { throw PauseError.writeFailed }
    }
    /// Sets an unreadable pause file aside (as `SharingRulesStore` does) and resumes with a fresh revision.
    /// A readable file is never touched: only a damaged one can be repaired.
    @discardableResult public static func repairAndResume(in root: URL = defaultRoot) throws -> Self {
        guard load(in: root).invalid else { throw PauseError.notDamaged }
        let fm = FileManager.default, target = file(in: root)
        if (try? fm.attributesOfItem(atPath: target.path)) != nil {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            var name = "global-pause.damaged-\(stamp).json", index = 1
            while (try? fm.attributesOfItem(atPath: root.appendingPathComponent(name).path)) != nil {
                name = "global-pause.damaged-\(stamp)-\(index).json"; index += 1
            }
            let aside = root.appendingPathComponent(name)
            try fm.moveItem(at: target, to: aside)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path)
            lock.lock(); cache.removeValue(forKey: target.path); lock.unlock()
        }
        var next = Self()
        next.revision = UUID().uuidString; next.changedAt = Date()
        try write(next, in: root)
        NotificationCenter.default.post(name: .goalongGlobalPauseDidChange, object: root.standardizedFileURL.path)
        return next
    }
    public enum PauseError: Error, LocalizedError {
        case active, changed, unreadable, notDamaged, writeFailed
        public var errorDescription: String? {
            switch self {
            case .active: return "Pause globale active : les sources et les envois sont suspendus."
            case .changed: return "La pause globale a changé. Recommencez cette action après la reprise."
            case .unreadable: return "Le réglage de pause est abîmé. Goalong reste en pause par sécurité : utilisez « Réparer et reprendre »."
            case .notDamaged: return "Le réglage de pause n’est pas abîmé : rien à réparer."
            case .writeFailed: return "Le changement de pause n’a pas pu être enregistré."
            }
        }
    }
}
