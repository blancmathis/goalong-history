#if os(macOS)
import Foundation
import Combine
import LocalHistoryCore

enum GoalongAnalyticsFormatting {
    /// A missing/zero measurement must never acquire a minute through presentation rounding.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        return DashboardFormatters.duration(seconds: seconds)
    }
}

/// Seconds and minutes remain legible for a sparse first day instead of disappearing
/// against a fixed 60-minute / one-hour vertical axis.
struct GoalongAnalyticsChartScale {
    let unitSeconds: Double
    let unit: String
    let upperBound: Double

    init(maximumSeconds: Double, hourly: Bool = false) {
        let maximum = maximumSeconds.isFinite ? max(0, maximumSeconds) : 0
        if maximum < 60 { unitSeconds = 1; unit = "s" }
        else if hourly || maximum < 3600 { unitSeconds = 60; unit = "min" }
        else { unitSeconds = 3600; unit = "h" }
        let raw = maximum / unitSeconds
        let step: Double = unitSeconds == 3600 ? 0.5 : (raw > 30 ? 10 : (raw > 10 ? 5 : 1))
        let bound = max(step, ceil(raw * 1.12 / step) * step)
        upperBound = hourly && unitSeconds == 60 ? min(60, bound) : bound
    }
    func label(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "fr_FR")).precision(.fractionLength(0...1))) + "\u{00A0}" + unit
    }
}

struct GoalongAnalyticsCard: Identifiable, Sendable {
    let id: String
    let day: String
    let module: String
    let title: String
    let summary: String
    let status: String
    let caveat: String
}
/// R13c: what a payload was read from. While none of it changed, the payload can go on screen again at once.
struct GoalongAnalyticsSources: Sendable, Equatable {
    /// Each day of the period and of its comparison, with its source revision taken before the read.
    var days: [Date: String]
    /// The days whose saved daily recap is shown, and the stamp of the recaps and saved analyses.
    let cardDays: [Date]
    let cards: String
}

struct GoalongAnalyticsPayload: Sendable {
    let current: GoalongLocalAnalytics.Period
    let previous: GoalongLocalAnalytics.Period
    let cards: [GoalongAnalyticsCard]
    let archiveNotice: String?
    let updatedAt: Date
    let isPreview: Bool
    /// The selected period is shown first; its comparison (an empty `previous`) follows.
    let comparisonPending: Bool
    /// Nil for the preview and the gallery's fixed payloads: never shown again from memory.
    let sources: GoalongAnalyticsSources?
    /// R14a: the tasks of `current`, computed once with the payload (where it is built, off the click), not by each
    /// evaluation of the page: a period shown again re-evaluates its page in the click.
    let tasks: [GoalongWorkTask]

    init(current: GoalongLocalAnalytics.Period, previous: GoalongLocalAnalytics.Period,
         cards: [GoalongAnalyticsCard], archiveNotice: String?, updatedAt: Date, isPreview: Bool = false,
         comparisonPending: Bool = false, sources: GoalongAnalyticsSources? = nil) {
        self.current = current; self.previous = previous; self.cards = cards
        self.archiveNotice = archiveNotice; self.updatedAt = updatedAt; self.isPreview = isPreview
        self.comparisonPending = comparisonPending; self.sources = sources
        tasks = current.tasks
    }

    func with(previous: GoalongLocalAnalytics.Period, revisions: [Date: String]) -> Self {
        var sources = sources
        sources?.days.merge(revisions) { _, new in new }
        return Self(current: current, previous: previous, cards: cards, archiveNotice: archiveNotice,
                    updatedAt: updatedAt, isPreview: isPreview, sources: sources)
    }
}

/// Lives off the main actor and outlives the dashboard window, so reopening it shows the
/// days already read. Stores only bounded derived measurements, never source events.
actor GoalongAnalyticsReader {
    static let shared = GoalongAnalyticsReader(root: AppPaths.applicationSupportDirectory)
    /// Recently shown days (about 0.5 MB for a busy one): enough for a 28-day period and
    /// its comparison, plus a few days visited around it.
    private static let maximumCachedDays = 64
    private var cache: [Date: (String, GoalongLocalAnalytics.Day)] = [:]
    private var lastUse: [Date: Int] = [:]
    private var uses = 0
    /// Cached days with the user's verdicts applied, for the same source revision (R13c): applying them to 56 days
    /// took ~55 ms per read. Same bound as `cache`; emptied when the verdicts change.
    private var applied: [Date: (String, GoalongLocalAnalytics.Day)] = [:]
    private var appliedVerdicts = GoalongWorkVerdicts()
    /// Today's journal is read once, then only the lines appended since. The checkpoint
    /// holds derived segments and the last 15 minutes of rows (about 2 MB on a busy day).
    private var today: (date: Date, revision: String, state: GoalongLocalAnalytics.ResumableDayState)?
    private(set) var todayCheckpointBytesHashed: Int64 = 0
    private(set) var todayEventBytesRead: Int64 = 0
    /// The data folder this reader was given; the page lists the imported days here, never in the real folder (R272b-2).
    let root: URL
    /// The real clock in the app; a fixed one in tests and the gallery.
    nonisolated let now: @Sendable () -> Date
    init(root: URL, now: @escaping @Sendable () -> Date = { GoalongToday.now }) { self.root = root; self.now = now }

    /// Focus reuses the same validated day cache and bounded current-day fold, without
    /// loading recap cards, starting analysis or changing the Activity selection.
    func focusDay(_ day: Date, verdicts: GoalongWorkVerdicts) throws -> GoalongLocalAnalytics.Day {
        try Task.checkCancellation()
        let value = try days(ending: Calendar.current.startOfDay(for: day), count: 1, now: now(), calendar: .current)[0]
        return value.day.applying(verdicts)
    }

    func read(ending day: Date, count: Int, force: Bool, preview: Bool,
              verdicts: GoalongWorkVerdicts = GoalongWorkVerdicts()) throws -> GoalongAnalyticsPayload {
        try Task.checkCancellation()
        // Preview exits before looking at caches, journals, daily reports or project archives.
        if preview { return GoalongAnalyticsPreview.make(ending: day, count: count, now: now()) }
        _ = try GoalongGlobalPause.admit(in: root)
        let calendar = Calendar.current, now = self.now()
        let count = [1, 7, 28].contains(count) ? count : 7
        let last = calendar.startOfDay(for: day)
        if force { cache.removeAll(); lastUse.removeAll(); applied.removeAll(); today = nil }
        let current = try days(ending: last, count: count, now: now, calendar: calendar)
        let previousLast = calendar.date(byAdding: .day, value: -count, to: last) ?? last
        // A comparison that needs a journal read waits for `comparison(for:)`: the selected
        // period goes on screen first.
        let previous = cachedDays(ending: previousLast, count: count, now: now, calendar: calendar)
        let cardDays = current.prefix(28).map(\.date)
        let cardsStamp = Self.cardsStamp(root: root, days: cardDays)
        let saved = try readCards(start: current.first?.day.date ?? last, end: current.last?.day.end ?? now)
        let recaps = try readDailyRecaps(days: current.map(\.day), calendar: calendar)
        let cards = (saved.0 + recaps.0).sorted { a, b in a.day == b.day ? a.id < b.id : a.day > b.day }
        let notices = [saved.1, recaps.1].compactMap { $0 }
        let revisions = Dictionary((current + (previous ?? [])).map { ($0.date, $0.revision) }) { _, new in new }
        // The cache keeps raw days; the verdicts of the user's work definition are applied on
        // every read, so a new verdict or correction never requires reading the journals again.
        return GoalongAnalyticsPayload(current: applying(verdicts, to: current, now: now, calendar: calendar),
            previous: applying(verdicts, to: previous ?? [], now: now, calendar: calendar),
            cards: cards, archiveNotice: notices.isEmpty ? nil : notices.joined(separator: " "), updatedAt: now,
            comparisonPending: previous == nil,
            sources: GoalongAnalyticsSources(days: revisions, cardDays: cardDays, cards: cardsStamp))
    }

    /// A day read before is applied the verdicts once per source revision; today always again.
    private func applying(_ verdicts: GoalongWorkVerdicts, to days: [ReadDay], now: Date,
                          calendar: Calendar) -> GoalongLocalAnalytics.Period {
        if verdicts != appliedVerdicts { applied.removeAll(); appliedVerdicts = verdicts }
        return GoalongLocalAnalytics.Period(days: days.map { item in
            // The value is the cached one only when the cache holds it under the revision taken before the read.
            let revision = item.cacheRevision
            let reusable = revision != nil && cache[item.date]?.0 == revision
            if reusable, let held = applied[item.date], held.0 == revision { return held.1 }
            let value = item.day.applying(verdicts)
            if reusable, let revision { applied[item.date] = (revision, value) }
            return value
        })
    }

    /// Reads the previous period of the same length, after the selected one is on screen.
    func comparison(for payload: GoalongAnalyticsPayload, verdicts: GoalongWorkVerdicts) throws -> GoalongAnalyticsPayload {
        let calendar = Calendar.current
        guard payload.comparisonPending, let first = payload.current.days.first,
              let previousLast = calendar.date(byAdding: .day, value: -1, to: first.date) else { return payload }
        let previous = try days(ending: previousLast, count: payload.current.days.count,
            now: payload.updatedAt, calendar: calendar)
        return payload.with(previous: applying(verdicts, to: previous, now: payload.updatedAt, calendar: calendar),
                            revisions: Dictionary(previous.map { ($0.date, $0.revision) }) { _, new in new })
    }

    /// A day as read, with the source revision taken before reading it.
    private struct ReadDay {
        let date: Date; let revision: String; let day: GoalongLocalAnalytics.Day
        /// The reader cache's revision when `day` is the cached value, else nil (today, an incomplete day).
        let cacheRevision: String?
    }

    private func days(ending last: Date, count: Int, now: Date, calendar: Calendar) throws -> [ReadDay] {
        let pause = try GoalongGlobalPause.admit(in: root)
        let barrier = DerivedHistoryWriteBarrier.shared
        guard let permit = barrier.beginJob() else { throw CancellationError() }
        defer { barrier.endJob(permit) }
        var days: [ReadDay] = []
        for offset in (0..<count).reversed() {
            try Task.checkCancellation()
            guard let date = calendar.date(byAdding: .day, value: -offset, to: last) else { continue }
            let revision = sourceRevision(date, calendar: calendar)
            let value: GoalongLocalAnalytics.Day
            if calendar.isDate(date, inSameDayAs: now) {
                value = try readToday(date, now: now, calendar: calendar)
            } else if let cached = cache[date], cached.0 == revision {
                value = cached.1
            } else if let held = today, calendar.isDate(held.date, inSameDayAs: date) {
                // The day that just ended is finished from its checkpoint, not read again.
                value = try readToday(date, now: now, calendar: calendar)
                if value.state != .incomplete { cache[date] = (sourceRevision(date, calendar: calendar), value) }
            } else {
                value = GoalongActivityDayReader.load(root: root, day: date, now: now, calendar: calendar,
                    shouldContinue: { !Task.isCancelled })
                try Task.checkCancellation()
                if value.state != .incomplete { cache[date] = (sourceRevision(date, calendar: calendar), value) }
            }
            // The read itself may write the day's summary and checkpoint: those parts are taken after it. The journal
            // part stays the one taken before, so rows written during the read always count as a change.
            let after = sourceRevision(date, calendar: calendar)
            let stamp = (revision.components(separatedBy: "|summary|").first ?? revision) + "|summary|"
                + (after.components(separatedBy: "|summary|").dropFirst().joined(separator: "|summary|"))
            let fromCache = !calendar.isDate(date, inSameDayAs: now) && value.state != .incomplete
            days.append(ReadDay(date: date, revision: stamp, day: value, cacheRevision: fromCache ? cache[date]?.0 : nil))
            uses += 1
            if cache[date] != nil { lastUse[date] = uses }
        }
        try GoalongGlobalPause.revalidate(pause, in: root)
        guard barrier.isCurrent(permit) else { throw CancellationError() }
        if cache.count > Self.maximumCachedDays {
            let evicted = cache.keys.sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }.prefix(cache.count - Self.maximumCachedDays)
            for date in evicted { cache[date] = nil; lastUse[date] = nil; applied[date] = nil }
        }
        return days
    }

    func readToday(_ date: Date, now: Date, calendar: Calendar) throws -> GoalongLocalAnalytics.Day {
        // Close the previous in-memory day before the regular refresh switches to today.
        // No new timer; the adapter still applies pause, retention and deletion admission.
        if calendar.isDate(date, inSameDayAs: now), let held = today,
           held.date < calendar.startOfDay(for: now) {
            _ = try readToday(held.date, now: now, calendar: calendar)
        }
        let revision = GoalongActivityCheckpointStore(root: root).sourceRevision(day: date, calendar: calendar)
        let previous = today.flatMap { calendar.isDate($0.date, inSameDayAs: date)
                && Self.canResumeInMemory(from: $0.revision, to: revision) ? $0.state : nil }
        let loaded = GoalongActivityDayReader.loadResumable(root: root, day: date, resuming: previous, now: now,
            calendar: calendar, shouldContinue: { !Task.isCancelled })
        todayCheckpointBytesHashed = loaded.checkpointBytesHashed
        todayEventBytesRead = loaded.eventBytesRead
        // The cursor validates device/inode, consumed size, last line and the stable read.
        // Growth can use that bounded check; same-size edits still take disk validation.
        today = loaded.state.flatMap {
            revision == GoalongActivityCheckpointStore(root: root).sourceRevision(day: date, calendar: calendar)
                ? (date, revision, $0) : nil
        }
        try Task.checkCancellation()
        return loaded.day
    }

    static func canResumeInMemory(from previous: String, to current: String) -> Bool {
        if previous == current { return true }
        let old = previous.split(separator: "|"), new = current.split(separator: "|")
        // sourceRevision: device, inode, size, mtime, ctime, timezone.
        guard old.count == 6, new.count == 6, old[0] == new[0], old[1] == new[1], old[5] == new[5],
              let oldSize = Int64(old[2]), let newSize = Int64(new[2]) else { return false }
        return newSize > oldSize
    }

    /// Moves today's checkpoint forward between visits, so opening Activité decodes
    /// minutes of journal rather than everything written since the last visit.
    func advanceToday() {
        let calendar = Calendar.current
        let now = self.now()
        _ = try? readToday(calendar.startOfDay(for: now), now: now, calendar: calendar)
    }

    /// The period's days when none needs a journal read, nil otherwise.
    private func cachedDays(ending last: Date, count: Int, now: Date, calendar: Calendar) -> [ReadDay]? {
        var days: [ReadDay] = []
        for offset in (0..<count).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: last),
                  !calendar.isDate(date, inSameDayAs: now), let cached = cache[date],
                  cached.0 == sourceRevision(date, calendar: calendar) else { return nil }
            days.append(ReadDay(date: date, revision: cached.0, day: cached.1, cacheRevision: cached.0))
            uses += 1
            lastUse[date] = uses
        }
        return days
    }

    /// Reads only existing bounded reports. Does not select a day in the shared recap
    /// runtime, cancel an analysis, build its context, or launch an agent.
    private func readDailyRecaps(days: [GoalongLocalAnalytics.Day], calendar: Calendar) throws -> ([GoalongAnalyticsCard], String?) {
        let directory = root.appendingPathComponent("chatgpt/recaps", isDirectory: true)
        var cards: [GoalongAnalyticsCard] = []
        var rejected = 0
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        for day in days.prefix(28) {
            try Task.checkCancellation()
            let path = ChatGPTRecapPersistence.jsonURL(for: day.date, in: directory)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            guard let recap = ChatGPTRecapPersistence.load(for: day.date, from: directory),
                  calendar.isDate(recap.day, inSameDayAs: day.date) else {
                rejected += 1
                continue
            }
            let date = formatter.string(from: day.date)
            cards.append(GoalongAnalyticsCard(id: "daily-recap|" + date, day: date, module: "dailyRecap",
                title: "Bilan du " + day.date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated)),
                summary: recap.markdown, status: "inferred",
                caveat: "Synthèse IA enregistrée. Ses sources peuvent différer des seules observations sur ce Mac."))
        }
        return (cards, rejected > 0 ? "\(FrenchCount.count(rejected, "bilan", "bilans")) \(FrenchCount.word(rejected, "quotidien illisible ou incohérent n’est", "quotidiens illisibles ou incohérents ne sont")) pas \(FrenchCount.word(rejected, "affiché", "affichés"))." : nil)
    }

    private func sourceRevision(_ day: Date, calendar: Calendar) -> String {
        GoalongActivityDayReader.sourceRevision(root: root, day: day, calendar: calendar)
    }

    /// Saved analyses (any file added, removed or replaced changes the folder) and each shown day's recap.
    static func cardsStamp(root: URL, days: [Date]) -> String {
        let recaps = root.appendingPathComponent("chatgpt/recaps", isDirectory: true)
        return ([root.appendingPathComponent("chatgpt/profile-analyses", isDirectory: true), recaps]
            + days.map { ChatGPTRecapPersistence.jsonURL(for: $0, in: recaps) }).map { url -> String in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return "-" }
            return "\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
        }.joined(separator: ";")
    }

    enum SourceMatch { case changed, grown, same }

    /// `.same` while every source of `sources` is unchanged: a new read would give the same payload. `.grown` when
    /// only today's journal grew (rows appended since the read, shown by the read that follows). A few hundred
    /// `stat` calls for 28 days and their comparison.
    nonisolated static func match(_ sources: GoalongAnalyticsSources, root: URL, now: Date,
                                  calendar: Calendar) -> SourceMatch {
        var result = SourceMatch.same
        for (date, stored) in sources.days {
            let current = GoalongActivityDayReader.sourceRevision(root: root, day: date, calendar: calendar)
            guard current != stored else { continue }
            guard calendar.isDate(date, inSameDayAs: now),
                  let old = stored.components(separatedBy: "|summary|").first,
                  let new = current.components(separatedBy: "|summary|").first,
                  canResumeInMemory(from: old, to: new) else { return .changed }
            result = .grown
        }
        return cardsStamp(root: root, days: sources.cardDays) == sources.cards ? result : .changed
    }

    static func savedAnalysesNotice(truncated: Bool, rejected: Int) -> String? {
        var parts: [String] = []
        if truncated { parts.append("Seules les 64 analyses enregistrées les plus récentes sont lues.") }
        if rejected > 0 {
            parts.append("\(FrenchCount.count(rejected, "analyse enregistrée", "analyses enregistrées")) \(FrenchCount.word(rejected, "illisible n’est", "illisibles ne sont")) pas \(FrenchCount.word(rejected, "affichée", "affichées")).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func readCards(start: Date, end: Date) throws -> ([GoalongAnalyticsCard], String?) {
        let folder = root.appendingPathComponent("chatgpt/profile-analyses", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return ([], nil) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            return ([], "Les analyses enregistrées ne sont pas accessibles.")
        }
        var files: [(URL, Date)] = [], visited = 0, rejected = 0
        for case let file as URL in iterator {
            try Task.checkCancellation()
            visited += 1
            if visited > 512 { break }
            guard file.lastPathComponent.hasSuffix(".analysis.json") else { continue }
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 256 * 1024 else {
                rejected += 1; continue
            }
            files.append((file, values.contentModificationDate ?? .distantPast))
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        let first = formatter.string(from: start), last = formatter.string(from: end.addingTimeInterval(-0.001))
        var cards: [GoalongAnalyticsCard] = [], seen = Set<String>()
        for (file, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(64) {
            try Task.checkCancellation()
            do {
                let data = try GoalongSiteAnalysisRequest.readSelectedBytes(file)
                let archive = try GoalongProfileAnalysis.parseArchive(data)
                let context = try archive.request.context()
                guard context.date >= first, context.date <= last else { continue }
                let result = try GoalongProfileAnalysis.apply(archive.result, to: archive.request)
                let modules = Set(result.items.map(\.module)).filter { !seen.contains(context.date + "|" + $0) }
                for item in result.items where modules.contains(item.module) {
                    cards.append(GoalongAnalyticsCard(id: archive.request.request_id + "|" + item.id,
                        day: context.date, module: item.module, title: item.title, summary: item.summary,
                        status: item.status, caveat: item.caveat))
                }
                for module in modules { seen.insert(context.date + "|" + module) }
            } catch { rejected += 1 }
        }
        let notice = Self.savedAnalysesNotice(truncated: visited > 512 || files.count > 64, rejected: rejected)
        return (cards, notice)
    }
}

@MainActor final class GoalongAnalyticsModel: ObservableObject {
    @Published private(set) var payload: GoalongAnalyticsPayload?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    /// The global pause suspends reads of the observations: no error, nothing to retry.
    @Published private(set) var paused = false
    private let reader: GoalongAnalyticsReader
    private var operation = UUID()
    /// Reads started and not finished, all pages together. The gallery waits for 0 before it captures Activité.
    private(set) static var loadsInFlight = 0
    /// Every read started, for the view-switch budget test (R13a).
    private(set) static var loadsStarted = 0

    /// R13c: the last complete read of each period (key: last day and count), shown again at once when the user
    /// comes back to it, then read again. An entry is shown only while its verdicts, its day, the history-clear
    /// generation and every source it was read from are the same. Any change of data or classification empties it.
    private struct Snapshot {
        let payload: GoalongAnalyticsPayload
        let verdicts: GoalongWorkVerdicts
        let admission: DerivedHistoryWriteBarrier.Admission
        var use: Int
    }
    private var snapshots: [String: Snapshot] = [:]
    private var snapshotUses = 0
    /// Raised by `forgetSnapshots()`; `storeSnapshot` refuses a read that started under an older value.
    private(set) var snapshotGeneration = 0
    private var recentMatch: (key: String, updatedAt: Date, match: GoalongAnalyticsReader.SourceMatch, at: TimeInterval)?
    /// Bound: about 72 days of data in total (for example 28 + 7 + 1 for two dates).
    static let snapshotDayLimit = 72
    private var invalidation: AnyCancellable?

    init() { reader = .shared; observeChanges() }

    /// Called by the existing 10-minute analysis timer: no wake-up of its own.
    nonisolated static func advanceToday() {
        Task.detached(priority: .utility) { await GoalongAnalyticsReader.shared.advanceToday() }
    }
    init(root: URL) { reader = GoalongAnalyticsReader(root: root); observeChanges() }
    init(reader: GoalongAnalyticsReader) { self.reader = reader; observeChanges() }

    private func observeChanges() {
        let names: [Notification.Name] = [.goalongWorkVerdictsDidChange, .goalongRecordingChoicesDidChange,
            .goalongGlobalPauseDidChange, .goalongRetentionPolicyDidChange, .goalongProfileAnalysisDidSave,
            .goalongExclusionsDidChange, .goalongAnalysisSelectionDidChange, .NSCalendarDayChanged,
            .NSSystemTimeZoneDidChange]
        invalidation = Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
            // The system posts the day and time-zone notifications on its own thread: hop to main first.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetSnapshots() } }
    }

    /// Empties every stored period. Called on any change of data or classification, and before a forced read.
    /// A read or a preload in flight keeps the generation it started with: its result is dropped if this moved.
    func forgetSnapshots() { snapshots.removeAll(); recentMatch = nil; snapshotGeneration += 1 }

    private static func snapshotKey(day: Date, count: Int, calendar: Calendar = .current) -> String {
        "\(calendar.startOfDay(for: day).timeIntervalSinceReferenceDate)|\(count)"
    }

    /// R14a: selections of Activité waiting for their stored read's file check, off the main thread. The view-switch
    /// timing waits for 0 before it times the frame that shows the new period.
    static var selectionsPending = 0

    /// True when a complete read of this period is stored: the page then checks it before it shows the new period.
    func hasSnapshot(day: Date, count: Int) -> Bool { snapshots[Self.snapshotKey(day: day, count: count)] != nil }

    /// Puts the last complete read of this period on screen, if it still describes the sources.
    /// Returns false (and drops the entry) otherwise; the normal read then runs.
    @discardableResult
    func showSnapshot(day: Date, count: Int, verdicts: GoalongWorkVerdicts) async -> Bool {
        let match = await verifySnapshot(day: day, count: count, verdicts: verdicts)
        return showVerified(day: day, count: count, match: match)
    }

    /// R14a: checks the stored read of this period against its files on a background thread (a few hundred `stat`
    /// for 28 days). The result holds only for this generation and this entry: any change since gives `.changed`.
    func verifySnapshot(day: Date, count: Int, verdicts: GoalongWorkVerdicts) async -> GoalongAnalyticsReader.SourceMatch {
        let key = Self.snapshotKey(day: day, count: count)
        guard let stored = snapshots[key] else { return .changed }
        let now = reader.now()
        guard stored.verdicts == verdicts,
              Calendar.current.isDate(stored.payload.updatedAt, inSameDayAs: now),
              DerivedHistoryWriteBarrier.shared.isCurrent(stored.admission),
              let sources = stored.payload.sources
        else { snapshots[key] = nil; return .changed }
        // The click shows the snapshot, then the page's read asks again a few ms later: one file check for both.
        var match: GoalongAnalyticsReader.SourceMatch
        if let recent = recentMatch, recent.key == key, recent.updatedAt == stored.payload.updatedAt,
           ProcessInfo.processInfo.systemUptime - recent.at < 0.5 {
            match = recent.match
        } else {
            let generation = snapshotGeneration, root = reader.root
            Self.loadsInFlight += 1
            match = await Task.detached(priority: .userInitiated) {
                GoalongAnalyticsReader.match(sources, root: root, now: now, calendar: .current)
            }.value
            Self.loadsInFlight -= 1
            // Emptied, replaced or cleared during the check: never shown.
            guard generation == snapshotGeneration, snapshots[key]?.payload.updatedAt == stored.payload.updatedAt,
                  DerivedHistoryWriteBarrier.shared.isCurrent(stored.admission) else { return .changed }
            recentMatch = (key, stored.payload.updatedAt, match, ProcessInfo.processInfo.systemUptime)
        }
        guard match != .changed else { snapshots[key] = nil; return .changed }
        // Today's figures also follow the clock (the day so far): past one minute, shown and then read again.
        let start = Calendar.current.date(byAdding: .day, value: 1 - count, to: Calendar.current.startOfDay(for: day)) ?? day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day)) ?? day
        if match == .same, start <= now, now < end, now.throttleElapsed(since: stored.payload.updatedAt) > 60 { match = .grown }
        return match
    }

    /// Shows the stored read checked by `verifySnapshot` (same main-actor turn as the new selection: one layout).
    @discardableResult
    func showVerified(day: Date, count: Int, match: GoalongAnalyticsReader.SourceMatch) -> Bool {
        let key = Self.snapshotKey(day: day, count: count)
        guard match != .changed, let stored = snapshots[key] else { return false }
        snapshotUses += 1; snapshots[key]?.use = snapshotUses
        let shown = payload.map { value in
            value.updatedAt == stored.payload.updatedAt && value.current.days.count == count && !value.isPreview
                && value.current.days.last.map { Calendar.current.isDate($0.date, inSameDayAs: day) } == true
        } ?? false
        if !shown {
            payload = stored.payload
        }
        // R14a: a @Published set publishes even with the same value; the shown page is laid out only on a change.
        if error != nil { error = nil }
        if paused { paused = false }
        return true
    }

    func storeSnapshot(_ value: GoalongAnalyticsPayload, day: Date, count: Int, verdicts: GoalongWorkVerdicts,
                       admission: DerivedHistoryWriteBarrier.Admission?, generation: Int) {
        guard generation == snapshotGeneration, let admission, value.sources != nil, !value.isPreview,
              !value.comparisonPending,
              DerivedHistoryWriteBarrier.shared.isCurrent(admission) else { return }
        snapshotUses += 1
        snapshots[Self.snapshotKey(day: day, count: count)] =
            Snapshot(payload: value, verdicts: verdicts, admission: admission, use: snapshotUses)
        while snapshots.values.reduce(0, { $0 + $1.payload.current.days.count }) > Self.snapshotDayLimit,
              let oldest = snapshots.min(by: { $0.value.use < $1.value.use })?.key {
            snapshots[oldest] = nil
        }
    }

    /// After the first display: reads the other periods of the same day in the background, so that the first
    /// switch to them is shown from memory too. Not counted as a page read; stops with the calling task.
    func preloadOtherPeriods(day: Date, count: Int, verdicts: GoalongWorkVerdicts, counts: [Int] = [1, 7, 28]) async {
        for other in counts where other != count {
            guard !Task.isCancelled else { return }
            guard snapshots[Self.snapshotKey(day: day, count: other)] == nil else { continue }
            let admission = DerivedHistoryWriteBarrier.shared.admission()
            let generation = snapshotGeneration
            do {
                var value = try await reader.read(ending: day, count: other, force: false, preview: false, verdicts: verdicts)
                if value.comparisonPending { value = try await reader.comparison(for: value, verdicts: verdicts) }
                try Task.checkCancellation()
                storeSnapshot(value, day: day, count: other, verdicts: verdicts, admission: admission, generation: generation)
            } catch { return }
        }
    }

    /// Oldest day imported from Temps d’écran or Santé (R-265), listed in the reader's own folder (R272b-2):
    /// the gallery and the tests never list the real data folder.
    @Published private(set) var importedFirstDay: Date?

    /// Lists the imported days off the main thread. Called when a revision may have added one (import, refresh).
    func refreshImportedFirstDay(calendar: Calendar = .current) async {
        let root = reader.root
        let value = await Task.detached(priority: .utility) {
            GoalongActivityFirstDay.importedEarliest(root: root, calendar: calendar)
        }.value
        guard !Task.isCancelled else { return }
        if importedFirstDay != value { importedFirstDay = value }
    }

    /// R-265, UI-17A M3: the one bound of Activité (calendar, « précédent », every period's step). Nil in the preview.
    func earliestDay(macDays: [Date], preview: Bool, calendar: Calendar = .current) -> Date? {
        preview ? nil : GoalongActivityFirstDay.earliest(macDays: macDays, imported: importedFirstDay, calendar: calendar)
    }

    /// « Précédent » / « suivant » of the page: the step always stops at `earliestDay` (R272b-1).
    func step(_ navigation: inout GoalongActivityNavigation, _ direction: Int, macDays: [Date], preview: Bool,
              now: Date = GoalongToday.now, calendar: Calendar = .current) {
        navigation.step(direction, earliest: earliestDay(macDays: macDays, preview: preview, calendar: calendar),
                        now: now, calendar: calendar)
    }
    func load(_ request: GoalongAnalyticsLoadRequest, force: Bool = false,
              verdicts: GoalongWorkVerdicts = GoalongWorkVerdicts()) async {
        guard request.permitsLoading, !Task.isCancelled else { return }
        await load(day: request.day, count: request.count, force: force, preview: request.isPreview, verdicts: verdicts)
    }

    func load(day: Date, count: Int, force: Bool = false, preview: Bool = false,
              verdicts: GoalongWorkVerdicts = GoalongWorkVerdicts()) async {
        // R14a: nothing is published before something changes. A check of unchanged sources (the 30 s reread)
        // neither shows the progress mark nor lays out the page; `busy` rises only when a read really starts.
        let id = UUID(); operation = id
        if error != nil { error = nil }
        if paused { paused = false }
        Self.loadsInFlight += 1; Self.loadsStarted += 1
        defer { Self.loadsInFlight -= 1 }
        if force { forgetSnapshots() }
        let admission = DerivedHistoryWriteBarrier.shared.admission()
        let generation = snapshotGeneration
        func sameSelection() -> Bool {
            payload.map {
                $0.isPreview == preview && $0.current.days.count == count
                    && $0.current.days.last.map { Calendar.current.isDate($0.date, inSameDayAs: day) } == true
            } ?? false
        }
        // Keep a valid same-period snapshot during refresh, never across dates or preview boundaries.
        if !force, !preview {
            let match = await verifySnapshot(day: day, count: count, verdicts: verdicts)
            guard operation == id, !Task.isCancelled else { if operation == id, busy { busy = false }; return }
            if showVerified(day: day, count: count, match: match), match == .same {
                // Every source is as read: a new read gives the same payload. Nothing to read again.
                if busy { busy = false }
                return
            }
        }
        if !busy { busy = true }
        if payload != nil, !sameSelection() { payload = nil }
        do {
            let value = try await reader.read(ending: day, count: count, force: force, preview: preview, verdicts: verdicts)
            try Task.checkCancellation()
            guard operation == id else { return }
            payload = value
            if value.comparisonPending {
                let compared = try await reader.comparison(for: value, verdicts: verdicts)
                try Task.checkCancellation()
                guard operation == id else { return }
                payload = compared
            }
            if !preview, let payload { storeSnapshot(payload, day: day, count: count, verdicts: verdicts, admission: admission, generation: generation) }
            busy = false
        } catch is CancellationError {
            if operation == id { busy = false }
        } catch GoalongGlobalPause.PauseError.active, GoalongGlobalPause.PauseError.unreadable {
            guard operation == id else { return }
            paused = true
            busy = false
        } catch {
            guard operation == id else { return }
            self.error = payload == nil
                ? "Impossible de lire cette période. Réessayez ; vos enregistrements n’ont pas été modifiés."
                : "Actualisation impossible. Les derniers chiffres lus restent affichés avec leur heure de mise à jour. Réessayez."
            busy = false
        }
    }
}
#endif
