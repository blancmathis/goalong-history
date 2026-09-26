#if os(macOS)
import Foundation
import Darwin

/// Only the explicit Save panel calls this writer. Create a private sibling and
/// atomically rename it; never truncate/follow an existing destination symlink.
enum SupportReportWriter {
    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".goalong-report-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(temporary.path) }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EPERM) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
#endif
