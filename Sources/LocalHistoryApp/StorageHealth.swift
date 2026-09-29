#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    /// Coarse, path-free facts about local storage used by capture health, the
    /// support report and the recovery banner.
    enum StorageHealth {
        /// Below this free space Goalong warns before writes start failing.
        static let lowSpaceThreshold: Int64 = 2 * 1_024 * 1_024 * 1_024

        /// Walks at most four levels of underlying errors and reads only numeric codes.
        static func failureKind(for error: Error) -> CaptureStorageFailureKind {
            var current: NSError? = error as NSError
            var depth = 0
            while let error = current, depth < 4 {
                switch (error.domain, error.code) {
                case (NSPOSIXErrorDomain, Int(ENOSPC)), (NSPOSIXErrorDomain, Int(EDQUOT)),
                     (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError):
                    return .diskFull
                case (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)),
                     (NSPOSIXErrorDomain, Int(EROFS)),
                     (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
                     (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError):
                    return .permissionDenied
                default:
                    current = error.userInfo[NSUnderlyingErrorKey] as? NSError
                    depth += 1
                }
            }
            return .unavailable
        }

        /// Free space usable for important writes on the volume holding `url`.
        static func availableBytes(at url: URL = AppPaths.applicationSupportDirectory) -> Int64? {
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            var status = statfs()
            guard statfs(url.path, &status) == 0 else { return nil }
            return Int64(status.f_bavail) * Int64(status.f_bsize)
        }

        static func isLow(_ bytes: Int64?) -> Bool {
            guard let bytes else { return false }
            return bytes < lowSpaceThreshold
        }

        static func formatted(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useGB, .useMB]
            return formatter.string(fromByteCount: bytes)
        }
    }
#endif
