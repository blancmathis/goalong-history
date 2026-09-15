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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalHistory", isDirectory: true)
    }
    public static func file(in root: URL) -> URL { root.appendingPathComponent("global-pause.json") }
    private static let lock = NSLock()
    private struct Entry { let stamp: String; let value: GoalongGlobalPause }
    private static var cache: [String: Entry] = [:]
    private static var unavailable: Self {
        var value = Self(); value.paused = true; value.invalid = true; value.revision = "invalid"; return value
    }
    public static func load(in root: URL = defaultRoot) -> Self {
        let url = file(in: root), fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: url.path) }
        catch let error as NSError {
            return error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) ? Self() : unavailable
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 8192 else { return unavailable }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let stamp = "\(attributes[.systemFileNumber] ?? "none")-\(modified)-\(size)"
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
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = file(in: root), temporary = root.appendingPathComponent(".pause-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(next), attributes: [.posixPermissions: 0o600]) else { throw PauseError.writeFailed }
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: target) }
        lock.lock(); cache.removeValue(forKey: target.path); lock.unlock()
        guard load(in: root) == next else { throw PauseError.writeFailed }
        NotificationCenter.default.post(name: .goalongGlobalPauseDidChange, object: root.standardizedFileURL.path)
        return next
    }
    public enum PauseError: Error, LocalizedError {
        case active, changed, unreadable, writeFailed
        public var errorDescription: String? {
            switch self {
            case .active: return "Pause globale active : les sources et les envois sont suspendus."
            case .changed: return "La pause globale a changé. Recommencez cette action après la reprise."
            case .unreadable: return "Le réglage de pause est illisible. Goalong reste en pause par sécurité."
            case .writeFailed: return "Le changement de pause n’a pas pu être enregistré."
            }
        }
    }
}
