#if os(macOS)
    import Darwin
    import Foundation

    /// macOS `fsync` does not flush the drive cache, so data it "synced" can still be lost or
    /// reordered on power loss. `full` asks the drive itself (F_FULLFSYNC) for the rare writes that
    /// later state depends on: checkpoints, seals and directory entries. `barrier` (F_BARRIERFSYNC)
    /// keeps frequent journal syncs cheap while still ordering them before any later write.
    enum DurableSync {
        /// Returns 0 on success, otherwise the errno of the failed sync.
        static func full(_ descriptor: Int32) -> Int32 {
            sync(descriptor, primary: { fcntl($0, F_FULLFSYNC) }, fallback: { fsync($0) })
        }

        static func barrier(_ descriptor: Int32) -> Int32 {
            sync(descriptor, primary: { fcntl($0, F_BARRIERFSYNC) }, fallback: { fsync($0) })
        }

        /// Some volumes (network shares, FUSE, some disk images) do not support the fcntl;
        /// only then does it fall back to a plain fsync. A real I/O error is reported as is.
        static func sync(
            _ descriptor: Int32,
            primary: (Int32) -> Int32,
            fallback: (Int32) -> Int32
        ) -> Int32 {
            while primary(descriptor) == -1 {
                let code = errno
                if code == EINTR { continue }
                guard [ENOTSUP, EINVAL, ENOTTY].contains(code) else { return code }
                while fallback(descriptor) != 0 {
                    let fallbackCode = errno
                    if fallbackCode == EINTR { continue }
                    return fallbackCode == 0 ? EIO : fallbackCode
                }
                return 0
            }
            return 0
        }
    }
#endif
