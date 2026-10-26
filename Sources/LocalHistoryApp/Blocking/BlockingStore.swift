#if os(macOS)
import Darwin
import Foundation
import LocalHistoryCore

/// All path components are opened without following links; operations remain relative to the held fd.
struct BlockingStore {
    var directory: URL
    static var standard: BlockingStore { standard(channel: .current, base: GoalongBuildChannel.applicationSupportBase) }
    /// The channel's own Blocking folder: `LocalHistory-Dev/Blocking` in Goalong Dev, never the real stakes.
    static func standard(channel: GoalongBuildChannel, base: URL) -> BlockingStore {
        BlockingStore(directory: channel.dataRoot(base: base).appendingPathComponent("Blocking", isDirectory: true))
    }
    enum Failure: Error { case unsafePath, unreadable, invalidDocument }
    /// How `loadRecovering` obtained its document.
    enum Recovery: Equatable { case none, previous, reset }
    private static let current = "blocking.json", previous = "blocking.previous.json", lockMarker = "locked-until"

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
        return try readDocument(Self.current, in: directoryFD) ?? BlockingDocument()
    }

    /// A damaged or missing file gives way to the previous generation; a damaged file is set aside, never
    /// deleted. When neither is usable the store starts empty. Only an unusable directory throws.
    func loadRecovering() throws -> (document: BlockingDocument, recovery: Recovery) {
        guard let directoryFD = try openDirectory(create: false) else { return (BlockingDocument(), .none) }
        defer { close(directoryFD) }
        var damaged = false
        do { if let document = try readDocument(Self.current, in: directoryFD) { return (document, .none) } }
        catch { damaged = true; guard setAside(Self.current, in: directoryFD) else { throw Failure.unsafePath } }
        let restored: BlockingDocument?
        do { restored = try readDocument(Self.previous, in: directoryFD) }
        catch { damaged = true; restored = nil; guard setAside(Self.previous, in: directoryFD) else { throw Failure.unsafePath } }
        if let restored { try save(restored); return (restored, .previous) }
        return (BlockingDocument(), damaged ? .reset : .none)
    }

    /// The running state replaces a file changed under it; the changed file is set aside.
    func replaceDamaged(with document: BlockingDocument) throws {
        if let directoryFD = try openDirectory(create: false) {
            defer { close(directoryFD) }
            guard setAside(Self.current, in: directoryFD) else { throw Failure.unsafePath }
        }
        try save(document)
    }

    private func setAside(_ name: String, in directoryFD: Int32) -> Bool {
        renameat(directoryFD, name, directoryFD, name.replacingOccurrences(of: ".json", with: ".damaged.json")) == 0 || errno == ENOENT
    }

    /// nil when the file does not exist.
    private func readDocument(_ name: String, in directoryFD: Int32) throws -> BlockingDocument? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
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
        let status = fstatat(directoryFD, Self.current, &existing, AT_SYMLINK_NOFOLLOW)
        guard (status < 0 && errno == ENOENT) || (status == 0 && existing.st_mode & S_IFMT == S_IFREG && existing.st_nlink == 1) else { throw Failure.unsafePath }
        let temporary = ".blocking-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unreadable }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.invalidDocument }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw Failure.unreadable }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.unreadable }
        // The swap keeps blocking.json present at every instant; the replaced generation becomes the backup.
        if status == 0, renameatx_np(directoryFD, temporary, directoryFD, Self.current, UInt32(RENAME_SWAP)) == 0 {
            _ = renameat(directoryFD, temporary, directoryFD, Self.previous)
        } else {
            guard renameat(directoryFD, temporary, directoryFD, Self.current) == 0 else { throw Failure.unreadable }
        }
        guard fsync(directoryFD) == 0 else { throw Failure.unreadable }
    }

    /// Read by uninstall.sh: end of the latest lock in Unix seconds, absent when nothing is locked.
    /// Returns true only when the marker is durably in the wanted state, so the caller can retry a failure.
    @discardableResult
    func writeLockMarker(until: Date?) -> Bool {
        let opened: Int32?
        do { opened = try openDirectory(create: until != nil) } catch { return false }
        // Without a Blocking folder there is no marker to remove.
        guard let directoryFD = opened else { return until == nil }
        defer { close(directoryFD) }
        guard let until else {
            return (unlinkat(directoryFD, Self.lockMarker, 0) == 0 || errno == ENOENT) && fsync(directoryFD) == 0
        }
        let temporary = ".locked-until-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        let bytes = Array("\(Int(until.timeIntervalSince1970.rounded(.up)))\n".utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            guard count > 0 else { return false }
            offset += count
        }
        return fsync(fd) == 0 && renameat(directoryFD, temporary, directoryFD, Self.lockMarker) == 0 && fsync(directoryFD) == 0
    }
}

struct BlockingClockState: Codable, Equatable {
    var wall: Date
    var continuous: Double
    var boot: String
    /// Wall minus continuous seconds proven in this boot: the offset of its first sample, then following
    /// the wall offset at most `BlockingClock.driftAbsorption` per second of continuous time, both ways
    /// (T-044 r6). nil in documents of older builds.
    var anchor: Double? = nil
    /// `BlockingClock.frame` once the document dates are in the trusted frame (T-044 r5). nil: an older
    /// build wrote it, and its anchor may predate a clock set back (`BlockingClock.upgraded`).
    var frame: Int? = nil

    var offset: Double { wall.timeIntervalSince1970 - continuous }
    /// This sample read through the trusted-now rule (`BlockingClock.trusted`).
    var trusted: Date {
        let proven = continuous + (anchor ?? offset)
        return Date(timeIntervalSince1970: proven + min(max(0, wall.timeIntervalSince1970 - proven), BlockingClock.jumpTolerance))
    }
}

enum BlockingClock {
    /// Forward lead of the wall clock over the proven time that T takes at once: sampling noise. Any
    /// larger lead enters T only through `driftAbsorption` (spec K §4: changing the time changes nothing).
    static let jumpTolerance: TimeInterval = 1
    /// Drift of the wall clock absorbed into the anchor, per second of continuous time (1 s per hour), in
    /// both directions: NTP slewing the clock (≈ 0.5 s a day) leaves T on the wall clock, while a clock set
    /// back or forward by hand stays out of T for months (spec K §4, L-05, T-044 r6).
    static let driftAbsorption: Double = 1.0 / 3_600
    /// Format mark of `BlockingClockState.frame`.
    static let frame = 1
    static func continuous() -> Double {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1e9
    }
    static func bootID() -> String {
        var bytes = [CChar](repeating: 0, count: 128), size = 128
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
    /// The shift of protected ends at this sample: none in the same boot (T ignores clock changes, so the
    /// ends need no move: T-044 r6), else a wall clock earlier than the last sample (L-05).
    static func adjustment(previous: BlockingClockState, now: BlockingClockState) -> TimeInterval {
        if previous.boot == now.boot, now.continuous >= previous.continuous { return 0 }
        return min(0, now.wall.timeIntervalSince(previous.wall))
    }
    /// The one « now » of every blocking and stake decision (T-044 r5, r6). In the boot of `last`, it is
    /// the time proven by continuous time since the anchor, plus at most `jumpTolerance` of forward lead:
    /// a clock set back or forward moves it by at most `driftAbsorption` a second, so day keys, breaks and
    /// program windows keep real time. Without a sample of this boot there is no proof: the wall clock (L-05).
    static func trusted(wall: Date, continuous: Double, boot: String, last: BlockingClockState?) -> Date {
        guard let last, last.boot == boot, continuous >= last.continuous else { return wall }
        var sample = BlockingClockState(wall: wall, continuous: continuous, boot: boot)
        sample.anchor = anchor(after: last, now: sample)
        return sample.trusted
    }
    /// `now` with the anchor the next refresh measures from: carried over in this boot (`anchor(after:)`),
    /// reset to `now` after a reboot (and its compensation) or without any previous sample.
    static func advanced(previous: BlockingClockState?, now: BlockingClockState, adjusted: TimeInterval) -> BlockingClockState {
        var next = now
        if let previous, adjusted == 0, previous.boot == now.boot, now.continuous >= previous.continuous {
            next.anchor = anchor(after: previous, now: now)
        } else {
            next.anchor = now.offset
        }
        next.frame = frame
        return next
    }
    /// The anchor of `last`, moved toward `now.offset` by at most `driftAbsorption` of the continuous
    /// time between them, never past it.
    static func anchor(after last: BlockingClockState, now: BlockingClockState) -> Double {
        let anchor = last.anchor ?? last.offset, step = max(0, now.continuous - last.continuous) * driftAbsorption
        return min(max(now.offset, anchor - step), anchor + step)
    }
    /// The stored sample of a document of an older build, read in this frame. Its dates are wall dates:
    /// in the same boot the anchor may not run ahead of the wall clock (S = 0), so a set-back before the
    /// update cannot shift them. A forward jump stays out of T, as in this build.
    static func upgraded(_ last: BlockingClockState?, wall: Date, continuous: Double, boot: String) -> BlockingClockState? {
        guard var last, last.frame != frame else { return last }
        last.frame = frame
        guard last.boot == boot, continuous >= last.continuous else { return last }
        last.anchor = min(last.anchor ?? last.offset, wall.timeIntervalSince1970 - continuous)
        return last
    }
}
#endif
