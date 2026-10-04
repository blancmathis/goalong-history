#if os(macOS)
import Darwin
import Foundation

/// All path components are opened without following links; operations remain relative to the held fd.
struct BlockingStore {
    var directory: URL
    static var standard: BlockingStore { BlockingStore(directory: AppPaths.applicationSupportDirectory.appendingPathComponent("Blocking", isDirectory: true)) }
    enum Failure: Error { case unsafePath, unreadable, invalidDocument }

    private func openDirectory(create: Bool) throws -> Int32? {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafePath }
        do {
            // standardizedFileURL rewrites /private/var to the symlink /var on macOS.
            // Preserve the caller's literal absolute path so O_NOFOLLOW stays meaningful.
            guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { throw Failure.unsafePath }
            for component in directory.pathComponents.dropFirst() {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    if !create { close(fd); return nil }
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw Failure.unsafePath }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Failure.unsafePath }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), create || info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
            if create { guard fchmod(fd, 0o700) == 0 else { throw Failure.unsafePath } }
            return fd
        } catch { close(fd); throw error }
    }

    func load() throws -> BlockingDocument {
        guard let directoryFD = try openDirectory(create: false) else { return BlockingDocument() }
        defer { close(directoryFD) }
        let fd = openat(directoryFD, "blocking.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return BlockingDocument() }
        guard fd >= 0 else { throw Failure.unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 8 * 1024 * 1024,
              info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw Failure.unreadable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 8 * 1024 * 1024 else { throw Failure.unreadable }
        }
        let document: BlockingDocument
        do { document = try JSONDecoder().decode(BlockingDocument.self, from: data) }
        catch { throw Failure.invalidDocument }
        guard BlockingRules.validate(document) else { throw Failure.invalidDocument }
        return document
    }

    func save(_ document: BlockingDocument) throws {
        guard BlockingRules.validate(document), let directoryFD = try openDirectory(create: true) else { throw Failure.invalidDocument }
        defer { close(directoryFD) }
        // Refuse an existing link or other special file rather than replacing it silently.
        var existing = stat()
        let status = fstatat(directoryFD, "blocking.json", &existing, AT_SYMLINK_NOFOLLOW)
        guard (status < 0 && errno == ENOENT) || (status == 0 && existing.st_mode & S_IFMT == S_IFREG && existing.st_nlink == 1) else { throw Failure.unsafePath }
        let temporary = ".blocking-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unreadable }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw Failure.unreadable }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, "blocking.json") == 0,
              fsync(directoryFD) == 0 else { throw Failure.unreadable }
    }
}

struct BlockingClockState: Codable, Equatable {
    var wall: Date
    var continuous: Double
    var boot: String
}

enum BlockingClock {
    static func continuous() -> Double {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1e9
    }
    static func bootID() -> String {
        var bytes = [CChar](repeating: 0, count: 128), size = 128
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
    static func adjustment(previous: BlockingClockState, now: BlockingClockState) -> TimeInterval {
        if previous.boot == now.boot, now.continuous >= previous.continuous {
            let jump = now.wall.timeIntervalSince(previous.wall) - (now.continuous - previous.continuous)
            return jump > 60 ? jump : 0
        }
        return min(0, now.wall.timeIntervalSince(previous.wall))
    }
}
#endif
