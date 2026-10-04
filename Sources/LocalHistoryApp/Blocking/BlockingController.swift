#if os(macOS)
import AppKit
import Combine
import Foundation

/// Owns the module while it is on. Created by `BlockingRuntime` only when
/// `goalong.module.blocking.enabled` is true; destroyed when it is turned off.
/// Contract for the page: docs/BLOCKING.md « API for the UI ».
@MainActor final class BlockingController: ObservableObject {
    @Published private(set) var lists: [BlockList]
    @Published private(set) var activeBlocks: [BlockingActiveBlock] = []
    @Published private(set) var freeze: BlockFreeze?
    @Published private(set) var nextProgramStart: (listID: UUID, date: Date)?
    @Published private(set) var siteBlockingAvailable = true
    @Published private(set) var browsers: [BlockingBrowserSupport] = []
    @Published private(set) var protection = BlockingProtectionState()
    @Published var error: String?

    private var document: BlockingDocument
    private let clock: () -> Date

    init(document: BlockingDocument = BlockingDocument(), clock: @escaping () -> Date = Date.init) {
        self.document = document
        self.lists = document.lists
        self.freeze = document.freeze
        self.clock = clock
        refresh()
    }

    /// Anything the member committed to and cannot undo before its end.
    var hasLocks: Bool {
        let now = clock()
        return activeBlocks.contains { $0.lock == .locked }
            || lists.contains { $0.program.isLocked(at: now) }
            || (freeze.map { $0.end > now } ?? false)
    }

    var suggestions: [BlockSuggestion] { BlockSuggestion.catalog }

    func list(_ id: UUID) -> BlockList? { lists.first { $0.id == id } }

    // MARK: Lists

    func editCheck(_ next: BlockList) -> BlockingEditCheck {
        guard let current = list(next.id) else { return .allowed }
        guard isStricterOnly(current.id) else { return .allowed }
        let removedSites = Set(current.sites).subtracting(next.sites)
        let removedApps = Set(current.apps).subtracting(next.apps)
        if next.mode != current.mode { return .refused("Le mode ne change pas pendant un verrou.") }
        if current.mode == .block, !removedSites.isEmpty || !removedApps.isEmpty {
            return .refused("Pendant un verrou, une liste peut seulement s’allonger.")
        }
        if current.mode == .allowOnly, next.sites.count > current.sites.count || next.apps.count > current.apps.count {
            return .refused("Pendant un verrou, « Tout bloquer sauf » ne peut pas s’élargir.")
        }
        if let quota = next.quotaMinutesPerDay, quota > (current.quotaMinutesPerDay ?? 0) || current.quotaMinutesPerDay == nil {
            return .refused("Pendant un verrou, le temps permis peut seulement baisser.")
        }
        if let breaks = next.breaks {
            let old = current.breaks ?? BlockBreaks(count: 0, minutes: 0)
            if breaks.count > old.count || breaks.minutes > old.minutes {
                return .refused("Pendant un verrou, les pauses peuvent seulement diminuer.")
            }
        }
        let oldMinutes = Self.programCoverage(current.program), newMinutes = Self.programCoverage(next.program)
        if !oldMinutes.isSubset(of: newMinutes) { return .refused("Pendant un verrou, le programme peut seulement s’allonger.") }
        return .allowed
    }

    func save(_ next: BlockList) {
        if case .refused(let reason) = editCheck(next) { error = reason; return }
        if let index = document.lists.firstIndex(where: { $0.id == next.id }) {
            document.lists[index] = next
        } else {
            document.lists.append(next)
        }
        commit()
    }

    func delete(_ id: UUID) {
        if isStricterOnly(id) { error = "Une liste verrouillée ne peut pas être supprimée."; return }
        document.lists.removeAll { $0.id == id }
        document.sessions = document.sessions.compactMap { session in
            var session = session
            session.listIDs.removeAll { $0 == id }
            return session.listIDs.isEmpty ? nil : session
        }
        commit()
    }

    func lockProgram(listID: UUID, until date: Date) {
        guard let index = document.lists.firstIndex(where: { $0.id == listID }) else { return }
        let current = document.lists[index].program.lockedUntil ?? .distantPast
        document.lists[index].program.lockedUntil = max(current, date)
        commit()
    }

    // MARK: Sessions

    func start(listIDs: [UUID], until end: Date, lock: BlockLock) {
        let now = clock()
        guard !listIDs.isEmpty, end > now else { return }
        document.sessions.append(BlockSession(listIDs: listIDs, start: now, end: end, lock: lock))
        commit()
    }

    /// Ends a manual session. `typed` must match the challenge for `.typing`; `.locked` never stops.
    func stop(_ id: UUID, typed: String? = nil) {
        guard let session = document.sessions.first(where: { $0.id == id }) else { return }
        switch session.lock {
        case .locked:
            error = "Ce blocage est verrouillé jusqu’à la fin."
            return
        case .typing:
            guard let typed, typed == typingChallenge(for: id) else {
                error = "Le texte ne correspond pas."
                return
            }
        case .free:
            break
        }
        document.sessions.removeAll { $0.id == id }
        commit()
    }

    private var challenges: [UUID: String] = [:]

    func typingChallenge(for id: UUID) -> String {
        if let value = challenges[id] { return value }
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let value = String((0..<120).map { _ in alphabet.randomElement()! })
        challenges[id] = value
        return value
    }

    func takeBreak(listID: UUID) {
        guard let breaks = list(listID)?.breaks else { return }
        var usage = todayUsage()
        let taken = usage.breaksTaken[listID] ?? 0
        guard taken < breaks.count, freeze == nil else { return }
        usage.breaksTaken[listID] = taken + 1
        usage.breakEnds[listID] = clock().addingTimeInterval(TimeInterval(breaks.minutes * 60))
        document.usage = usage
        commit()
    }

    func endBreak(listID: UUID) {
        var usage = todayUsage()
        usage.breakEnds[listID] = nil
        document.usage = usage
        commit()
    }

    // MARK: Freeze

    func startFreeze(until end: Date, mode: BlockFreeze.Mode, allowedApps: [BlockAppRule]) {
        let now = clock()
        let bounded = min(max(end, now.addingTimeInterval(5 * 60)), now.addingTimeInterval(24 * 3_600))
        document.freeze = BlockFreeze(start: now, end: bounded, mode: mode, allowedApps: allowedApps)
        commit()
    }

    // MARK: Apps

    nonisolated static func installedApps() async -> [BlockAppRule] {
        let manager = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        var seen = Set<String>(), apps: [BlockAppRule] = []
        for root in roots {
            let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in children where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !BlockingRules.neverBlocked.contains(id), seen.insert(id).inserted else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(BlockAppRule(bundleIdentifier: id, name: name))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: State

    func refresh() {
        let now = clock()
        document.sessions.removeAll { $0.end <= now }
        if let freeze = document.freeze, freeze.end <= now { document.freeze = nil }
        lists = document.lists
        freeze = document.freeze
        let usage = todayUsage()
        activeBlocks = document.sessions.map { session in
            var block = BlockingActiveBlock(id: session.id, listIDs: session.listIDs, start: session.start,
                                            end: session.end, lock: session.lock, origin: session.origin)
            for id in session.listIDs {
                guard let list = list(id) else { continue }
                if let breaks = list.breaks { block.breaksLeft[id] = max(0, breaks.count - (usage.breaksTaken[id] ?? 0)) }
                if let end = usage.breakEnds[id], end > now { block.breakEnds[id] = end }
                if let quota = list.quotaMinutesPerDay {
                    block.quotaSecondsLeft[id] = max(0, Double(quota * 60) - (usage.quotaSecondsUsed[id] ?? 0))
                }
            }
            return block
        } + programBlocks(at: now, usage: usage)
        nextProgramStart = nextStart(after: now)
    }

    private func commit() {
        refresh()
    }

    private func todayUsage() -> BlockDayUsage {
        let day = Self.dayKey(clock())
        if let usage = document.usage, usage.day == day { return usage }
        return BlockDayUsage(day: day)
    }

    private func isStricterOnly(_ listID: UUID) -> Bool {
        let now = clock()
        if list(listID)?.program.isLocked(at: now) == true { return true }
        return activeBlocks.contains { $0.lock == .locked && $0.listIDs.contains(listID) }
    }

    private func programBlocks(at now: Date, usage: BlockDayUsage) -> [BlockingActiveBlock] {
        document.lists.compactMap { list in
            guard let window = BlockingSchedule.currentWindow(of: list.program, at: now) else { return nil }
            var block = BlockingActiveBlock(id: window.rangeID, listIDs: [list.id], start: window.start, end: window.end,
                                            lock: list.program.isLocked(at: now) ? .locked : .free,
                                            origin: .program(window.rangeID))
            if let breaks = list.breaks { block.breaksLeft[list.id] = max(0, breaks.count - (usage.breaksTaken[list.id] ?? 0)) }
            if let end = usage.breakEnds[list.id], end > now { block.breakEnds[list.id] = end }
            if let quota = list.quotaMinutesPerDay {
                block.quotaSecondsLeft[list.id] = max(0, Double(quota * 60) - (usage.quotaSecondsUsed[list.id] ?? 0))
            }
            return block
        }
    }

    private func nextStart(after now: Date) -> (listID: UUID, date: Date)? {
        document.lists.compactMap { list in
            BlockingSchedule.nextStart(of: list.program, after: now).map { (list.id, $0) }
        }.min { $0.1 < $1.1 }
    }

    /// Every (weekday, minute-of-week) the program covers, at minute resolution.
    static func programCoverage(_ program: BlockProgram) -> Set<Int> {
        var minutes = Set<Int>()
        for range in program.ranges {
            for day in range.weekdays {
                let base = (day - 1) * 1_440 + range.startMinute
                for offset in 0..<range.durationMinutes { minutes.insert((base + offset) % (7 * 1_440)) }
            }
        }
        return minutes
    }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
/// Holds the controller only while the module is on.
@MainActor final class BlockingRuntime: ObservableObject {
    static let shared = BlockingRuntime()
    @Published private(set) var controller: BlockingController?
    private var observer: NSObjectProtocol?

    func start(modules: GoalongModuleStore = .shared) {
        apply(enabled: modules.isEnabled(.blocking))
        observer = NotificationCenter.default.addObserver(forName: .goalongModulesDidChange, object: modules, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.apply(enabled: modules.isEnabled(.blocking)) }
        }
    }

    func apply(enabled: Bool) {
        if enabled, controller == nil {
            controller = BlockingController()
        } else if !enabled, let controller, !controller.hasLocks {
            self.controller = nil
        }
    }
}
#endif
