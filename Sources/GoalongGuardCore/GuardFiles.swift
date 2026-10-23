import Darwin
import Foundation

/// `guard-release`: the app says its exit is legitimate. Written in `applicationWillTerminate`.
public struct GuardRelease: Codable, Equatable, Sendable {
    public static let userQuit = "user_quit"
    public static let sessionEnd = "session_end"
    public var pid: Int32
    public var reason: String
    /// Unix seconds.
    public var writtenAt: Double
    /// `kern.boottime`, Unix seconds.
    public var bootTime: Double
    public init(pid: Int32, reason: String, writtenAt: Double, bootTime: Double) {
        self.pid = pid; self.reason = reason; self.writtenAt = writtenAt; self.bootTime = bootTime
    }
}

/// `guard-lease`: a relaunch is already planned by Sparkle or the permission relauncher.
public struct GuardLease: Codable, Equatable, Sendable {
    public static let update = "update"
    public static let permissionRestart = "permission_restart"
    /// Longest wait the guard ever grants, from the moment it reads the lease.
    public static let maximumDuration: TimeInterval = 180
    public var pid: Int32
    public var reason: String
    /// Unix seconds.
    public var until: Double
    public init(pid: Int32, reason: String, until: Double) { self.pid = pid; self.reason = reason; self.until = until }
}

/// `guard-health`: written by the app once its blocking runtime runs.
public struct GuardHealth: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Unix seconds.
    public var at: Double
    public init(pid: Int32, at: Double) { self.pid = pid; self.at = at }
}

/// `guard-state.json`: written by the guard only, read for display and the M1 gap measure.
public struct GuardState: Codable, Equatable, Sendable {
    public var build: String
    public var armed: Bool
    public var lastRelaunch: Double?
    /// Death of the app to its next `guard-health`, in milliseconds.
    public var gapMs: Int?
    public var budget: String
    /// Continuous end, marker value and boot of the armed window: a new guard process of the same boot
    /// starts from this memory, so a clock change while the guard was down cannot disarm it.
    public var endContinuous: Double?
    public var markerDate: Double?
    public var bootTime: Double?
    public init(build: String, armed: Bool, lastRelaunch: Double? = nil, gapMs: Int? = nil, budget: String = "normal",
                endContinuous: Double? = nil, markerDate: Double? = nil, bootTime: Double? = nil) {
        self.build = build; self.armed = armed; self.lastRelaunch = lastRelaunch; self.gapMs = gapMs; self.budget = budget
        self.endContinuous = endContinuous; self.markerDate = markerDate; self.bootTime = bootTime
    }
}

/// `guard-override`: written by `--unregister-guard` when an installer runs with the documented override
/// during a severe block. While fresh, the running app neither re-registers the guard nor ignores SIGTERM.
public struct GuardOverride: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 600
    public var pid: Int32
    /// Unix seconds.
    public var writtenAt: Double
    public init(pid: Int32, writtenAt: Double) { self.pid = pid; self.writtenAt = writtenAt }
    public func isFresh(now: Double) -> Bool { writtenAt <= now + 5 && now - writtenAt <= Self.lifetime }
}

/// Result of reading `guard-until`. Anything but `.date` arms nothing (fail open).
public enum GuardMarker: Equatable, Sendable {
    case absent
    case invalid
    case date(Date)
}

/// Exchange files in `<dataRoot>/Blocking/`. Same discipline as BlockingStore: every component opened
/// without following links, owner checked, regular files only, 0600, atomic replace with fsync.
public struct GuardFiles: Sendable {
    public static let until = "guard-until", release = "guard-release", lease = "guard-lease"
    public static let health = "guard-health", state = "guard-state.json", override = "guard-override"
    /// A marker further than this arms nothing: a typo or a forged file can never lock the Mac for years.
    public static let maximumArming: TimeInterval = 400 * 86_400

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// The end the app writes for `severe`: whole seconds rounded up, and never past what the guard accepts
    /// (`maximumArming`, two days of margin, whole days so the file changes at most once a day).
    public static func markerEnd(_ severe: Date, now: Date) -> Date {
        let limit = ((now.timeIntervalSince1970 + maximumArming - 2 * 86_400) / 86_400).rounded(.down) * 86_400
        return Date(timeIntervalSince1970: min(severe.timeIntervalSince1970.rounded(.up), limit))
    }

    // MARK: Reading

    public func readMarker(now: Date) -> GuardMarker {
        guard let data = read(Self.until, limit: 16) else { return exists(Self.until) ? .invalid : .absent }
        guard let text = String(data: data, encoding: .utf8) else { return .invalid }
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber),
              let seconds = Int64(trimmed) else { return .invalid }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        guard date.timeIntervalSince(now) <= Self.maximumArming else { return .invalid }
        return .date(date)
    }
    public func readRelease() -> GuardRelease? { decode(Self.release) }
    public func readLease() -> GuardLease? { decode(Self.lease) }
    public func readHealth() -> GuardHealth? { decode(Self.health) }
    public func readState() -> GuardState? { decode(Self.state) }
    public func readOverride() -> GuardOverride? { decode(Self.override) }

    // MARK: Writing

    /// Writes or removes `guard-until`. True only when the file is durably in the wanted state.
    @discardableResult
    public func writeMarker(until: Date?) -> Bool {
        guard let until else { return remove(Self.until) }
        return write(Self.until, Data("\(Int64(until.timeIntervalSince1970.rounded(.up)))\n".utf8), create: true)
    }
    @discardableResult public func writeRelease(_ value: GuardRelease) -> Bool { encode(value, to: Self.release) }
    @discardableResult public func writeLease(_ value: GuardLease) -> Bool { encode(value, to: Self.lease) }
    @discardableResult public func writeHealth(_ value: GuardHealth) -> Bool { encode(value, to: Self.health) }
    @discardableResult public func writeState(_ value: GuardState) -> Bool { encode(value, to: Self.state, create: false) }
    @discardableResult public func writeOverride(_ value: GuardOverride) -> Bool { encode(value, to: Self.override) }
    @discardableResult public func removeLease() -> Bool { remove(Self.lease) }
    /// Called by the app at launch: a token always belongs to the process that wrote it.
    public func clearTokens() { _ = remove(Self.release); _ = remove(Self.lease) }

    /// True when `guard-until` exists as a name (cheap stat, no read): the refresh rewrites a deleted marker.
    public func markerExists() -> Bool { exists(Self.until) }

    // MARK: Low level

    private func openDirectory(create: Bool) -> Int32? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { return nil }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for component in directory.pathComponents.dropFirst() {
            var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { close(fd); return nil }
                next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); return nil }
        return fd
    }

    private func exists(_ name: String) -> Bool {
        guard let directoryFD = openDirectory(create: false) else { return false }
        defer { close(directoryFD) }
        var info = stat()
        return fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    private func read(_ name: String, limit: Int) -> Data? {
        guard let directoryFD = openDirectory(create: false) else { return nil }
        defer { close(directoryFD) }
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size <= limit else { return nil }
        var buffer = [UInt8](repeating: 0, count: limit + 1)
        var total = 0
        while total <= limit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: total), limit + 1 - total) }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            total += count
        }
        guard total <= limit else { return nil }
        return Data(buffer.prefix(total))
    }

    private func decode<T: Decodable>(_ name: String) -> T? {
        guard let data = read(name, limit: 4096) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, to name: String, create: Bool = true) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        return write(name, data, create: create)
    }

    private func remove(_ name: String) -> Bool {
        guard let directoryFD = openDirectory(create: false) else { return !FileManager.default.fileExists(atPath: directory.path) }
        defer { close(directoryFD) }
        return (unlinkat(directoryFD, name, 0) == 0 || errno == ENOENT) && fsync(directoryFD) == 0
    }

    private func write(_ name: String, _ bytes: Data, create: Bool) -> Bool {
        guard let directoryFD = openDirectory(create: create) else { return false }
        defer { close(directoryFD) }
        var existing = stat()
        let status = fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW)
        guard (status < 0 && errno == ENOENT) || (status == 0 && existing.st_mode & S_IFMT == S_IFREG) else { return false }
        let temporary = "." + name + "-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        let written = bytes.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return written && fsync(fd) == 0 && renameat(directoryFD, temporary, directoryFD, name) == 0 && fsync(directoryFD) == 0
    }
}

/// Boot and process facts shared by the guard and the app.
public enum GuardSystem {
    /// `realpath(3)`: unlike `resolvingSymlinksInPath`, it keeps `/private/var`, so GuardFiles can open
    /// every component without following links. Unchanged when the path does not exist yet.
    public static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: url.hasDirectoryPath)
    }

    /// `kern.boottime` in Unix seconds; 0 when unreadable.
    public static func bootTime() -> Double {
        var value = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return 0 }
        return Double(value.tv_sec) + Double(value.tv_usec) / 1e6
    }
    /// Seconds of `mach_continuous_time`: keeps counting during sleep, ignores wall clock changes.
    public static func continuousSeconds() -> TimeInterval {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1e9
    }
}
