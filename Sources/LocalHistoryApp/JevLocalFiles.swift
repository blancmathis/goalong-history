#if os(macOS)
import Darwin
import Foundation

/// Small owner-only local settings. No API key in UserDefaults, telemetry, errors,
/// exported history or Git. Ad-hoc builds do not create recurring Keychain prompts.
enum JevLocalFiles {
    static func read(_ name: String, root: URL = AppPaths.applicationSupportDirectory) throws -> Data? {
        guard validName(name) else { throw failure() }
        return try withDirectory(root) { directory in
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT { return nil }
            guard fd >= 0 else { throw failure() }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
                  info.st_size >= 0, info.st_size <= 4096 else { throw failure() }
            var bytes = [UInt8](repeating: 0, count: 4097)
            let size = Darwin.read(fd, &bytes, bytes.count)
            guard size >= 0, size <= 4096 else { throw failure() }
            return Data(bytes.prefix(size))
        }
    }
    static func write(_ data: Data?, name: String, root: URL = AppPaths.applicationSupportDirectory) throws {
        guard validName(name), data == nil || data!.count <= 4096 else { throw failure() }
        try withDirectory(root) { directory in
            guard let data else {
                guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw failure() }
                return
            }
            let temporary = ".jev-" + UUID().uuidString
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw failure() }
            defer { close(fd); unlinkat(directory, temporary, 0) }
            var written = 0
            try data.withUnsafeBytes { bytes in
                while written < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw failure() }
                    written += count
                }
            }
            guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0 else { throw failure() }
        }
    }
    private static func validName(_ name: String) -> Bool { ["api-key", "break.json"].contains(name) }
    private static func withDirectory<T>(_ root: URL, body: (Int32) throws -> T) throws -> T {
        let directory = root.appendingPathComponent("jev", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw failure() }
        return try body(fd)
    }
    private static func failure() -> NSError {
        NSError(domain: "GoalongJev", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Le stockage privé Jev n’est pas accessible. Aucun envoi n’est effectué."])
    }
}
#endif
