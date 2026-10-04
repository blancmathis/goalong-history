#if os(macOS)
import Foundation

/// The member's own lists. Never filled by the work agent, Jev or analytics (docs/BLOCKING.md).
struct BlockList: Codable, Identifiable, Equatable, Hashable {
    enum Mode: String, Codable, CaseIterable { case block, allowOnly }

    var id: UUID
    var name: String
    var mode: Mode
    var sites: [BlockSiteRule]
    var apps: [BlockAppRule]
    var program: BlockProgram
    /// Minutes the list allows per local day while it is active, before it blocks.
    var quotaMinutesPerDay: Int?
    var breaks: BlockBreaks?
    enum Action: String, Codable { case block, slowDown }
    var action: Action?
    var slowDownSeconds: Int?
    var continueMinutes: Int?
    var effectiveAction: Action { action ?? .block }
    var delaySeconds: Int { slowDownSeconds ?? 10 }
    var allowanceMinutes: Int { continueMinutes ?? 10 }

    init(id: UUID = UUID(), name: String, mode: Mode = .block, sites: [BlockSiteRule] = [],
         apps: [BlockAppRule] = [], program: BlockProgram = BlockProgram(),
         quotaMinutesPerDay: Int? = nil, breaks: BlockBreaks? = nil, action: Action? = nil,
         slowDownSeconds: Int? = nil, continueMinutes: Int? = nil) {
        self.id = id; self.name = name; self.mode = mode; self.sites = sites; self.apps = apps
        self.program = program; self.quotaMinutesPerDay = quotaMinutesPerDay; self.breaks = breaks
        self.action = action; self.slowDownSeconds = slowDownSeconds; self.continueMinutes = continueMinutes
    }

    var isEmpty: Bool { sites.isEmpty && apps.isEmpty && mode == .block }
}

/// A normalized `host[/path]`. A host matches itself and every subdomain; a path matches on a
/// segment boundary.
struct BlockSiteRule: Codable, Hashable, Identifiable {
    var pattern: String
    var id: String { pattern }
    var host: String { pattern.split(separator: "/", maxSplits: 1).first.map(String.init) ?? pattern }
}

struct BlockAppRule: Codable, Hashable, Identifiable {
    var bundleIdentifier: String
    var name: String
    var id: String { bundleIdentifier }
}

struct BlockProgram: Codable, Hashable {
    var ranges: [BlockProgramRange] = []
    /// While in the future, the list and its program can only get stricter.
    var lockedUntil: Date?

    func isLocked(at now: Date) -> Bool { lockedUntil.map { $0 > now } ?? false }
}

struct BlockProgramRange: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// ISO weekdays: 1 = Monday … 7 = Sunday.
    var weekdays: Set<Int>
    /// Minutes since local midnight, 0…1440. `end <= start` ends the next day.
    var startMinute: Int
    var endMinute: Int

    var crossesMidnight: Bool { endMinute <= startMinute }
    var durationMinutes: Int { crossesMidnight ? 1_440 - startMinute + endMinute : endMinute - startMinute }
}

struct BlockBreaks: Codable, Hashable {
    var count: Int
    var minutes: Int
}

enum BlockLock: String, Codable, CaseIterable {
    /// « Libre »: Arrêter ends it.
    case free
    /// « Difficile »: retype a random text to stop.
    case typing
    /// « Verrouillé »: cannot be stopped before its end.
    case locked
}

struct BlockSession: Codable, Identifiable, Hashable {
    enum Origin: Codable, Hashable { case manual, program(UUID), commitment(UUID) }
    var id: UUID = UUID()
    var listIDs: [UUID]
    var start: Date
    var end: Date
    var lock: BlockLock
    var origin: Origin = .manual
}

struct BlockDayUsage: Codable, Hashable {
    /// Local day, `yyyy-MM-dd`.
    var day: String
    var quotaSecondsUsed: [UUID: Double] = [:]
    var breaksTaken: [UUID: Int] = [:]
    var breakEnds: [UUID: Date] = [:]
    var slowDownShown: [UUID: Int]?
    var renounced: [UUID: Int]?
    var continued: [UUID: Int]?
}

struct BlockFreeze: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable { case shield, lockScreen }
    var start: Date
    var end: Date
    var mode: Mode
    var allowedApps: [BlockAppRule] = []
}

struct BlockingDocument: Codable, Equatable {
    static let currentVersion = 1
    var version = BlockingDocument.currentVersion
    var lists: [BlockList] = []
    var sessions: [BlockSession] = []
    var usage: BlockDayUsage?
    var freeze: BlockFreeze?
    var clock: BlockingClockState?
    var programSkips: [UUID: Date]?
    var heldPrograms: [BlockSession]?
    var usageHistory: [String: BlockDayUsage]?
}

/// One thing blocking right now, as the page shows it: a manual session or a program window.
struct BlockingActiveBlock: Identifiable, Hashable {
    var id: UUID
    var listIDs: [UUID]
    var start: Date
    var end: Date
    var lock: BlockLock
    var origin: BlockSession.Origin
    /// Per list: breaks left today, current break end, quota seconds left today.
    var breaksLeft: [UUID: Int] = [:]
    var breakEnds: [UUID: Date] = [:]
    var quotaSecondsLeft: [UUID: Double] = [:]
}

struct BlockingBrowserSupport: Identifiable, Hashable {
    var bundleIdentifier: String
    var name: String
    var supported: Bool
    var id: String { bundleIdentifier }
}

enum BlockingProtectionLevel: String, Codable, CaseIterable { case standard, strict }

struct BlockingProtectionState: Hashable {
    enum Component: Hashable { case notInstalled, awaitingApproval, running, failed(String) }
    var level: BlockingProtectionLevel = .standard
    var component: Component = .notInstalled
    var launchAtLogin = false
}

struct BlockingFrictionPresentation: Equatable {
    var listID: UUID
    var key: String
    var name: String
    var shownAt: Date
    var readyAt: Date
    var occurrence: Int
    static func key(_ target: BlockingObservation, listID: UUID) -> String {
        let destination = target.isBrowser ? "host:" + (BlockingRules.normalize(target.url ?? "")?.split(separator: "/").first.map(String.init) ?? "") : "app:" + target.bundleIdentifier
        return listID.uuidString + "|" + destination
    }
}

enum BlockingEditCheck: Equatable {
    case allowed
    case refused(String)
}

/// A fixed catalog the member taps to add. Never computed from history or the work agent.
struct BlockSuggestion: Identifiable, Hashable {
    var id: String
    var title: String
    var symbol: String
    var sites: [String]
    var apps: [BlockAppRule] = []

    static let catalog: [BlockSuggestion] = [
        BlockSuggestion(id: "social", title: "Réseaux sociaux", symbol: "person.2",
                        sites: ["x.com", "instagram.com", "facebook.com", "tiktok.com", "linkedin.com",
                                "threads.net", "bsky.app", "snapchat.com"]),
        BlockSuggestion(id: "video", title: "Vidéo", symbol: "play.rectangle",
                        sites: ["youtube.com", "netflix.com", "twitch.tv", "primevideo.com",
                                "disneyplus.com", "canalplus.com", "dailymotion.com"]),
        BlockSuggestion(id: "news", title: "Actualités", symbol: "newspaper",
                        sites: ["lemonde.fr", "lefigaro.fr", "bfmtv.com", "liberation.fr",
                                "francetvinfo.fr", "20minutes.fr", "news.google.com"]),
        BlockSuggestion(id: "forums", title: "Forums", symbol: "bubble.left.and.bubble.right",
                        sites: ["reddit.com", "news.ycombinator.com", "jeuxvideo.com", "9gag.com"]),
        BlockSuggestion(id: "shopping", title: "Achats", symbol: "bag",
                        sites: ["amazon.fr", "amazon.com", "leboncoin.fr", "vinted.fr", "aliexpress.com",
                                "temu.com", "zalando.fr"]),
        BlockSuggestion(id: "messages", title: "Messageries", symbol: "message",
                        sites: ["web.whatsapp.com", "messenger.com", "discord.com", "web.telegram.org"],
                        apps: [BlockAppRule(bundleIdentifier: "net.whatsapp.WhatsApp", name: "WhatsApp"),
                               BlockAppRule(bundleIdentifier: "com.hnc.Discord", name: "Discord"),
                               BlockAppRule(bundleIdentifier: "ru.keepcoder.Telegram", name: "Telegram"),
                               BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")]),
    ]
}
#endif
