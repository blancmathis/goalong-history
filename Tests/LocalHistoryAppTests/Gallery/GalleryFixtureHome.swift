#if os(macOS)
import Foundation
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Data written under the shard's throwaway HOME before an entry renders (spec C §5.7). Events go through the
/// domain's `HistoryEvent` encoder, consent through `GoalongCapabilityConsentStore`: a schema change breaks the
/// build or still reads. Invented apps and sites only; no real name, mail or text.
@MainActor enum GalleryFixtureHome {
    enum Kind: Equatable {
        /// Nothing written: recording off, no day.
        case empty
        /// Recording on, 28 days of work ending on the gallery morning (08:12-09:40).
        case realistic
        /// Recording on, three isolated traces this morning.
        case sparse
        /// Recording on, no event yet.
        case recordingOn
    }

    static func install(_ kind: Kind) throws {
        guard kind != .empty else { return }
        enableRecording()
        // A running recorder has its journal folder even before the first event; without it Activité reports
        // « Lecture incomplète » (source folder absent) instead of an empty day.
        try FileManager.default.createDirectory(at: AppPaths.eventsDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        switch kind {
        case .empty, .recordingOn: return
        case .sparse: try write(sparseDay(), day: GalleryClock.today)
        case .realistic:
            for offset in 0..<28 {
                let day = GalleryClock.calendar.date(byAdding: .day, value: -offset, to: GalleryClock.today)!
                let events = workDay(day, offset: offset)
                if !events.isEmpty { try write(events, day: day) }
            }
        }
    }

    /// Goalong's own consent for this Mac's history; the shared store reads the file again.
    static func enableRecording() {
        let store = GoalongCapabilityConsentStore.shared
        store.reload()
        store.set(.localComputerHistory, enabled: true, surface: .settings)
    }

    /// « Tout suspendre » on, written like `GoalongGlobalPause.setPaused` but with a fixed revision and time.
    static func writeGlobalPause() throws {
        var pause = GoalongGlobalPause()
        pause.paused = true
        pause.revision = "galerie"
        pause.changedAt = GalleryClock.at(9, 5)
        let root = GoalongGlobalPause.defaultRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = GoalongGlobalPause.file(in: root)
        try JSONEncoder().encode(pause).write(to: url, options: .atomic)
        guard GoalongGlobalPause.load(in: root).paused else { throw GalleryError.fixture("global-pause.json not read back") }
    }

    // MARK: Days

    private struct Activity {
        let app: String, bundle: String, host: String?, title: String, category: String?, isWork: Bool?
    }

    private static let work: [Activity] = [
        Activity(app: "Xcode", bundle: "com.apple.dt.Xcode", host: nil, title: "Atlas — PlanningView.swift",
                 category: "Développement", isWork: true),
        Activity(app: "Safari", bundle: "com.apple.Safari", host: "github.com", title: "atlas/app · Pull requests",
                 category: "Développement", isWork: true),
        Activity(app: "Terminal", bundle: "com.apple.Terminal", host: nil, title: "atlas — zsh", category: "Développement",
                 isWork: true),
        Activity(app: "Safari", bundle: "com.apple.Safari", host: "exemple.fr", title: "Exemple — Documentation",
                 category: "Recherche", isWork: true),
        Activity(app: "Notes", bundle: "com.apple.Notes", host: nil, title: "Plan de lancement", category: "Écriture",
                 isWork: true),
        Activity(app: "Mail", bundle: "com.apple.mail", host: nil, title: "Boîte de réception", category: "Communication",
                 isWork: true),
    ]
    private static let breaks: [Activity] = [
        Activity(app: "Messages", bundle: "com.apple.MobileSMS", host: nil, title: "Messages", category: "Communication",
                 isWork: false),
        Activity(app: "Safari", bundle: "com.apple.Safari", host: "youtube.com", title: "YouTube", category: "Divertissement",
                 isWork: false),
    ]

    /// Minutes of the day with activity: two work blocks, shorter on weekends, this morning up to 09:40.
    private static func blocks(_ day: Date, offset: Int) -> [(Int, Int)] {
        if offset == 0 { return [(8 * 60 + 12, 9 * 60 + 40)] }
        let weekday = GalleryClock.calendar.component(.weekday, from: day)
        if weekday == 1 { return offset % 2 == 0 ? [] : [(16 * 60, 16 * 60 + 35)] }
        if weekday == 7 { return [(10 * 60 + 5, 11 * 60 + 20)] }
        let shift = (offset * 7) % 25
        return [(8 * 60 + 40 + shift, 12 * 60 + 15 + shift / 2), (13 * 60 + 50, 17 * 60 + 30 + (offset * 11) % 70)]
    }

    private static func workDay(_ day: Date, offset: Int) -> [HistoryEvent] {
        var events: [HistoryEvent] = []
        for (start, end) in blocks(day, offset: offset) {
            var previous: String?
            for minute in start..<end {
                // A 50-minute cycle: 40 minutes of rotating work, 10 minutes away from it.
                let phase = (minute - start) % 50
                let activity = phase < 40 ? work[((minute - start) / 8 + offset) % work.count]
                    : breaks[((minute - start) / 50 + offset) % breaks.count]
                let timestamp = day.addingTimeInterval(Double(minute * 60))
                let key = activity.bundle + (activity.host ?? "")
                let id = "galerie-\(offset)-\(minute)"
                let app = AppSnapshot(name: activity.app, bundleIdentifier: activity.bundle, processIdentifier: 400)
                let url = activity.host.map { URLSnapshot(value: "https://\($0)/", host: $0, redactionApplied: false) }
                let window = WindowSnapshot(title: activity.title, role: "AXWindow", subrole: "AXStandardWindow")
                // The recorder's own label; Activité still shows « à classer » until the member defines their work.
                let classification = activity.category.map {
                    LocalClassification(category: $0, isWork: activity.isWork, confidence: 0.9, classifierVersion: "galerie")
                }
                if key != previous {
                    events.append(HistoryEvent(id: id + "-a", sessionID: "galerie", timestamp: timestamp,
                                               kind: .applicationActivated, app: app, window: window, url: url,
                                               classification: classification))
                    previous = key
                }
                events.append(HistoryEvent(id: id, sessionID: "galerie", timestamp: timestamp.addingTimeInterval(30),
                                           kind: .heartbeat, app: app, window: window, url: url,
                                           classification: classification))
            }
        }
        return events
    }

    private static func sparseDay() -> [HistoryEvent] {
        [(8, 3), (8, 47), (9, 12)].map { hour, minute in
            HistoryEvent(id: "galerie-trace-\(hour)-\(minute)", sessionID: "galerie", timestamp: GalleryClock.at(hour, minute),
                         kind: .heartbeat,
                         app: AppSnapshot(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 400))
        }
    }

    // MARK: Journal

    private static func key(_ day: Date) -> String {
        let parts = GalleryClock.calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// One journal per day, then read back with the domain decoder: an empty or unreadable fixture fails the entry.
    private static func write(_ events: [HistoryEvent], day: Date) throws {
        let directory = AppPaths.eventsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var bytes = Data()
        for event in events {
            bytes.append(try encoder.encode(event))
            bytes.append(0x0A)
        }
        let url = directory.appendingPathComponent("\(key(day)).jsonl")
        try bytes.write(to: url, options: .atomic)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try decoder.decode(HistoryEvent.self, from: Data($0.utf8)) }
        guard read.count == events.count, read.count > 0 else {
            throw GalleryError.fixture("\(url.lastPathComponent): \(read.count) of \(events.count) events read back")
        }
    }
}
#endif
