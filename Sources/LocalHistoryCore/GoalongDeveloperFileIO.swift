import Foundation
import Darwin

/// Bounded regular-file reads and descriptor-relative private writes; refuses final symlinks.
public enum GoalongDeveloperFileIO {
    public enum Failure: Error { case inaccessible, invalid, tooLarge, changed }
    public static func readFile(_ url: URL, maximumBytes: Int, tail: Bool = false) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.inaccessible }
        defer { close(fd) }
        return try readDescriptor(fd, maximumBytes: maximumBytes, tail: tail)
    }
    public static func readOwned(name: String, root: URL, childDirectory: String? = nil, maximumBytes: Int) throws -> Data {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw Failure.invalid }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.inaccessible }
        defer { close(rootFD) }
        let directoryFD: Int32
        if let childDirectory {
            guard !childDirectory.contains("/"), childDirectory != ".", childDirectory != ".." else { throw Failure.invalid }
            directoryFD = openat(rootFD, childDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw Failure.inaccessible }
        } else { directoryFD = dup(rootFD) }
        defer { close(directoryFD) }
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.inaccessible }
        defer { close(fd) }
        return try readDescriptor(fd, maximumBytes: maximumBytes, tail: false)
    }
    private static func readDescriptor(_ fd: Int32, maximumBytes: Int, tail: Bool) throws -> Data {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw Failure.invalid }
        guard maximumBytes >= 0, tail || before.st_size <= maximumBytes else { throw Failure.tooLarge }
        let offset = tail ? max(0, before.st_size - off_t(maximumBytes)) : 0
        guard lseek(fd, offset, SEEK_SET) >= 0 else { throw Failure.inaccessible }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.changed }
        return offset > 0 ? Data(data.drop(while: { $0 != 10 }).dropFirst()) : data
    }
    public static func write(_ data: Data, name: String, directory: URL, childDirectory: String? = nil, append: Bool = false, maximumBytes: Int = 2_097_152) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", data.count <= maximumBytes else { throw Failure.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.inaccessible }
        defer { close(rootFD) }
        let dir: Int32
        if let childDirectory {
            guard !childDirectory.isEmpty, !childDirectory.contains("/"), childDirectory != ".", childDirectory != ".." else { throw Failure.invalid }
            if mkdirat(rootFD, childDirectory, 0o700) != 0 && errno != EEXIST { throw Failure.inaccessible }
            dir = openat(rootFD, childDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { throw Failure.inaccessible }
        } else { dir = dup(rootFD) }
        defer { close(dir) }
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalid }
        } else if errno != ENOENT { throw Failure.inaccessible }
        let target = append ? name : ".developer-\(UUID().uuidString)"
        let fd = openat(dir, target, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (append ? O_APPEND : O_EXCL), 0o600)
        guard fd >= 0 else { throw Failure.inaccessible }
        defer { close(fd); if !append { unlinkat(dir, target, 0) } }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              !append || info.st_size + Int64(data.count) <= maximumBytes else { throw Failure.tooLarge }
        guard fchmod(fd, 0o600) == 0 else { throw Failure.inaccessible }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.inaccessible }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.inaccessible }
        if !append { guard renameat(dir, target, dir, name) == 0, fsync(dir) == 0 else { throw Failure.inaccessible } }
    }
}
