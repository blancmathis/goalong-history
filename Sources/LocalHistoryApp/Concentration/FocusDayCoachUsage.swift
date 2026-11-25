#if os(macOS)
import Darwin
import Foundation

struct FocusDayCoachUsageStatus: Codable, Equatable {
    var day: String
    var calls: Int
    var limit: Int
    var remaining: Int
    var knownTokens: Int
    var unreportedCalls: Int
    var isBusy: Bool
    var model: String?
    var reasoningEffort: String?
}

/// Counts attempts before inference. A crash, timeout or cancellation never refunds one.
struct FocusDayCoachUsageLedger: Codable, Equatable {
    struct Attempt: Codable, Equatable {
        var id: UUID
        var day: String
        var at: Date
        var tokens: Int?
    }
    var schema = 1
    var attempts: [Attempt] = []
    var valid: Bool {
        schema == 1 && attempts.count <= 600 && Set(attempts.map(\.id)).count == attempts.count
            && attempts.allSatisfy { FocusValidation.day($0.day) && $0.at.timeIntervalSince1970.isFinite && ($0.tokens.map { (0...100_000_000).contains($0) } ?? true) }
    }
    func status(day: String, settings: FocusDayCoachSettings, busy: Bool) -> FocusDayCoachUsageStatus {
        let values = attempts.filter { $0.day == day }
        return .init(day: day, calls: values.count, limit: settings.dailyCallLimit,
                     remaining: max(0, settings.dailyCallLimit - values.count),
                     knownTokens: values.compactMap(\.tokens).reduce(0, +),
                     unreportedCalls: values.filter { $0.tokens == nil }.count,
                     isBusy: busy, model: settings.model, reasoningEffort: settings.reasoningEffort)
    }
    mutating func reserve(day: String, now: Date, limit: Int) throws -> UUID {
        guard FocusValidation.day(day), (1...6).contains(limit), valid else { throw FocusDayCoachFailure.storage }
        guard attempts.filter({ $0.day == day }).count < limit else { throw FocusDayCoachFailure.dailyLimit }
        // Keep recent dates, including future dates if the clock was turned back.
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        attempts.removeAll { $0.at < cutoff && $0.day != day }
        guard attempts.count < 600 else { throw FocusDayCoachFailure.storage }
        let id = UUID(); attempts.append(.init(id: id, day: day, at: now, tokens: nil)); return id
    }
    mutating func settle(_ id: UUID, tokens: Int?) {
        guard let index = attempts.firstIndex(where: { $0.id == id }),
              let tokens, (0...100_000_000).contains(tokens) else { return }
        attempts[index].tokens = tokens
    }
}

/// Small owner-only file. No prompts, output, credentials or agenda data are persisted here.
struct FocusDayCoachUsageStore {
    let directory: URL
    static var standard: Self { .init(directory: FocusStore.standard.directory.appendingPathComponent("coach", isDirectory: true)) }
    private var file: URL { directory.appendingPathComponent("usage.json") }
    func load() throws -> FocusDayCoachUsageLedger {
        // A no-follow walk also rejects a substituted parent directory.
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { throw FocusDayCoachFailure.storage }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FocusDayCoachFailure.storage }
        defer { Darwin.close(fd) }
        for part in directory.pathComponents.dropFirst() {
            let next = Darwin.openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT { return .init() }
            guard next >= 0 else { throw FocusDayCoachFailure.storage }
            Darwin.close(fd); fd = next
        }
        var parent = stat()
        guard fstat(fd, &parent) == 0, parent.st_uid == getuid(), parent.st_mode & 0o077 == 0 else { throw FocusDayCoachFailure.storage }
        let input = Darwin.openat(fd, "usage.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if input < 0 && errno == ENOENT { return .init() }
        guard input >= 0 else { throw FocusDayCoachFailure.storage }
        defer { Darwin.close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 256_000 else { throw FocusDayCoachFailure.storage }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(input, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw FocusDayCoachFailure.storage }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 256_000 else { throw FocusDayCoachFailure.storage }
        }
        guard let value = try? JSONDecoder().decode(FocusDayCoachUsageLedger.self, from: data), value.valid else { throw FocusDayCoachFailure.storage }
        return value
    }
    func save(_ value: FocusDayCoachUsageLedger) throws {
        guard value.valid else { throw FocusDayCoachFailure.storage }
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= 256_000 else { throw FocusDayCoachFailure.storage }
            try ChatGPTSecureStorage.writeFileAtomically(data, to: file)
        } catch { throw FocusDayCoachFailure.storage }
    }
    func reserve(day: String, now: Date, limit: Int) throws -> UUID {
        var value = try load()
        let id = try value.reserve(day: day, now: now, limit: limit)
        try save(value); return id
    }
    func settle(_ id: UUID, tokens: Int?) throws {
        var value = try load(); value.settle(id, tokens: tokens); try save(value)
    }
}
#endif
