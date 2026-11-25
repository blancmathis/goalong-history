#if os(macOS)
import Foundation

/// The member's attention is sequential; the processes they coordinate need not be.
/// These types extend the existing daily plan and never infer a completed result.
enum FocusActionKind: String, Codable, CaseIterable {
    case work, launch, coordination, review, routine
    var title: String {
        switch self {
        case .work: return "Travail"
        case .launch: return "Lancer les processus"
        case .coordination: return "Répondre et débloquer"
        case .review: return "Relire et valider"
        case .routine: return "Routine"
        }
    }
}

struct FocusAgentProcess: Codable, Equatable, Identifiable {
    enum Status: String, Codable, CaseIterable {
        case queued, running, waitingForYou, readyForReview, done, failed, cancelled
        var title: String {
            switch self {
            case .queued: return "À lancer"
            case .running: return "En cours"
            case .waitingForYou: return "Attend votre réponse"
            case .readyForReview: return "À relire"
            case .done: return "Terminé"
            case .failed: return "À débloquer"
            case .cancelled: return "Annulé"
            }
        }
        var isFinished: Bool { self == .done || self == .cancelled }
    }
    var id = UUID()
    var title: String
    var project: String? = nil
    var agent: String? = nil
    var externalID: String? = nil
    var contextURL: String? = nil
    var status: Status = .queued
    var question: String? = nil
    var answer: String? = nil
    var updatedAt: Date? = nil
    var needsAnswer: Bool {
        status == .waitingForYou && (answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    var valid: Bool {
        FocusValidation.text(title, maximum: 140, required: true)
            && FocusDayValidation.text(project, maximum: 140)
            && FocusDayValidation.text(agent, maximum: 140)
            && FocusDayValidation.text(externalID, maximum: 256)
            && FocusDayValidation.contextURL(contextURL)
            && FocusDayValidation.text(question, maximum: 1000)
            && FocusDayValidation.text(answer, maximum: 1000)
            && (updatedAt.map { $0.timeIntervalSince1970.isFinite } ?? true)
    }
    enum CodingKeys: String, CodingKey { case id, title, project, agent, externalID, contextURL, status, question, answer, updatedAt }
    init(id: UUID = UUID(), title: String, project: String? = nil, agent: String? = nil,
         externalID: String? = nil, contextURL: String? = nil, status: Status = .queued,
         question: String? = nil, answer: String? = nil, updatedAt: Date? = nil) {
        self.id = id; self.title = title; self.project = project; self.agent = agent
        self.externalID = externalID; self.contextURL = contextURL; self.status = status
        self.question = question; self.answer = answer; self.updatedAt = updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID)
        contextURL = try c.decodeIfPresent(String.self, forKey: .contextURL)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        question = try c.decodeIfPresent(String.self, forKey: .question)
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct FocusAgendaSlot: Codable, Equatable, Identifiable {
    enum State: String, Codable, CaseIterable {
        case planned, active, done, skipped, unscheduled
        var title: String {
            switch self {
            case .planned: return "Prévu"
            case .active: return "En cours"
            case .done: return "Fait"
            case .skipped: return "Reporté"
            case .unscheduled: return "À replacer"
            }
        }
        var isFinished: Bool { self == .done || self == .skipped }
    }
    var id = UUID()
    var itemID: UUID? = nil
    var title: String
    var startMinute: Int
    var endMinute: Int
    var fixed = false
    var state: State = .planned
    var earliestMinute: Int? = nil
    var latestEndMinute: Int? = nil
    var durationMinutes: Int { endMinute - startMinute }
    var valid: Bool {
        FocusValidation.text(title, maximum: 140, required: true)
            && (0..<1440).contains(startMinute) && (1...1440).contains(endMinute)
            && endMinute > startMinute
            && (earliestMinute.map { (0..<1440).contains($0) } ?? true)
            && (latestEndMinute.map { (1...1440).contains($0) } ?? true)
            && (earliestMinute == nil || latestEndMinute == nil || earliestMinute! < latestEndMinute!)
            && (state == .unscheduled || ((earliestMinute.map { startMinute >= $0 } ?? true)
                && (latestEndMinute.map { endMinute <= $0 } ?? true)))
    }
    enum CodingKeys: String, CodingKey { case id, itemID, title, startMinute, endMinute, fixed, state, earliestMinute, latestEndMinute }
    init(id: UUID = UUID(), itemID: UUID? = nil, title: String, startMinute: Int, endMinute: Int,
         fixed: Bool = false, state: State = .planned, earliestMinute: Int? = nil, latestEndMinute: Int? = nil) {
        self.id = id; self.itemID = itemID; self.title = title
        self.startMinute = startMinute; self.endMinute = endMinute; self.fixed = fixed
        self.state = state; self.earliestMinute = earliestMinute; self.latestEndMinute = latestEndMinute
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        itemID = try c.decodeIfPresent(UUID.self, forKey: .itemID)
        title = try c.decode(String.self, forKey: .title)
        startMinute = try c.decode(Int.self, forKey: .startMinute)
        endMinute = try c.decode(Int.self, forKey: .endMinute)
        fixed = try c.decodeIfPresent(Bool.self, forKey: .fixed) ?? false
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .planned
        earliestMinute = try c.decodeIfPresent(Int.self, forKey: .earliestMinute)
        latestEndMinute = try c.decodeIfPresent(Int.self, forKey: .latestEndMinute)
    }
}

struct FocusAgenda: Codable, Equatable {
    var timeZoneID: String
    /// Placement bounds for flexible work. Fixed routines may lie outside them.
    var startMinute = 480
    var endMinute = 1320
    var bufferMinutes = 10
    /// Daily prompt budget; a small default, adjustable for a fully guided routine.
    var reminderLimit = 8
    var guided = false
    var autoAdjust = true
    var slots: [FocusAgendaSlot] = []
    static let maximumSlots = 64
    var valid: Bool {
        TimeZone(identifier: timeZoneID) != nil
            && (0..<1440).contains(startMinute) && (1...1440).contains(endMinute) && startMinute < endMinute
            && (0...60).contains(bufferMinutes) && (1...32).contains(reminderLimit)
            && slots.count <= Self.maximumSlots && Set(slots.map(\.id)).count == slots.count
            && slots.allSatisfy(\.valid)
            && slots.filter { $0.state == .active }.count <= 1
    }
    var validTemplate: Bool { valid && slots.allSatisfy { $0.itemID == nil && $0.state == .planned } }
    func valid(forDay day: String, items: [FocusPlanItem]) -> Bool {
        guard valid else { return false }
        let itemIDs = Set(items.map(\.id))
        return slots.allSatisfy { slot in
            (slot.itemID.map { itemIDs.contains($0) } ?? true)
                && FocusDayPlanner.date(day: day, minute: slot.startMinute, timeZoneID: timeZoneID) != nil
                && FocusDayPlanner.date(day: day, minute: slot.endMinute, timeZoneID: timeZoneID) != nil
        }
    }
    enum CodingKeys: String, CodingKey { case timeZoneID, startMinute, endMinute, bufferMinutes, reminderLimit, guided, autoAdjust, slots }
    init(timeZoneID: String, startMinute: Int = 480, endMinute: Int = 1320,
         bufferMinutes: Int = 10, reminderLimit: Int = 8, guided: Bool = false, autoAdjust: Bool = true, slots: [FocusAgendaSlot] = []) {
        self.timeZoneID = timeZoneID; self.startMinute = startMinute; self.endMinute = endMinute
        self.bufferMinutes = bufferMinutes; self.reminderLimit = reminderLimit
        self.guided = guided; self.autoAdjust = autoAdjust; self.slots = slots
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeZoneID = try c.decode(String.self, forKey: .timeZoneID)
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute) ?? 480
        endMinute = try c.decodeIfPresent(Int.self, forKey: .endMinute) ?? 1320
        bufferMinutes = try c.decodeIfPresent(Int.self, forKey: .bufferMinutes) ?? 10
        reminderLimit = try c.decodeIfPresent(Int.self, forKey: .reminderLimit) ?? 8
        guided = try c.decodeIfPresent(Bool.self, forKey: .guided) ?? false
        autoAdjust = try c.decodeIfPresent(Bool.self, forKey: .autoAdjust) ?? true
        slots = try c.decodeIfPresent([FocusAgendaSlot].self, forKey: .slots) ?? []
    }
}

struct FocusPlanReceipt: Codable, Equatable {
    var id: String
    var revision: Int
    var digest: String? = nil
    var valid: Bool {
        FocusValidation.text(id, maximum: 128, required: true)
            && FocusDayValidation.revision(revision)
            && FocusDayValidation.text(digest, maximum: 128)
    }
}

struct FocusPlanChange: Codable, Equatable, Identifiable {
    var id = UUID()
    var at: Date
    var actor: String? = nil
    var reason: String
    var revision: Int
    var valid: Bool {
        at.timeIntervalSince1970.isFinite && FocusDayValidation.text(actor, maximum: 140)
            && FocusValidation.text(reason, maximum: 500, required: true) && FocusDayValidation.revision(revision)
    }
}

enum FocusDayValidation {
    static func text(_ value: String?, maximum: Int) -> Bool {
        value.map { FocusValidation.text($0, maximum: maximum) } ?? true
    }
    static func revision(_ value: Int) -> Bool { (0...1_000_000_000).contains(value) }
    /// These are links opened by an explicit user action through the app's existing open policy.
    /// Never accept a file, shell command, credentials-bearing URL or an active-content scheme.
    static func contextURL(_ value: String?) -> Bool {
        guard let value else { return true }
        guard FocusValidation.text(value, maximum: 2048),
              let c = URLComponents(string: value), c.user == nil, c.password == nil,
              let scheme = c.scheme?.lowercased(), ["https", "http", "context-room", "t3"].contains(scheme),
              let url = c.url, url.absoluteString == value else { return false }
        if scheme == "https" || scheme == "http" { return c.host.map { !$0.isEmpty } ?? false }
        return !(c.host?.isEmpty ?? true) || !c.path.isEmpty
    }
}

struct FocusSlotChange: Codable, Equatable {
    var slotID: UUID
    var oldStartMinute: Int
    var oldEndMinute: Int
    var startMinute: Int
    var endMinute: Int
    var state: FocusAgendaSlot.State
    var reason: String
}

struct FocusDayReflow: Codable, Equatable {
    var agenda: FocusAgenda?
    var changes: [FocusSlotChange] = []
    var unplaced: [UUID] = []
    var conflicts: [String] = []
}

enum FocusDayPlanner {
    static func calendar(timeZoneID: String) -> Calendar? {
        guard let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c
    }
    static func dayKey(at date: Date, timeZoneID: String) -> String? {
        guard let c = calendar(timeZoneID: timeZoneID) else { return nil }
        let d = c.dateComponents([.year, .month, .day], from: date)
        guard let y = d.year, let m = d.month, let day = d.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, day)
    }
    static func localMinute(at date: Date, timeZoneID: String) -> Int? {
        guard let c = calendar(timeZoneID: timeZoneID) else { return nil }
        return c.component(.hour, from: date) * 60 + c.component(.minute, from: date)
    }
    /// Missing wall-clock times on a spring DST transition are invalid, never silently shifted.
    /// Repeated wall-clock times use their first occurrence; durations here are wall-clock slots.
    static func date(day: String, minute: Int, timeZoneID: String) -> Date? {
        guard FocusValidation.day(day), (0...1440).contains(minute), let c = calendar(timeZoneID: timeZoneID) else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let start = c.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        if minute == 1440 { return c.date(byAdding: .day, value: 1, to: start) }
        let match = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
        guard let value = c.nextDate(after: start.addingTimeInterval(-1), matching: match,
            matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward),
            dayKey(at: value, timeZoneID: timeZoneID) == day else { return nil }
        return value
    }
    static func task(for slot: FocusAgendaSlot, in plan: FocusPlan) -> FocusPlanItem? {
        guard let id = slot.itemID else { return nil }; return plan.items.first { $0.id == id }
    }
    static func waitingProcesses(plan: FocusPlan) -> [FocusAgentProcess] {
        (plan.processes ?? []).filter(\.needsAnswer)
    }
    static func currentSlot(plan: FocusPlan, at now: Date) -> FocusAgendaSlot? {
        guard let a = plan.agenda, a.valid, dayKey(at: now, timeZoneID: a.timeZoneID) == plan.day else { return nil }
        let open = a.slots.filter { slot in
            !slot.state.isFinished && slot.state != .unscheduled
                && (task(for: slot, in: plan).map { $0.status == .open } ?? true)
        }.sorted(by: ordered)
        if let active = open.first(where: { $0.state == .active }) { return active }
        return open.first { slot in
            guard let start = date(day: plan.day, minute: slot.startMinute, timeZoneID: a.timeZoneID),
                  let end = date(day: plan.day, minute: slot.endMinute, timeZoneID: a.timeZoneID) else { return false }
            return start <= now && now < end
        }
    }
    static func nextSlot(plan: FocusPlan, at now: Date) -> FocusAgendaSlot? {
        guard let a = plan.agenda, a.valid,
              let currentDay = dayKey(at: now, timeZoneID: a.timeZoneID), currentDay <= plan.day else { return nil }
        let current = currentSlot(plan: plan, at: now)?.id
        return a.slots.filter { slot in
            slot.id != current && slot.state == .planned
                && (date(day: plan.day, minute: slot.startMinute, timeZoneID: a.timeZoneID).map { $0 >= now } ?? false)
                && (task(for: slot, in: plan).map { $0.status == .open } ?? true)
        }.sorted(by: ordered).first
    }
    /// Pure placement: no timer, observation, network, process launch or storage.
    /// Running agent processes never consume a slot of the member's attention.
    static func reflow(plan: FocusPlan, now: Date, notBeforeMinute: Int? = nil) -> FocusDayReflow {
        guard var agenda = plan.agenda else { return FocusDayReflow(agenda: nil) }
        var result = FocusDayReflow(agenda: agenda)
        guard agenda.valid(forDay: plan.day, items: plan.items),
              let nowDay = dayKey(at: now, timeZoneID: agenda.timeZoneID),
              notBeforeMinute.map({ (0...1440).contains($0) }) ?? true else {
            result.conflicts = ["Le programme contient un horaire ou une référence invalide."]; return result
        }
        let minute = nowDay == plan.day ? (localMinute(at: now, timeZoneID: agenda.timeZoneID) ?? 0) : (nowDay > plan.day ? 1440 : 0)
        let floor = max(agenda.startMinute, max(minute, notBeforeMinute ?? 0))
        let originals = Dictionary(uniqueKeysWithValues: agenda.slots.map { ($0.id, $0) })
        // Declared task completion is authoritative. Activity evidence never reaches this code.
        for i in agenda.slots.indices {
            guard let task = task(for: agenda.slots[i], in: plan), task.status != .open,
                  !agenda.slots[i].state.isFinished else { continue }
            agenda.slots[i].state = task.status == .done ? .done : .skipped
        }
        struct Occupied { var start: Int; var end: Int; var id: UUID }
        let protected = agenda.slots.filter { ($0.fixed || $0.state == .active) && !$0.state.isFinished && $0.state != .unscheduled }.sorted(by: ordered)
        var occupied: [Occupied] = []
        for slot in protected {
            if protected.contains(where: { $0.id != slot.id && $0.startMinute < slot.endMinute && slot.startMinute < $0.endMinute }) {
                let message = "Chevauchement entre un créneau fixe ou en cours et « \(slot.title) »."
                if !result.conflicts.contains(message) { result.conflicts.append(message) }
            }
            if slot.state == .active && nowDay == plan.day
                && (date(day: plan.day, minute: slot.endMinute, timeZoneID: agenda.timeZoneID).map { $0 <= now } ?? false) {
                result.conflicts.append("« \(slot.title) » est encore en cours ; sa prolongation demande un choix.")
            }
            occupied.append(.init(start: slot.startMinute,
                end: slot.state == .active ? max(slot.endMinute, minute) : slot.endMinute, id: slot.id))
        }
        let candidates = agenda.slots.indices.filter {
            !agenda.slots[$0].fixed && (agenda.slots[$0].state == .planned || agenda.slots[$0].state == .unscheduled)
        }.sorted { ordered(agenda.slots[$0], agenda.slots[$1]) }
        var cursor = floor
        for index in candidates {
            let old = agenda.slots[index]
            let duration = old.durationMinutes
            let latest = min(agenda.endMinute, old.latestEndMinute ?? agenda.endMinute)
            var start = max(cursor, max(old.startMinute, old.earliestMinute ?? agenda.startMinute))
            // Find a full-length free interval; never split or shorten work implicitly.
            while start + duration <= latest {
                if let hit = occupied.sorted(by: { $0.start < $1.start }).first(where: {
                    start < $0.end + agenda.bufferMinutes && start + duration + agenda.bufferMinutes > $0.start
                }) {
                    start = max(start + 1, hit.end + agenda.bufferMinutes)
                    continue
                }
                // The start must be in the future in absolute time too: round past partial minutes
                // and the first occurrence of an hour already passed during an autumn clock change.
                guard let startDate = date(day: plan.day, minute: start, timeZoneID: agenda.timeZoneID),
                      startDate >= now,
                      date(day: plan.day, minute: start + duration, timeZoneID: agenda.timeZoneID) != nil else {
                    start += 1; continue
                }
                break
            }
            if start + duration > latest || nowDay > plan.day {
                agenda.slots[index].state = .unscheduled
                result.unplaced.append(old.id)
            } else {
                agenda.slots[index].startMinute = start
                agenda.slots[index].endMinute = start + duration
                agenda.slots[index].state = .planned
                occupied.append(.init(start: start, end: start + duration, id: old.id))
                cursor = start + duration + agenda.bufferMinutes
            }
        }
        for slot in agenda.slots {
            guard let old = originals[slot.id], old != slot else { continue }
            result.changes.append(.init(slotID: slot.id, oldStartMinute: old.startMinute, oldEndMinute: old.endMinute,
                startMinute: slot.startMinute, endMinute: slot.endMinute, state: slot.state,
                reason: slot.state == .unscheduled ? "Ne tient plus dans les créneaux autorisés."
                    : slot.state.isFinished ? "Résultat déclaré de la tâche."
                    : "Décalage dans les créneaux disponibles, repères fixes conservés."))
        }
        result.agenda = agenda
        return result
    }
    private static func ordered(_ lhs: FocusAgendaSlot, _ rhs: FocusAgendaSlot) -> Bool {
        if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
        if lhs.fixed != rhs.fixed { return lhs.fixed }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
#endif
