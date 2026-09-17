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
}

/// Lives off the main actor. Stores only bounded derived measurements, never source events.
private actor GoalongAnalyticsReader {
    private var cache: [Date: (String, GoalongLocalAnalytics.Day)] = [:]
    private let root: URL
    init(root: URL) { self.root = root }

    func read(ending day: Date, count: Int, force: Bool) throws -> GoalongAnalyticsPayload {
        let calendar = Calendar.current, now = Date()
        let count = [1, 7, 28].contains(count) ? count : 7
        let last = calendar.startOfDay(for: day)
        var days: [GoalongLocalAnalytics.Day] = []
        if force { cache.removeAll() }
        // A day-at-a-time source pass bounds memory, including when viewing 28 days.
        for offset in (0..<(count * 2)).reversed() {
            try Task.checkCancellation()
            guard let date = calendar.date(byAdding: .day, value: -offset, to: last) else { continue }
            let revision = sourceRevision(date, calendar: calendar)
            let value: GoalongLocalAnalytics.Day
            if !calendar.isDate(date, inSameDayAs: now), let cached = cache[date], cached.0 == revision {
                value = cached.1
            } else {
                value = GoalongLocalAnalytics.load(root: root, day: date, now: now, calendar: calendar,
                    shouldContinue: { !Task.isCancelled })
                try Task.checkCancellation()
                if value.state != .incomplete { cache[date] = (revision, value) }
            }
            days.append(value)
        }
        cache = cache.filter { key, _ in days.contains { $0.date == key } }
        let current = Array(days.suffix(count)), previous = Array(days.prefix(count))
        let saved = try readCards(start: current.first?.date ?? last, end: current.last?.end ?? now)
        return GoalongAnalyticsPayload(current: .init(days: current), previous: .init(days: previous),
            cards: saved.0, archiveNotice: saved.1, updatedAt: now)
    }
    private func sourceRevision(_ day: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        // Neighboring files can intersect a local day after a timezone change.
        return (-1...1).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: day) ?? day
            let url = root.appendingPathComponent("events/" + formatter.string(from: date) + ".jsonl")
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
            return "\(a[.systemFileNumber] ?? "-")|\(a[.size] ?? "-")|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";") + calendar.timeZone.identifier
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
                // Latest saved analysis per day/module; don't duplicate earlier versions.
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
    init(root: URL = AppPaths.applicationSupportDirectory) { reader = GoalongAnalyticsReader(root: root) }
    func load(day: Date, count: Int, force: Bool = false) async {
        let id = UUID(); operation = id; busy = true; error = nil
        payload = nil // A previous day's metrics must never appear under a new date.
        do {
            let value = try await reader.read(ending: day, count: count, force: force)
            try Task.checkCancellation()
            guard operation == id else { return }
            payload = value; busy = false
        } catch is CancellationError {
            if operation == id { busy = false }
        } catch {
            guard operation == id else { return }
            self.error = "Impossible de lire cette période. Réessayez ; vos enregistrements n’ont pas été modifiés."
            busy = false
        }
    }
}
#endif
