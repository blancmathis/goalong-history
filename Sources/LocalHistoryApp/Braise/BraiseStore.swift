#if os(macOS)
import BraiseCore
import Darwin
import Foundation

/// No I/O in init. The legacy file is read once, on the first explicit enable.
struct BraiseStore {
    let directory: URL
    let legacySettings: URL
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    func load() throws -> Preferences { try loadRecovering().preferences }

    /// An unreadable settings file is moved aside and Braise starts with default settings;
    /// an unreadable legacy file is left untouched and simply not imported. Only a folder
    /// that cannot be used still fails. `notice` tells the user what was reset.
    func loadRecovering() throws -> (preferences: Preferences, notice: String?) {
        guard Self.isFreeOfSymlinks(directory) else { throw CocoaError(.fileReadNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var value: Preferences
        var notice: String?
        if Self.exists(settingsURL) {
            if let decoded = try? Self.decode(settingsURL) { value = decoded } else {
                let name = try Self.moveDamagedFileAside(settingsURL)
                notice = "Les réglages Braise étaient illisibles : ils ont été remis à zéro. L’ancien fichier est gardé dans \(directory.path)/\(name)."
                value = Preferences(); value.sanitize()
                try save(value)
            }
        } else {
            if Self.exists(legacySettings) {
                if let decoded = try? Self.decode(legacySettings) { value = decoded } else {
                    value = Preferences()
                    notice = "Les anciens réglages Braise sont illisibles : Braise démarre avec les réglages par défaut."
                }
            } else { value = Preferences() }
            value.sanitize()
            try save(value)
        }
        value.sanitize()
        var ids = Set<UUID>()
        value.rules = value.rules.filter { ids.insert($0.id).inserted }
        return (value, notice)
    }

    /// Compares paths, not URLs: macOS 15 resolves an absent folder without its trailing slash, so URL
    /// equality refused the first enable (T-045 BRS-01).
    static func isFreeOfSymlinks(_ url: URL, resolvedBy resolve: (URL) -> URL = { $0.resolvingSymlinksInPath() }) -> Bool {
        url.standardizedFileURL.path == resolve(url).standardizedFileURL.path
    }

    /// True for any directory entry, including a dangling or foreign symlink.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func decode(_ url: URL) throws -> Preferences {
        try JSONDecoder().decode(Preferences.self, from: read(url, maximumBytes: 64 * 1024))
    }

    /// Keeps the unreadable file (or link) next to the settings, under a dated name.
    static func moveDamagedFileAside(_ url: URL) throws -> String {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = url.deletingLastPathComponent()
        var name = "settings.damaged-\(stamp).json", index = 1
        while exists(folder.appendingPathComponent(name)) { name = "settings.damaged-\(stamp)-\(index).json"; index += 1 }
        try fm.moveItem(at: url, to: folder.appendingPathComponent(name, isDirectory: false))
        return name
    }

    func save(_ value: Preferences) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.write(encoder.encode(value), to: settingsURL)
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard isFreeOfSymlinks(url) else { throw CocoaError(.fileReadNoPermission) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        guard isFreeOfSymlinks(url) else { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
