import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Bounded, content-free foreground days. Raw journals remain authoritative while present.
public struct GoalongActivityDayStore: Sendable {
    public static let schema = "goalong.activity-day.v1"
    /// Hidden temporary name prefix used by `writePrivateFile` before its atomic rename.
    public static let temporaryPrefix = ".activity-"
    public static let directoryName = "activity-days"
    public static let maximumSegments = 20_000
    public static let maximumBytes = 2 * 1_024 * 1_024
    /// Content-free trace that retention expired this day's journal without leaving a summary.
    public static let purgeMarkerSuffix = ".purged"
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
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Adjacent-journal stamp of a summary.
    public func sourceRevision(day: Date, calendar: Calendar = .current) -> String {
        (-1...1).map { offset -> String in
            journalRevision(day: calendar.date(byAdding: .day, value: offset, to: day) ?? day, calendar: calendar)
        }.joined(separator: ";") + calendar.timeZone.identifier
    }

    /// One journal's stamp, with nanosecond mtime to detect fast rewrites.
    public func journalRevision(day: Date, calendar: Calendar = .current) -> String {
        let url = root.appendingPathComponent("events/" + Self.dayKey(day, calendar: calendar) + ".jsonl")
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? "missing" : "unreadable" }
        guard info.st_mode & S_IFMT == S_IFREG else { return "unsafe" }
        return "\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    /// The next day's journal can still add events to this day until that day closes too.
    public static func isSettled(_ day: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return false }
        return next < calendar.startOfDay(for: now)
    }

    /// A summary still describes its day while the day's own journal is unchanged and a
    /// neighbouring journal has only disappeared: retention purges days oldest first.
    static func revision(_ stored: String, describes current: String, timeZone: String) -> Bool {
        if stored == current { return true }
        guard stored.hasSuffix(timeZone), current.hasSuffix(timeZone) else { return false }
        let a = stored.dropLast(timeZone.count).split(separator: ";", omittingEmptySubsequences: false)
        let b = current.dropLast(timeZone.count).split(separator: ";", omittingEmptySubsequences: false)
        guard a.count == 3, b.count == 3, a[1] == b[1], a[1] != "missing" else { return false }
        return [0, 2].allSatisfy { a[$0] == b[$0] || b[$0] == "missing" }
    }

    package func readPrivateFile(name: String, maximumBytes: Int) throws -> Data {
        let fd = try directory(create: false); defer { close(fd) }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= maximumBytes,
              let bytes = try handle.read(upToCount: maximumBytes + 1), bytes.count == info.st_size else { throw Failure.unsafePath }
        var after = stat()
        guard fstat(file, &after) == 0, info.st_size == after.st_size,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.sourceChanged }
        return bytes
    }

    /// Metadata only, through the same private, no-follow directory as checkpoint I/O.
    package func privateFileModificationDate(name: String, maximumBytes: Int) throws -> Date {
        let fd = try directory(create: false); defer { close(fd) }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= maximumBytes else { throw Failure.unsafePath }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    public func read(day: Date, sourceRevision: String? = nil, calendar: Calendar = .current) throws -> GoalongLocalAnalytics.Day {
        try readSummary(day: day, sourceRevision: sourceRevision, calendar: calendar).day
    }

    /// True when the saved summary of this date is valid but was written in another time zone.
    /// Such a summary is the settled account of the day: it is never replaced by a recount.
    public func hasForeignTimeZoneSummary(day: Date, calendar: Calendar = .current) -> Bool {
        (try? readSummary(day: day, sourceRevision: nil, calendar: calendar))?.foreign == true
    }

    private func readSummary(day: Date, sourceRevision: String?, calendar: Calendar) throws -> (day: GoalongLocalAnalytics.Day, foreign: Bool) {
        let key = Self.dayKey(day, calendar: calendar)
        let bytes = try readPrivateFile(name: key + ".json", maximumBytes: Self.maximumBytes)
        let e = try JSONDecoder().decode(Envelope.self, from: bytes)
        // A summary written in another time zone describes the same date in that zone. Without
        // a journal it is still the only account of the day: validate it in its own zone, then
        // place it on this zone's date. With a journal, the day is recounted in this zone.
        var zone = calendar
        let foreign = e.timeZone != calendar.timeZone.identifier
        let start: Date
        if foreign {
            guard sourceRevision == nil, let timeZone = TimeZone(identifier: e.timeZone) else { throw Failure.invalidSummary }
            zone.timeZone = timeZone
            let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = timeZone
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
            guard let parsed = f.date(from: key) else { throw Failure.invalidSummary }
            start = zone.startOfDay(for: parsed)
        } else {
            start = calendar.startOfDay(for: day)
        }
        guard let end = zone.date(byAdding: .day, value: 1, to: start) else { throw Failure.invalidSummary }
        // Without a journal, a summary from an older method is still the only account of the day.
        guard e.schema == Self.schema, e.method == GoalongLocalAnalytics.method || sourceRevision == nil,
              e.date == key, e.start == start, e.end == end, e.state == .ready, e.eventCount > 0,
              sourceRevision.map({ Self.revision(e.sourceRevision, describes: $0, timeZone: calendar.timeZone.identifier) }) ?? true,
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
            guard let boundary = zone.dateInterval(of: .hour, for: hour.start),
                  boundary.start == hour.start, boundary.end == hour.end, hour.start >= previousEnd else { throw Failure.invalidSummary }
            let active = segments.filter { $0.kind.isActive }.reduce(0.0) {
                $0 + max(0, min($1.end, hour.end).timeIntervalSince(max($1.start, hour.start)))
            }
            guard active == hour.totalSeconds else { throw Failure.invalidSummary }
            previousEnd = hour.end
        }
        guard foreign else { return (result, false) }
        // Same wall-clock day, moved onto this zone's date so pages match it to the selected day.
        // Each instant keeps its wall-clock time (15:00 in Paris shows at 15:00 here), also after
        // a clock change in either zone. A repeated hour overlaps itself: active time wins, then
        // the first pass. A skipped hour, or this day's extra hour, is marked as not recorded.
        // The saved summary itself stays unchanged.
        let localStart = calendar.startOfDay(for: day)
        guard let localEnd = calendar.date(byAdding: .day, value: 1, to: localStart), localEnd > localStart else { throw Failure.invalidSummary }
        let mapping = WallClockMapping(origin: zone.timeZone, start: start, end: end,
                                       local: calendar.timeZone, localStart: localStart, localEnd: localEnd)
        let moved = mapping.segments(segments)
        var hourIndex: [Date: Int] = [:], hours: [GoalongActivityBreakdown.Hour] = []
        for hour in e.breakdown.hours {
            guard let range = mapping.range(hour.start, hour.end) else { continue }
            if let index = hourIndex[range.from] {
                hours[index] = .init(start: hours[index].start, end: max(hours[index].end, range.to),
                    secondsByMode: hours[index].secondsByMode.merging(hour.secondsByMode, uniquingKeysWith: +))
            } else {
                hourIndex[range.from] = hours.count
                hours.append(.init(start: range.from, end: range.to, secondsByMode: hour.secondsByMode))
            }
        }
        hours.sort { $0.start < $1.start }
        let movedFirst = mapping.point(first), movedLast = mapping.point(last)
        let movedDay = GoalongLocalAnalytics.Day(date: localStart, end: localEnd, state: .ready, segments: moved,
            eventCount: e.eventCount, classifierVersions: Set(e.classifierVersions), origin: .summary, hasDetailedSource: false,
            firstObservation: min(movedFirst, movedLast), lastObservation: max(movedFirst, movedLast),
            recordedBreakdown: GoalongActivityBreakdown(hours: hours))
        return (movedDay, true)
    }

    /// Moves instants of one zone's day onto the same wall-clock times of another zone's date.
    struct WallClockMapping {
        let origin: TimeZone, start: Date, end: Date
        let local: TimeZone, localStart: Date, localEnd: Date

        /// Seconds since the origin day's wall-clock midnight, with the offset in force at `reference`.
        private func wall(_ t: Date, reference: Date) -> TimeInterval {
            t.timeIntervalSince(start) + Double(origin.secondsFromGMT(for: reference) - origin.secondsFromGMT(for: start))
        }
        /// The local instant showing wall time `w`, with the local offset in force at `reference` seconds.
        private func instant(_ w: TimeInterval, reference: TimeInterval) -> Date {
            let shift = local.secondsFromGMT(for: localStart.addingTimeInterval(reference)) - local.secondsFromGMT(for: localStart)
            return localStart.addingTimeInterval(w - Double(shift))
        }
        private func transitions(_ zone: TimeZone, from: Date, to: Date) -> [Date] {
            var output: [Date] = [], cursor = from
            while output.count < 8, let next = zone.nextDaylightSavingTimeTransition(after: cursor), next < to {
                output.append(next); cursor = next
            }
            return output
        }
        private func clamp(_ t: Date) -> Date { min(max(t, localStart), localEnd) }

        func point(_ t: Date) -> Date { clamp(instant(wall(t, reference: t), reference: wall(t, reference: t))) }

        /// Mapped pieces of [from, to), cut at both zones' clock changes so each piece moves by one offset.
        func pieces(_ from: Date, _ to: Date) -> [(from: Date, to: Date)] {
            var output: [(from: Date, to: Date)] = []
            let originCuts = transitions(origin, from: from, to: to)
            let localCuts = transitions(local, from: localStart, to: localEnd).map { $0.timeIntervalSince(localStart) }
            for (a, b) in zip([from] + originCuts, originCuts + [to]) where b > a {
                let w1 = wall(a, reference: a), w2 = wall(b, reference: a)
                let inside = localCuts.filter { $0 > w1 && $0 < w2 }
                for (x, y) in zip([w1] + inside, inside + [w2]) where y > x {
                    let mappedFrom = clamp(instant(x, reference: x)), mappedTo = clamp(instant(y, reference: x))
                    if mappedTo > mappedFrom { output.append((mappedFrom, mappedTo)) }
                }
            }
            return output
        }

        /// One continuous local interval for an origin hour, or nil when it falls outside this date.
        func range(_ from: Date, _ to: Date) -> (from: Date, to: Date)? {
            let parts = pieces(from, to)
            guard let first = parts.first, let last = parts.last else { return nil }
            return (first.from, max(first.to, last.to))
        }

        func segments(_ source: [GoalongLocalAnalytics.Segment]) -> [GoalongLocalAnalytics.Segment] {
            typealias Segment = GoalongLocalAnalytics.Segment
            struct Piece { let from: Date, to: Date, rank: Int, order: Int, source: Int, segment: Segment }
            var all: [Piece] = []
            for (index, segment) in source.enumerated() {
                let rank = segment.kind.isActive ? 2 : segment.kind == .unobserved ? 0 : 1
                for part in pieces(segment.start, segment.end) {
                    all.append(.init(from: part.from, to: part.to, rank: rank, order: all.count, source: index, segment: segment))
                }
            }
            func piece(_ s: Segment, _ from: Date, _ to: Date) -> Segment {
                .init(start: from, end: to, kind: s.kind, application: s.application, bundleIdentifier: s.bundleIdentifier,
                      host: s.host, contextKey: s.contextKey, coverageReason: s.coverageReason)
            }
            let missing = Segment(start: localStart, end: localEnd, kind: .unobserved, application: nil, bundleIdentifier: nil,
                                  host: nil, contextKey: nil, coverageReason: .notRecorded)
            let bounds = Array(Set(all.flatMap { [$0.from, $0.to] } + [localStart, localEnd])).sorted()
            let byStart = all.sorted { ($0.from, $0.order) < ($1.from, $1.order) }
            var open: [Piece] = [], next = 0, output: [Segment] = [], lastSource = -1
            for (a, b) in zip(bounds, bounds.dropFirst()) {
                while next < byStart.count, byStart[next].from <= a { open.append(byStart[next]); next += 1 }
                open.removeAll { $0.to <= a }
                let best = open.max { ($0.rank, -$0.order) < ($1.rank, -$1.order) }
                // Pieces of one source segment, cut at a clock change, join again when adjacent.
                let source = best?.source ?? -2
                if source == lastSource, let previous = output.last, previous.end == a {
                    output[output.count - 1] = piece(previous, previous.start, b)
                } else {
                    output.append(piece(best?.segment ?? missing, a, b))
                }
                lastSource = source
            }
            return output
        }
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
        try writePrivateFile(bytes, name: e.date + ".json")
    }

    package func writePrivateFile(_ bytes: Data, name: String) throws {
        guard name.range(of: #"^\d{4}-\d{2}-\d{2}(\.json|\.resume\.plist|\.purged)$"#, options: .regularExpression) != nil else {
            throw Failure.unsafePath
        }
        let fd = try directory(create: true); defer { close(fd) }
        let temporary = Self.temporaryPrefix + UUID().uuidString
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

    /// What a journal leaves behind before retention deletes it.
    public enum Preservation: Equatable, Sendable {
        /// A valid summary of the day is on disk.
        case summarized
        /// The journal holds no activity evidence (only health or permission rows): nothing to keep.
        case nothingToSummarize
        /// The journal stayed unchanged but its content cannot be read completely (corrupt or
        /// oversized line, evidence budget). Its day has no summary; retention still applies.
        case unreadable
    }

    /// Writes only if the journal is unchanged across the full read. A failed save, a source that
    /// changes during the read or incomplete access to events/ never permits purge; a day with
    /// nothing to summarize, or a stable journal with a content defect, does (the retention
    /// policy still applies).
    @discardableResult
    public func preserveBeforePurge(day: Date, now: Date = Date(), calendar: Calendar = .current) throws -> Preservation {
        let revision = sourceRevision(day: day, calendar: calendar)
        if (try? read(day: day, sourceRevision: revision, calendar: calendar)) != nil || hasForeignTimeZoneSummary(day: day, calendar: calendar) {
            guard revision == sourceRevision(day: day, calendar: calendar) else { throw Failure.sourceChanged }
            return .summarized
        }
        let (value, defect) = GoalongLocalAnalytics.loadReportingDefect(root: root, day: day, now: now, calendar: calendar)
        guard revision == sourceRevision(day: day, calendar: calendar) else { throw Failure.sourceChanged }
        switch value.state {
        case .noSource: markPurgedWithoutSummary(day: day, calendar: calendar); return .nothingToSummarize
        // Only a defect in the journals' own content is permanent. Incomplete access to events/
        // (a linked or foreign entry, a listing that changed, a cancelled read) keeps the journal.
        case .incomplete:
            guard defect == .content else { throw Failure.sourceChanged }
            markPurgedWithoutSummary(day: day, calendar: calendar); return .unreadable
        case .ready: break
        }
        try write(value, sourceRevision: revision, now: now, calendar: calendar)
        _ = try read(day: day, sourceRevision: revision, calendar: calendar)
        guard revision == sourceRevision(day: day, calendar: calendar) else { throw Failure.sourceChanged }
        return .summarized
    }

    /// Best effort: without the marker the day later reads as « no data » instead of
    /// « erased without summary »; it never blocks the purge itself.
    private func markPurgedWithoutSummary(day: Date, calendar: Calendar) {
        try? writePrivateFile(Data("purged\n".utf8), name: Self.dayKey(day, calendar: calendar) + Self.purgeMarkerSuffix)
    }

    /// A day without journal was really erased only if retention left a trace of it: its marker,
    /// or a summary file that can no longer be read. A day never recorded has neither.
    private func hasPurgeTrace(day: Date, calendar: Calendar) -> Bool {
        let key = Self.dayKey(day, calendar: calendar)
        guard let fd = try? directory(create: false) else { return false }
        defer { close(fd) }
        return [Self.purgeMarkerSuffix, ".json"].contains { suffix in
            var info = stat()
            return fstatat(fd, key + suffix, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG
        }
    }

    public func load(day: Date, now: Date = Date(), calendar: Calendar = .current, retentionDays: Int? = 30, summaryRetentionDays: Int? = nil,
                     allowsCheckpoints: Bool = true,
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
        var value = loadResumable(day: start, now: now, calendar: calendar,
            retentionDays: retentionDays, allowsCheckpoints: allowsCheckpoints, shouldContinue: shouldContinue).day
        if value.state == .noSource, absent, let days = retentionDays, days > 0,
           let cutoff = calendar.date(byAdding: .day, value: -days, to: now), start < calendar.startOfDay(for: cutoff),
           hasPurgeTrace(day: start, calendar: calendar) {
            value.dayReason = .purgedWithoutSummary
            value = .init(date: value.date, end: value.end, state: value.state, segments: value.segments.map {
                var segment = $0; segment.coverageReason = .purgedWithoutSummary; return segment
            }, eventCount: 0, classifierVersions: [], dayReason: .purgedWithoutSummary)
        }
        value.hasDetailedSource = !absent
        if past, value.state == .ready, Self.isSettled(start, now: now, calendar: calendar), shouldContinue(),
           retains(day: start, now: now, days: summaryRetentionDays, calendar: calendar),
           revision == sourceRevision(day: start, calendar: calendar),
           !hasForeignTimeZoneSummary(day: start, calendar: calendar) {
            try? write(value, sourceRevision: revision, now: now, calendar: calendar)
        }
        return value
    }

    /// The same fold serves today and a recently ended day. It is always disposable:
    /// deleted/truncated/rewritten sources reject it instead of becoming summary data.
    public func loadResumable(day: Date, resuming state: GoalongLocalAnalytics.ResumableDayState? = nil,
                             now: Date = Date(), calendar: Calendar = .current, retentionDays: Int? = 30,
                             allowsCheckpoints: Bool = true,
                             shouldContinue: () -> Bool = { true }) -> GoalongLocalAnalytics.ResumableDayLoad {
        let checkpoints = GoalongActivityCheckpointStore(root: root)
        var checkpointBytesHashed: Int64 = 0
        let revision = checkpoints.sourceRevision(day: day, calendar: calendar)
        let previous = allowsCheckpoints ? state ?? (shouldContinue() ? try? checkpoints.read(day: day, calendar: calendar,
            shouldContinue: shouldContinue, prefixBytesHashed: { checkpointBytesHashed += Int64($0) }) : nil) : nil
        var loaded = GoalongLocalAnalytics.load(root: root, day: day, resuming: previous,
            now: now, calendar: calendar, shouldContinue: shouldContinue)
        // Disk-prefix validation and suffix decoding are separate reads. A rewrite
        // between them must reject the old fold even if its last line is unchanged.
        if loaded.didResume, revision != checkpoints.sourceRevision(day: day, calendar: calendar), shouldContinue() {
            loaded = GoalongLocalAnalytics.load(root: root, day: day, resuming: nil,
                now: now, calendar: calendar, shouldContinue: shouldContinue)
        }
        if allowsCheckpoints, !loaded.wasCancelled, loaded.day.state != .incomplete, let next = loaded.state,
           (next.cursor != previous?.cursor || (next.isFinished && previous?.isFinished == false)),
           checkpoints.shouldWrite(day: day, now: now, calendar: calendar), shouldContinue(),
           retains(day: day, now: now, days: retentionDays, calendar: calendar) {
            try? checkpoints.write(next, day: day, sourceRevision: revision,
                calendar: calendar, shouldContinue: shouldContinue,
                prefixBytesHashed: { checkpointBytesHashed += Int64($0) })
        }
        loaded.checkpointBytesHashed = checkpointBytesHashed
        return loaded
    }

    public func journalDays(before now: Date = Date(), calendar: Calendar = .current) throws -> [Date] {
        let folder = root.appendingPathComponent("events")
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard names.count <= 20_000 else { throw Failure.unavailable }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = calendar.timeZone
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
            guard Self.isSettled(day, now: now, calendar: calendar),
                  retains(day: day, now: now, days: summaryRetentionDays, calendar: calendar) else { continue }
            let revision = sourceRevision(day: day, calendar: calendar)
            if (try? read(day: day, sourceRevision: revision, calendar: calendar)) != nil
                || hasForeignTimeZoneSummary(day: day, calendar: calendar) { continue }
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
