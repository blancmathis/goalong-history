import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Bounded, content-free foreground days. Raw journals remain authoritative while present.
public struct GoalongActivityDayStore: Sendable {
    public static let schema = "goalong.activity-day.v1"
    public static let directoryName = "activity-days"
    public static let maximumSegments = 20_000
    public static let maximumBytes = 2 * 1_024 * 1_024
    public let root: URL
    public init(root: URL) { self.root = root }

    private struct Row: Codable {
        let offset: Double, duration: Double
        let kind: GoalongLocalAnalytics.Kind
        let application: Int?, bundle: Int?, host: Int?, context: Int?, reason: Int?
    }
    private struct Envelope: Codable {
        let schema: String, method: String, timeZone: String, date: String, sourceRevision: String
        let start: Date, end: Date
        let state: GoalongLocalAnalytics.State
        let eventCount: Int
        let classifierVersions: [String]
        let strings: [String]
        let segments: [Row]
        let breakdown: GoalongActivityBreakdown
        let firstObservation: Date?, lastObservation: Date?
    }

    public enum Failure: Error { case unsafePath, invalidSummary, sourceChanged, unavailable }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Same adjacent-journal stamp as Activité, with nanosecond mtime to detect fast rewrites.
    public func sourceRevision(day: Date, calendar: Calendar = .current) -> String {
        (-1...1).map { offset -> String in
            let date = calendar.date(byAdding: .day, value: offset, to: day) ?? day
            let url = root.appendingPathComponent("events/" + Self.dayKey(date, calendar: calendar) + ".jsonl")
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? "missing" : "unreadable" }
            guard info.st_mode & S_IFMT == S_IFREG else { return "unsafe" }
            return "\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }.joined(separator: ";") + calendar.timeZone.identifier
    }

    public func read(day: Date, sourceRevision: String? = nil, calendar: Calendar = .current) throws -> GoalongLocalAnalytics.Day {
        let key = Self.dayKey(day, calendar: calendar)
        let fd = try directory(create: false); defer { close(fd) }
        let file = openat(fd, key + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= Self.maximumBytes,
              let bytes = try handle.read(upToCount: Self.maximumBytes + 1), bytes.count == info.st_size else { throw Failure.unsafePath }
        var after = stat()
        guard fstat(file, &after) == 0, info.st_size == after.st_size,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.sourceChanged }
        let e = try JSONDecoder().decode(Envelope.self, from: bytes)
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        guard e.schema == Self.schema, e.method == GoalongLocalAnalytics.method, e.timeZone == calendar.timeZone.identifier,
              e.date == key, e.start == start, e.end == end, e.state == .ready, e.eventCount > 0,
              sourceRevision.map({ e.sourceRevision == $0 }) ?? true,
              !e.sourceRevision.isEmpty, e.sourceRevision.utf8.count <= 1024,
              e.segments.count <= Self.maximumSegments, e.strings.count <= Self.maximumSegments * 5,
              e.strings.allSatisfy({ $0.utf8.count <= 1024 }), e.classifierVersions.count <= 16 else { throw Failure.invalidSummary }
        func string(_ index: Int?) throws -> String? {
            guard let index else { return nil }
            guard e.strings.indices.contains(index) else { throw Failure.invalidSummary }
            return e.strings[index]
        }
        var segments: [GoalongLocalAnalytics.Segment] = [], cursor = 0.0
        for row in e.segments {
            guard row.offset.isFinite, row.duration.isFinite, row.offset == cursor, row.duration > 0,
                  row.offset + row.duration <= end.timeIntervalSince(start) else { throw Failure.invalidSummary }
            let rawReason = try string(row.reason)
            let reason = rawReason.flatMap(GoalongCoverageReason.init(rawValue:))
            let context = try string(row.context)
            guard rawReason == nil || reason != nil,
                  context == nil || context!.range(of: #"^[a-f0-9]{16}$"#, options: .regularExpression) != nil,
                  !row.kind.isActive || row.kind == .unclassified,
                  (row.kind == .concealed || row.kind == .unobserved) == (reason != nil) else { throw Failure.invalidSummary }
            segments.append(.init(start: start.addingTimeInterval(row.offset), end: start.addingTimeInterval(row.offset + row.duration),
                kind: row.kind, application: try string(row.application), bundleIdentifier: try string(row.bundle),
                host: try string(row.host), contextKey: context, coverageReason: reason))
            cursor += row.duration
        }
        guard cursor == end.timeIntervalSince(start), e.breakdown.hours.count <= 26,
              e.breakdown.hours.allSatisfy({ hour in
                  hour.start >= start && hour.end <= end && hour.end > hour.start
                      && hour.secondsByMode.values.allSatisfy { $0.isFinite && $0 >= 0 }
                      && hour.totalSeconds <= hour.end.timeIntervalSince(hour.start)
              }) else { throw Failure.invalidSummary }
        let result = GoalongLocalAnalytics.Day(date: start, end: end, state: .ready, segments: segments,
            eventCount: e.eventCount, classifierVersions: Set(e.classifierVersions), origin: .summary, hasDetailedSource: false,
            firstObservation: e.firstObservation, lastObservation: e.lastObservation, recordedBreakdown: e.breakdown)
        guard result.breakdown.totalSeconds == result.activeSeconds,
              let first = e.firstObservation, let last = e.lastObservation,
              first >= start, last <= end, first <= last else { throw Failure.invalidSummary }
        var previousEnd = start
        for hour in e.breakdown.hours {
            guard let boundary = calendar.dateInterval(of: .hour, for: hour.start),
                  boundary.start == hour.start, boundary.end == hour.end, hour.start >= previousEnd else { throw Failure.invalidSummary }
            let active = segments.filter { $0.kind.isActive }.reduce(0.0) {
                $0 + max(0, min($1.end, hour.end).timeIntervalSince(max($1.start, hour.start)))
            }
            guard active == hour.totalSeconds else { throw Failure.invalidSummary }
            previousEnd = hour.end
        }
        return result
    }

    public func write(_ day: GoalongLocalAnalytics.Day, sourceRevision: String, now: Date = Date(), calendar: Calendar = .current) throws {
        let start = calendar.startOfDay(for: day.date)
        guard start < calendar.startOfDay(for: now), day.state == .ready, day.date == start,
              day.end == calendar.date(byAdding: .day, value: 1, to: start),
              day.segments.count <= Self.maximumSegments else { throw Failure.invalidSummary }
        var strings: [String] = [], indices: [String: Int] = [:]
        func index(_ value: String?) -> Int? {
            guard let value else { return nil }
            if let found = indices[value] { return found }
            let found = strings.count; strings.append(value); indices[value] = found; return found
        }
        let rows = day.segments.map { segment in
            Row(offset: segment.start.timeIntervalSince(start), duration: segment.seconds,
                kind: segment.kind.isActive ? .unclassified : segment.kind,
                application: index(segment.application), bundle: index(segment.bundleIdentifier), host: index(segment.host),
                context: index(segment.contextKey), reason: index(segment.coverageReason?.rawValue))
        }
        let e = Envelope(schema: Self.schema, method: GoalongLocalAnalytics.method, timeZone: calendar.timeZone.identifier,
            date: Self.dayKey(start, calendar: calendar), sourceRevision: sourceRevision, start: start, end: day.end,
            state: day.state, eventCount: day.eventCount, classifierVersions: day.classifierVersions.sorted(),
            strings: strings, segments: rows, breakdown: day.breakdown, firstObservation: day.firstObservation, lastObservation: day.lastObservation)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(e)
        guard bytes.count <= Self.maximumBytes else { throw Failure.invalidSummary }
        let fd = try directory(create: true); defer { close(fd) }
        let name = e.date + ".json", temporary = ".activity-" + UUID().uuidString
        var existing = stat()
        let status = fstatat(fd, name, &existing, AT_SYMLINK_NOFOLLOW)
        guard status != 0 ? errno == ENOENT : (existing.st_mode & S_IFMT == S_IFREG && existing.st_nlink == 1) else { throw Failure.unsafePath }
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.unavailable }
        defer { close(file); unlinkat(fd, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.unavailable }; offset += n
            }
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw Failure.unavailable }
    }

    /// Writes only if the journal is unchanged across the full read. A failed save never permits purge.
    public func preserveBeforePurge(day: Date, now: Date = Date(), calendar: Calendar = .current) throws {
        let revision = sourceRevision(day: day, calendar: calendar)
        if (try? read(day: day, sourceRevision: revision, calendar: calendar)) != nil {
            guard revision == sourceRevision(day: day, calendar: calendar) else { throw Failure.sourceChanged }
            return
        }
        let value = GoalongLocalAnalytics.load(root: root, day: day, now: now, calendar: calendar)
        guard value.state == .ready, revision == sourceRevision(day: day, calendar: calendar) else { throw Failure.sourceChanged }
        try write(value, sourceRevision: revision, now: now, calendar: calendar)
        _ = try read(day: day, sourceRevision: revision, calendar: calendar)
        guard revision == sourceRevision(day: day, calendar: calendar) else { throw Failure.sourceChanged }
    }

    public func load(day: Date, now: Date = Date(), calendar: Calendar = .current, retentionDays: Int? = 30, summaryRetentionDays: Int? = nil,
                     shouldContinue: () -> Bool = { true }) -> GoalongLocalAnalytics.Day {
        let start = calendar.startOfDay(for: day)
        let past = start < calendar.startOfDay(for: now)
        let revision = sourceRevision(day: start, calendar: calendar)
        let journal = root.appendingPathComponent("events/" + Self.dayKey(start, calendar: calendar) + ".jsonl")
        var info = stat()
        let absent = lstat(journal.path, &info) != 0 && errno == ENOENT
        if past, shouldContinue(), var saved = try? read(day: start, sourceRevision: absent ? nil : revision, calendar: calendar) {
            saved.hasDetailedSource = !absent; return saved
        }
        var value = GoalongLocalAnalytics.load(root: root, day: start, now: now, calendar: calendar, shouldContinue: shouldContinue)
        if value.state == .noSource, absent, let days = retentionDays, days > 0,
           let cutoff = calendar.date(byAdding: .day, value: -days, to: now), start < calendar.startOfDay(for: cutoff) {
            value.dayReason = .purgedWithoutSummary
            value = .init(date: value.date, end: value.end, state: value.state, segments: value.segments.map {
                var segment = $0; segment.coverageReason = .purgedWithoutSummary; return segment
            }, eventCount: 0, classifierVersions: [], dayReason: .purgedWithoutSummary)
        }
        value.hasDetailedSource = !absent
        if past, value.state == .ready, shouldContinue(), retains(day: start, now: now, days: summaryRetentionDays, calendar: calendar),
           revision == sourceRevision(day: start, calendar: calendar) {
            try? write(value, sourceRevision: revision, now: now, calendar: calendar)
        }
        return value
    }

    public func journalDays(before now: Date = Date(), calendar: Calendar = .current) throws -> [Date] {
        let folder = root.appendingPathComponent("events")
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard names.count <= 20_000 else { throw Failure.unavailable }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return names.compactMap { name in
            guard name.hasSuffix(".jsonl"), name.count == 16 else { return nil }
            let key = String(name.prefix(10))
            guard let date = f.date(from: key), Self.dayKey(date, calendar: calendar) == key,
                  date < calendar.startOfDay(for: now) else { return nil }
            return date
        }.sorted()
    }

    /// Explicit maintenance entry point, useful for CLI/fixtures. App admission is handled by its barrier.
    @discardableResult public func backfill(now: Date = Date(), calendar: Calendar = .current, summaryRetentionDays: Int? = nil,
                                           shouldContinue: () -> Bool = { true }) throws -> Int {
        var saved = 0
        for day in try journalDays(before: now, calendar: calendar) {
            guard shouldContinue() else { break }
            guard retains(day: day, now: now, days: summaryRetentionDays, calendar: calendar) else { continue }
            let revision = sourceRevision(day: day, calendar: calendar)
            if (try? read(day: day, sourceRevision: revision, calendar: calendar)) != nil { continue }
            let value = GoalongLocalAnalytics.load(root: root, day: day, now: now, calendar: calendar,
                shouldContinue: shouldContinue)
            guard shouldContinue() else { break }
            if value.state == .ready && sourceRevision(day: day, calendar: calendar) == revision {
                try write(value, sourceRevision: revision, now: now, calendar: calendar); saved += 1
            }
        }
        return saved
    }

    private func retains(day: Date, now: Date, days: Int?, calendar: Calendar) -> Bool {
        guard let cutoff = RetentionDuration(days: days).cutoff(relativeTo: now, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: day) else { return true }
        return end.addingTimeInterval(-0.001) >= cutoff
    }

    private func directory(create: Bool) throws -> Int32 {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.unsafePath }; defer { close(rootFD) }
        var info = stat()
        guard fstat(rootFD, &info) == 0, info.st_uid == getuid() else { throw Failure.unsafePath }
        if create, mkdirat(rootFD, Self.directoryName, 0o700) != 0, errno != EEXIST { throw Failure.unavailable }
        let fd = openat(rootFD, Self.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd); throw Failure.unsafePath
        }
        return fd
    }
}
