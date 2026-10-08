#if os(macOS)
import Foundation

struct BlockTriggers: Codable, Hashable {
    var apps: [BlockAppRule] = []
    /// Reserved until the App Intents packaging/discovery gate passes. `true` is refused.
    var focus = false
    init(apps: [BlockAppRule] = [], focus: Bool = false) { self.apps = apps; self.focus = focus }
    enum CodingKeys: String, CodingKey { case apps, focus }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = try c.decodeIfPresent([BlockAppRule].self, forKey: .apps) ?? []
        focus = try c.decodeIfPresent(Bool.self, forKey: .focus) ?? false
    }
}

struct BlockEarn: Codable, Hashable {
    var workMinutes = 25
    var rewardMinutes = 5
    var capMinutes = 60
    init(workMinutes: Int = 25, rewardMinutes: Int = 5, capMinutes: Int = 60) {
        self.workMinutes = workMinutes; self.rewardMinutes = rewardMinutes; self.capMinutes = capMinutes
    }
    enum CodingKeys: String, CodingKey { case workMinutes, rewardMinutes, capMinutes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workMinutes = try c.decodeIfPresent(Int.self, forKey: .workMinutes) ?? 25
        rewardMinutes = try c.decodeIfPresent(Int.self, forKey: .rewardMinutes) ?? 5
        capMinutes = try c.decodeIfPresent(Int.self, forKey: .capMinutes) ?? 60
    }
    var valid: Bool {
        (10...120).contains(workMinutes) && (1...30).contains(rewardMinutes)
            && (5...240).contains(capMinutes)
    }
    func rewardSeconds(focusedSeconds: Double) -> Double {
        guard valid, focusedSeconds.isFinite, focusedSeconds >= 0 else { return 0 }
        return min(Double(capMinutes * 60), floor(focusedSeconds / Double(workMinutes * 60)) * Double(rewardMinutes * 60))
    }
}

/// Local presentation data only. No target, URL, title, session intent or Jev verdict is retained.
struct BlockingListFeedback: Equatable, Hashable {
    var listID: UUID
    var reason: String?
    var attemptsToday: Int
    var earnedMinutesToday: Double
    var reasonLine: String? { reason.map { "« \($0) »" } }
    var attemptLine: String? { attemptsToday >= 2 ? "\(attemptsToday)ᵉ tentative aujourd’hui" : nil }
    var earnedLine: String? { earnedMinutesToday > 0 ? "+\(Int(earnedMinutesToday)) min gagnées" : nil }
}

/// Presentation model kept outside SwiftUI so the engine/UI handoff remains independent.
struct BlockingVeilPresentation: Equatable {
    enum Reason: Equatable {
        case site(String)
        case privateWindow
        case unsupportedBrowser(String)
        case quotaUsed(String, minutes: Int)
    }
    var reason: Reason
    var listName: String
    var start: Date
    var end: Date
    var lock: BlockLock
    var breakMinutes: Int?
    var breaksLeft = 0
    var feedback: BlockingListFeedback?
}

extension BlockingRules {
    static func normalizeReason(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...140).contains(value.count) ? value : nil
    }
    static func validTriggers(_ triggers: BlockTriggers, list: BlockList) -> Bool {
        guard !triggers.focus, triggers.apps.count <= 200,
              Set(triggers.apps.map(\.bundleIdentifier)).count == triggers.apps.count else { return false }
        return triggers.apps.allSatisfy { app in
            let id = app.bundleIdentifier
            guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  !neverBlocked.contains(id), !app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let appMatch = list.apps.contains { $0.bundleIdentifier == id }
            return list.mode == .block ? !appMatch : appMatch
        }
    }
    static func effectiveQuotaSeconds(_ list: BlockList, usage: BlockDayUsage) -> Double? {
        list.quotaMinutesPerDay.map { Double($0 * 60) + (usage.earnedSeconds?[list.id] ?? 0) }
    }
    static func validPlusUsage(_ usage: BlockDayUsage) -> Bool {
        (usage.blocked?.values.allSatisfy { $0 >= 0 } ?? true)
            && (usage.earnedSeconds?.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 240 * 60 } ?? true)
            && (usage.earnedSessionIDs.map { $0.count <= 4096 && Set($0).count == $0.count } ?? true)
    }
    /// Work-phase elapsed time, excluding breaks and skipped work; no inferred work/AI score.
    static func earnedWorkSeconds(_ session: FocusSession) -> Double {
        guard session.valid, let stop = session.events.last, stop.kind == .stop,
              stop.reason == .completed, stop.at >= session.startedAt else { return 0 }
        return FocusMeasurement.workIntervals(session, until: stop.at).reduce(0) { $0 + $1.duration }
    }
}
#endif
