#if os(macOS)
import Darwin
import Foundation

/// Owner-only, no-follow traversal and fd-relative atomic writes, like BlockingStore.
struct FocusStore {
    var directory: URL
    static var standard: Self { Self(directory: AppPaths.applicationSupportDirectory.appendingPathComponent("Focus")) }
    static let maximumBytes = 2 * 1024 * 1024
    private func openDirectory(_ area: String?, create: Bool) throws -> Int32? {
        let path = area.map { directory.appendingPathComponent($0) } ?? directory
        guard path.isFileURL, path.path.hasPrefix("/"), !path.pathComponents.contains("..") else { throw FocusFailure.storageFailed }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FocusFailure.storageFailed }
        do {
            for part in path.pathComponents.dropFirst() {
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    if !create { close(fd); return nil }
                    guard mkdirat(fd, part, 0o700) == 0 || errno == EEXIST else { throw FocusFailure.storageFailed }
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw FocusFailure.storageFailed }; close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw FocusFailure.storageFailed }
            return fd
        } catch { close(fd); throw error }
    }
    private func read(_ name: String, fd directoryFD: Int32) throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw FocusFailure.storageFailed }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size <= Self.maximumBytes else { throw FocusFailure.storageFailed }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw FocusFailure.storageFailed }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumBytes else { throw FocusFailure.storageFailed }
        }
    }
    private func load<T: Decodable>(_ type: T.Type, area: String?, name: String) throws -> T? {
        guard let fd = try openDirectory(area, create: false) else { return nil }; defer { close(fd) }
        guard let data = try read(name, fd: fd) else { return nil }
        do { return try FocusJSON.decode(type, from: data) } catch { throw FocusFailure.storageFailed }
    }
    private func save<T: Encodable>(_ value: T, area: String?, name: String) throws {
        let data = try FocusJSON.encode(value)
        guard data.count <= Self.maximumBytes, let directoryFD = try openDirectory(area, create: true) else { throw FocusFailure.invalidArgument }
        defer { close(directoryFD) }
        var info = stat()
        let existing = fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW)
        guard (existing < 0 && errno == ENOENT) || (existing == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == getuid() && info.st_mode & 0o077 == 0) else { throw FocusFailure.storageFailed }
        let temp = ".focus-" + UUID().uuidString
        let fd = openat(directoryFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FocusFailure.storageFailed }; defer { close(fd); unlinkat(directoryFD, temp, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw FocusFailure.storageFailed }; offset += n
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temp, directoryFD, name) == 0, fsync(directoryFD) == 0 else { throw FocusFailure.storageFailed }
    }
    func sessions(_ day: String) throws -> [FocusSession] {
        guard FocusValidation.day(day) else { throw FocusFailure.invalidArgument }
        let result = try load([FocusSession].self, area: "sessions", name: day + ".json") ?? []
        guard result.count <= 200, Set(result.map(\.id)).count == result.count, result.allSatisfy(\.valid) else { throw FocusFailure.storageFailed }
        return result
    }
    func saveSessions(_ sessions: [FocusSession], day: String) throws {
        guard FocusValidation.day(day), sessions.count <= 200, Set(sessions.map(\.id)).count == sessions.count, sessions.allSatisfy(\.valid) else { throw FocusFailure.invalidArgument }
        try save(sessions, area: "sessions", name: day + ".json")
    }
    func sessionDays() throws -> [String] { try days(area: "sessions") }
    func planDays() throws -> [String] { try days(area: "plans") }
    private func days(area: String) throws -> [String] {
        guard let fd = try openDirectory(area, create: false) else { return [] }; defer { close(fd) }
        guard let dir = fdopendir(dup(fd)) else { throw FocusFailure.storageFailed }; defer { closedir(dir) }
        var days: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) } }
            if name.hasSuffix(".json"), FocusValidation.day(String(name.dropLast(5))) { days.append(String(name.dropLast(5))) }
            guard days.count <= 4096 else { throw FocusFailure.storageFailed }
        }
        return days.sorted()
    }
    func plan(_ day: String) throws -> FocusPlan? {
        guard FocusValidation.day(day) else { throw FocusFailure.invalidArgument }
        let result = try load(FocusPlan.self, area: "plans", name: day + ".json")
        guard result.map({ $0.valid && $0.day == day }) ?? true else { throw FocusFailure.storageFailed }; return result
    }
    func review(_ day: String) throws -> FocusReview? {
        guard FocusValidation.day(day) else { throw FocusFailure.invalidArgument }
        let result = try load(FocusReview.self, area: "reviews", name: day + ".json")
        guard result.map({ $0.valid && $0.day == day }) ?? true else { throw FocusFailure.storageFailed }; return result
    }
    func settings() throws -> FocusSettings {
        let value = try load(FocusSettings.self, area: nil, name: "settings.json") ?? FocusSettings()
        guard value.valid else { throw FocusFailure.storageFailed }; return value
    }
    func saveSettings(_ value: FocusSettings) throws { guard value.valid else { throw FocusFailure.invalidArgument }; try save(value, area: nil, name: "settings.json") }
    struct Transaction: Codable { var plans: [FocusPlan]; var review: FocusReview? }
    /// Preflighted multi-day changes are replayable after interruption; app remains the only writer.
    func savePlans(_ plans: [FocusPlan], review: FocusReview? = nil) throws {
        guard plans.allSatisfy(\.valid), Set(plans.map(\.day)).count == plans.count, review?.valid ?? true else { throw FocusFailure.invalidArgument }
        let transaction = Transaction(plans: plans, review: review)
        try save(transaction, area: nil, name: "pending.json")
        try apply(transaction)
    }
    func recover() throws {
        if let value = try load(Transaction.self, area: nil, name: "pending.json") { try apply(value) }
    }
    private func apply(_ value: Transaction) throws {
        guard value.plans.allSatisfy(\.valid), value.review?.valid ?? true else { throw FocusFailure.storageFailed }
        for plan in value.plans { try save(plan, area: "plans", name: plan.day + ".json") }
        if let review = value.review { try save(review, area: "reviews", name: review.day + ".json") }
        guard let fd = try openDirectory(nil, create: false) else { return }; defer { close(fd) }
        guard unlinkat(fd, "pending.json", 0) == 0, fsync(fd) == 0 else { throw FocusFailure.storageFailed }
    }
    func prompts() throws -> FocusPromptState? { try load(FocusPromptState.self, area: nil, name: "prompts.json") }
    func savePrompts(_ value: FocusPromptState) throws { try save(value, area: nil, name: "prompts.json") }
    func marks() throws -> [FocusLimitMark] { try load([FocusLimitMark].self, area: nil, name: "limit-marks.json") ?? [] }
    func saveMarks(_ value: [FocusLimitMark]) throws { try save(Array(value.suffix(800)), area: nil, name: "limit-marks.json") }
    func appendStatus(_ data: Data, day: String) throws {
        guard FocusValidation.day(day), data.count <= 8192, let dir = try openDirectory("status", create: true) else { throw FocusFailure.invalidArgument }; defer { close(dir) }
        let fd = openat(dir, day + ".jsonl", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FocusFailure.storageFailed }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size + Int64(data.count) <= Int64(Self.maximumBytes) else { throw FocusFailure.storageFailed }
        var line = data; line.append(10)
        let result = line.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        guard result == line.count, fsync(fd) == 0 else { throw FocusFailure.storageFailed }
    }
    func deleteData() throws {
        guard let fd = try openDirectory(nil, create: false) else { return }; close(fd)
        // The root is verified, and removeItem does not follow a contained symlink.
        try FileManager.default.removeItem(at: directory)
    }
}
#endif
