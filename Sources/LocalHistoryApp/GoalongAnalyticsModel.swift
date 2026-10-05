#if os(macOS)
import Foundation
import Combine
import LocalHistoryCore

enum GoalongAnalyticsFormatting {
    /// A missing/zero measurement must never acquire a minute through presentation rounding.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds == 0 { return "0 min" }
        if seconds < 60 { return "< 1 min" }
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
        value.formatted(.number.locale(Locale(identifier: "fr_FR")).precision(.fractionLength(0...1))) + " " + unit
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
struct GoalongAnalyticsPayload: Sendable {
    let current: GoalongLocalAnalytics.Period
    let previous: GoalongLocalAnalytics.Period
    let cards: [GoalongAnalyticsCard]
    let archiveNotice: String?
    let updatedAt: Date
    let isPreview: Bool
    /// The selected period is shown first; its comparison (an empty `previous`) follows.
    let comparisonPending: Bool

    init(current: GoalongLocalAnalytics.Period, previous: GoalongLocalAnalytics.Period,
         cards: [GoalongAnalyticsCard], archiveNotice: String?, updatedAt: Date, isPreview: Bool = false,
         comparisonPending: Bool = false) {
        self.current = current; self.previous = previous; self.cards = cards
        self.archiveNotice = archiveNotice; self.updatedAt = updatedAt; self.isPreview = isPreview
        self.comparisonPending = comparisonPending
    }

    func with(previous: GoalongLocalAnalytics.Period) -> Self {
        Self(current: current, previous: previous, cards: cards, archiveNotice: archiveNotice,
             updatedAt: updatedAt, isPreview: isPreview)
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
    /// Today's journal is read once, then only the lines appended since. The checkpoint
    /// holds derived segments and the last 15 minutes of rows (about 2 MB on a busy day).
    private var today: (date: Date, revision: String, state: GoalongLocalAnalytics.ResumableDayState)?
    private(set) var todayCheckpointBytesHashed: Int64 = 0
    private(set) var todayEventBytesRead: Int64 = 0
    private let root: URL
    init(root: URL) { self.root = root }

    /// Focus reuses the same validated day cache and bounded current-day fold, without
    /// loading recap cards, starting analysis or changing the Activity selection.
    func focusDay(_ day: Date, verdicts: GoalongWorkVerdicts) throws -> GoalongLocalAnalytics.Day {
        try Task.checkCancellation()
        let value = try days(ending: Calendar.current.startOfDay(for: day), count: 1, now: Date(), calendar: .current)[0]
        return value.applying(verdicts)
    }

    func read(ending day: Date, count: Int, force: Bool, preview: Bool,
              verdicts: GoalongWorkVerdicts = GoalongWorkVerdicts()) throws -> GoalongAnalyticsPayload {
        try Task.checkCancellation()
        // Preview exits before looking at caches, journals, daily reports or project archives.
        if preview { return GoalongAnalyticsPreview.make(ending: day, count: count) }
        _ = try GoalongGlobalPause.admit(in: root)
        let calendar = Calendar.current, now = Date()
        let count = [1, 7, 28].contains(count) ? count : 7
        let last = calendar.startOfDay(for: day)
        if force { cache.removeAll(); lastUse.removeAll(); today = nil }
        let current = try days(ending: last, count: count, now: now, calendar: calendar)
        let previousLast = calendar.date(byAdding: .day, value: -count, to: last) ?? last
        // A comparison that needs a journal read waits for `comparison(for:)`: the selected
        // period goes on screen first.
        let previous = cachedDays(ending: previousLast, count: count, now: now, calendar: calendar)
        let saved = try readCards(start: current.first?.date ?? last, end: current.last?.end ?? now)
        let recaps = try readDailyRecaps(days: current, calendar: calendar)
        let cards = (saved.0 + recaps.0).sorted { a, b in a.day == b.day ? a.id < b.id : a.day > b.day }
        let notices = [saved.1, recaps.1].compactMap { $0 }
        // The cache keeps raw days; the verdicts of the user's work definition are applied on
        // every read, so a new verdict or correction never requires reading the journals again.
        return GoalongAnalyticsPayload(current: GoalongLocalAnalytics.Period(days: current).applying(verdicts),
            previous: GoalongLocalAnalytics.Period(days: previous ?? []).applying(verdicts),
            cards: cards, archiveNotice: notices.isEmpty ? nil : notices.joined(separator: " "), updatedAt: now,
            comparisonPending: previous == nil)
    }

    /// Reads the previous period of the same length, after the selected one is on screen.
    func comparison(for payload: GoalongAnalyticsPayload, verdicts: GoalongWorkVerdicts) throws -> GoalongAnalyticsPayload {
        let calendar = Calendar.current
        guard payload.comparisonPending, let first = payload.current.days.first,
              let previousLast = calendar.date(byAdding: .day, value: -1, to: first.date) else { return payload }
        let previous = try days(ending: previousLast, count: payload.current.days.count,
            now: payload.updatedAt, calendar: calendar)
        return payload.with(previous: GoalongLocalAnalytics.Period(days: previous).applying(verdicts))
    }

    private func days(ending last: Date, count: Int, now: Date, calendar: Calendar) throws -> [GoalongLocalAnalytics.Day] {
        let pause = try GoalongGlobalPause.admit(in: root)
        let barrier = DerivedHistoryWriteBarrier.shared
        guard let permit = barrier.beginJob() else { throw CancellationError() }
        defer { barrier.endJob(permit) }
        var days: [GoalongLocalAnalytics.Day] = []
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
            days.append(value)
            uses += 1
            if cache[date] != nil { lastUse[date] = uses }
        }
        try GoalongGlobalPause.revalidate(pause, in: root)
        guard barrier.isCurrent(permit) else { throw CancellationError() }
        if cache.count > Self.maximumCachedDays {
            let evicted = cache.keys.sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }.prefix(cache.count - Self.maximumCachedDays)
            for date in evicted { cache[date] = nil; lastUse[date] = nil }
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

    private static func canResumeInMemory(from previous: String, to current: String) -> Bool {
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
        let now = Date()
        _ = try? readToday(calendar.startOfDay(for: now), now: now, calendar: calendar)
    }

    /// The period's days when none needs a journal read, nil otherwise.
    private func cachedDays(ending last: Date, count: Int, now: Date, calendar: Calendar) -> [GoalongLocalAnalytics.Day]? {
        var days: [GoalongLocalAnalytics.Day] = []
        for offset in (0..<count).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: last),
                  !calendar.isDate(date, inSameDayAs: now), let cached = cache[date],
                  cached.0 == sourceRevision(date, calendar: calendar) else { return nil }
            days.append(cached.1)
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
        return (cards, rejected > 0 ? "\(rejected) bilan(s) quotidien(s) illisible(s) ou incohérent(s) ne sont pas affichés." : nil)
    }

    private func sourceRevision(_ day: Date, calendar: Calendar) -> String {
        GoalongActivityDayReader.sourceRevision(root: root, day: day, calendar: calendar)
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
        let notice = (visited > 512 || files.count > 64 || rejected > 0)
            ? "Lecture limitée aux 64 dossiers récents valides. Certains dossiers anciens ou illisibles ne sont pas affichés." : nil
        return (cards, notice)
    }
}

@MainActor final class GoalongAnalyticsModel: ObservableObject {
    @Published private(set) var payload: GoalongAnalyticsPayload?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let reader: GoalongAnalyticsReader
    private var operation = UUID()
    init() { reader = .shared }

    /// Called by the existing 10-minute analysis timer: no wake-up of its own.
    nonisolated static func advanceToday() {
        Task.detached(priority: .utility) { await GoalongAnalyticsReader.shared.advanceToday() }
    }
    init(root: URL) { reader = GoalongAnalyticsReader(root: root) }
    func load(_ request: GoalongAnalyticsLoadRequest, force: Bool = false,
              verdicts: GoalongWorkVerdicts = GoalongWorkVerdicts()) async {
        guard request.permitsLoading, !Task.isCancelled else { return }
        await load(day: request.day, count: request.count, force: force, preview: request.isPreview, verdicts: verdicts)
    }

    func load(day: Date, count: Int, force: Bool = false, preview: Bool = false,
              verdicts: GoalongWorkVerdicts = GoalongWorkVerdicts()) async {
        let id = UUID(); operation = id; busy = true; error = nil
        let sameSelection = payload.map {
            $0.isPreview == preview && $0.current.days.count == count
                && $0.current.days.last.map { Calendar.current.isDate($0.date, inSameDayAs: day) } == true
        } ?? false
        // Keep a valid same-period snapshot during refresh, never across dates or preview boundaries.
        if !sameSelection { payload = nil }
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
            busy = false
        } catch is CancellationError {
            if operation == id { busy = false }
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
