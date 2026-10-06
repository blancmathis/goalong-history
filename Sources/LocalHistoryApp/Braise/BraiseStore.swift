#if os(macOS)
import BraiseCore
import Darwin
import Foundation

/// No I/O in init. The legacy file is read once, on the first explicit enable.
struct BraiseStore {
    let directory: URL
    let legacySettings: URL
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    func load() throws -> Preferences {
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw CocoaError(.fileReadNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var value: Preferences
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            value = try JSONDecoder().decode(Preferences.self, from: Self.read(settingsURL, maximumBytes: 64 * 1024))
        } else {
            if FileManager.default.fileExists(atPath: legacySettings.path) {
                value = try JSONDecoder().decode(Preferences.self, from: Self.read(legacySettings, maximumBytes: 64 * 1024))
            } else { value = Preferences() }
            value.sanitize()
            try save(value)
        }
        value.sanitize()
        var ids = Set<UUID>()
        value.rules = value.rules.filter { ids.insert($0.id).inserted }
        return value
    }

    func save(_ value: Preferences) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.write(encoder.encode(value), to: settingsURL)
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw CocoaError(.fileReadNoPermission) }
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
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
#endif
