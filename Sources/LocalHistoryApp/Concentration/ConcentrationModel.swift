#if os(macOS)
import Foundation
import LocalHistoryQueryCLI

/// Local, member-authored data. No phase or inferred completion is persisted.
struct FocusMode: Codable, Equatable {
    enum Kind: String, Codable { case free, pomodoro }
    var kind: Kind = .free
    var minutes: Int? = 25
    var workMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var longBreakEvery = 4
    var cycles: Int?
    var valid: Bool {
        switch kind {
        case .free: return minutes.map { (5...240).contains($0) } ?? true
        case .pomodoro: return (5...120).contains(workMinutes) && (1...30).contains(shortBreakMinutes)
            && (5...60).contains(longBreakMinutes) && (2...8).contains(longBreakEvery)
            && (cycles.map { (1...16).contains($0) } ?? true)
        }
    }
}
struct FocusSession: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable { case done, partly; case notDone = "not-done" }
    struct Event: Codable, Equatable {
        enum Kind: String, Codable { case start, skip, stop }
        enum Reason: String, Codable { case completed, member, appClosed, moduleDisabled }
        var kind: Kind
        var at: Date
        var reason: Reason?
    }
    var id = UUID()
    var intent: String
    var planItemId: UUID?
    var mode: FocusMode
    var blockListIds: [UUID] = []
    var blockDuringBreaks = false
    var lock = false
    var ambiance = false
    var startedAt: Date
    var plannedEndAt: Date?
    var events: [Event] = []
    var outcome: Outcome?
    var note: String?
    var endedAt: Date? { events.first { $0.kind == .stop }?.at }
    var valid: Bool {
        FocusValidation.text(intent, maximum: 140, required: true) && mode.valid
            && !(lock && mode.kind == .free && mode.minutes == nil) && (!lock || !blockListIds.isEmpty)
            && Set(blockListIds).count == blockListIds.count && blockListIds.count <= 200
            && events.count <= 1024 && events.first?.kind == .start && events.first?.at == startedAt
            && zip(events, events.dropFirst()).allSatisfy { $0.at <= $1.at }
            && events.dropFirst().allSatisfy { $0.kind != .start && $0.at >= startedAt }
            && events.filter { $0.kind == .stop }.count <= 1
            && (endedAt == nil || events.last?.kind == .stop)
            && (note.map { FocusValidation.text($0, maximum: 140) } ?? true)
    }
}
struct FocusPhase: Equatable {
    enum Kind: String, Codable { case work, shortBreak, longBreak, ended }
    var kind: Kind
    var cycle: Int
    var startedAt: Date
    var endsAt: Date?
    var isWork: Bool { kind == .work }
}
struct FocusPlanItem: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case open, done, dropped, moved }
    var id = UUID()
    var title: String
    var project: String?
    var estimateMinutes: Int?
    var status: Status = .open
    var toDay: String?
    var valid: Bool {
        FocusValidation.text(title, maximum: 140, required: true)
            && (project.map { FocusValidation.text($0, maximum: 140, required: true) } ?? true)
            && (estimateMinutes.map { (5...600).contains($0) } ?? true)
            && (status != .moved || toDay.map(FocusValidation.day) == true)
    }
}
struct FocusPlan: Codable, Equatable {
    var schema = 1
    var day: String
    var intention: String?
    var items: [FocusPlanItem] = []
    var valid: Bool { schema == 1 && FocusValidation.day(day) && items.count <= 10
        && Set(items.map(\.id)).count == items.count && items.allSatisfy(\.valid)
        && (intention.map { FocusValidation.text($0, maximum: 140) } ?? true) }
}
struct FocusReview: Codable, Equatable {
    struct Item: Codable, Equatable {
        var id: UUID
        var outcome: FocusSession.Outcome?
        var toDay: String?
    }
    var schema = 1
    var day: String
    var items: [Item] = []
    var tomorrowFirst: String?
    var note: String?
    var valid: Bool { schema == 1 && FocusValidation.day(day) && items.count <= 10
        && Set(items.map(\.id)).count == items.count && items.allSatisfy {
            ($0.toDay.map(FocusValidation.day) ?? true) && !($0.outcome != nil && $0.toDay != nil)
        } && (tomorrowFirst.map { FocusValidation.text($0, maximum: 140) } ?? true)
        && (note.map { FocusValidation.text($0, maximum: 500) } ?? true) }
}
struct FocusLimits: Codable, Equatable {
    var weeklyHours: Int?
    var dailyHours: Int?
    var endMinute: Int?
    var weekdays: Set<Int> = []
    var valid: Bool { (weeklyHours.map { (10...80).contains($0) } ?? true)
        && (dailyHours.map { (2...16).contains($0) } ?? true)
        && (endMinute.map { (0..<1440).contains($0) && !weekdays.isEmpty } ?? true)
        && weekdays.isSubset(of: Set(1...7)) }
}
struct FocusSettings: Codable, Equatable {
    var detectionEnabled = true
    var phaseSound = true
    var morningPrompt = true
    var morningMinute = 360
    var eveningPrompt = true
    var eveningMinute = 1110
    var limits = FocusLimits()
    /// Optional for compatibility with settings saved before Engagements.
    var commitmentJokers: FocusJokerSettings?
    var jokerSettings: FocusJokerSettings { commitmentJokers ?? FocusJokerSettings() }
    var valid: Bool { (0..<1440).contains(morningMinute) && (0..<1440).contains(eveningMinute) && limits.valid && jokerSettings.valid }
}
enum FocusFailure: String, Error { case moduleDisabled, invalidArgument, locked, notFound, storageFailed, appNotRunning }
enum FocusValidation {
    static func text(_ value: String, maximum: Int, required: Bool = false) -> Bool {
        value.count <= maximum && value.utf8.count <= maximum * 32 && (!required || !value.trimmingCharacters(in: .whitespaces).isEmpty)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func day(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f.date(from: value).map { f.string(from: $0) == value } ?? false
    }
}
typealias FocusCalendar = GoalongFocusCalendar

struct FocusJokerSettings: Codable, Equatable {
    var day = 2
    var week = 1
    var valid: Bool { (0...5).contains(day) && (0...2).contains(week) }
}
struct FocusCommitmentPeriod: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case day, week }
    var kind: Kind
    var key: String
    func interval(calendar: Calendar = .current) -> DateInterval? {
        kind == .day ? FocusCalendar.dayInterval(key, calendar: calendar) : FocusCalendar.weekInterval(key, calendar: calendar)
    }
    var valid: Bool { interval() != nil }
}
struct FocusStake: Codable, Equatable {
    var listIds: [UUID]
    var until = "12:00"
    var minute: Int? {
        let n = until.split(separator: ":", omittingEmptySubsequences: false)
        guard until.count == 5, n.count == 2, let h = Int(n[0]), let m = Int(n[1]),
              (0...23).contains(h), (0...59).contains(m), String(format: "%02d:%02d", h, m) == until else { return nil }
        return h * 60 + m
    }
    var valid: Bool { !listIds.isEmpty && listIds.count <= 200 && Set(listIds).count == listIds.count && minute != nil }
}
struct FocusCommitmentResult: Codable, Equatable {
    enum Outcome: String, Codable { case held, missed }
    struct Stake: Codable, Equatable {
        enum State: String, Codable { case none, applied, skipped, cancelled }
        enum Reason: String, Codable { case late, noList, blockingOff }
        var state: State = .none
        var blockId: UUID?
        var reason: Reason?
        var at: Date?
        var valid: Bool {
            switch state {
            case .none: return blockId == nil && reason == nil && at == nil
            case .applied: return blockId != nil && reason == nil
            case .skipped: return blockId == nil && reason != nil && at == nil
            case .cancelled: return reason == nil && at != nil
            }
        }
    }
    var settledAt: Date
    var measured: Double
    var unmeasuredMinutes: Double
    var outcome: Outcome
    var declared = false
    var jokerAt: Date?
    var stake = Stake()
    /// Keep the source label truthful if the work definition changes after settlement.
    var usesActiveTime: Bool?
    var valid: Bool {
        measured.isFinite && measured >= 0 && unmeasuredMinutes.isFinite && unmeasuredMinutes >= 0 && stake.valid
            && (!declared || outcome == .held) && !(declared && jokerAt != nil)
            && (jokerAt.map { $0 >= settledAt } ?? true) && (stake.at.map { $0 >= settledAt } ?? true)
    }
}
struct FocusCommitment: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case work, task, sessions, plan }
    struct Edit: Codable, Equatable { var at: Date; var target: Int; var stake: FocusStake? }
    var id = UUID()
    var period: FocusCommitmentPeriod
    var kind: Kind
    var target: Int
    var task: String?
    var stake: FocusStake?
    var createdAt: Date
    var edits: [Edit] = []
    var result: FocusCommitmentResult?
    static func validTarget(_ target: Int, kind: Kind, period: FocusCommitmentPeriod.Kind) -> Bool {
        switch (kind, period) {
        case (.work, .day): return (30...960).contains(target) && target % 15 == 0
        case (.work, .week): return (60...4800).contains(target) && target % 15 == 0
        case (.task, .day): return (15...960).contains(target) && target % 15 == 0
        case (.task, .week): return (30...4800).contains(target) && target % 15 == 0
        case (.sessions, .day): return (1...12).contains(target)
        case (.sessions, .week): return (1...60).contains(target)
        case (.plan, .day): return (1...10).contains(target)
        case (.plan, .week): return (1...70).contains(target)
        }
    }
    var valid: Bool {
        period.valid && Self.validTarget(target, kind: kind, period: period.kind)
            && (kind == .task ? task.map { FocusValidation.text($0, maximum: 140, required: true) } == true : task == nil)
            && (stake?.valid ?? true) && (result?.valid ?? true) && (result?.stake.blockId.map { $0 == id } ?? true)
            && (result?.stake.state != .applied || (stake != nil && result?.outcome == .missed && result?.jokerAt == nil && result?.declared == false))
            && edits.count <= 1024
            // The goal kind can change freely before commitment; old edits keep their original unit.
            && edits.allSatisfy { $0.at >= createdAt && (1...4800).contains($0.target) && ($0.stake?.valid ?? true) }
            && zip(edits, edits.dropFirst()).allSatisfy { $0.at <= $1.at }
    }
}
struct FocusCommitmentProgress: Codable, Equatable {
    var measured: Double = 0
    var unmeasuredMinutes: Double = 0
    var usesActiveTime = false
}
struct FocusCommitmentCard: Codable, Equatable, Identifiable {
    var commitment: FocusCommitment
    var progress: FocusCommitmentProgress
    var series: Int
    var jokersLeft: Int
    var canUseJoker: Bool
    var canDeclare: Bool
    var exitUntil: Date?
    var limitHours: Int?
    var editMode: String
    var editUntil: Date
    var id: UUID { commitment.id }
}
enum FocusJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return try e.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return try d.decode(type, from: data)
    }
}
struct FocusPromptState: Codable {
    var day: String
    var morningShown = false
    var eveningShown = false
    var morningReminded = false
    var eveningReminded = false
    var morningReminderAt: Date?
    var eveningReminderAt: Date?
}

protocol FocusSessionAudio {
    func startWork()
    func startBreak()
    func stop()
}
struct NoOpFocusSessionAudio: FocusSessionAudio {
    func startWork() {}
    func startBreak() {}
    func stop() {}
}
#endif
