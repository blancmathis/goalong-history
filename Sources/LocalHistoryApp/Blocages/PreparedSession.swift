#if os(macOS)
import Combine
import AppleScreenTime
import LocalHistoryCore
import SwiftUI

/// A session saved « pour plus tard » (T-050 lot B2): the four blocks of « Quoi », « Pendant », « Rythme » and the
/// stop. One model for every engine: nothing here names Concentration or Blocage (P1).
struct PreparedSession: Codable, Equatable, Identifiable {
    enum Span: Codable, Equatable { case minutes(Int), until(minute: Int) }

    var id = UUID()
    var name = ""
    // Rythme
    var pomodoro = false
    /// 0 = 25 / 5, 1 = 50 / 10, 2 = Autre.
    var rhythm = 0
    var work = 25, shortBreak = 5, longBreak = 15, every = 4
    var cycles: Int?
    var intent = ""
    // Pendant
    var span: Span = .minutes(60)
    // Quoi
    var listIDs: [UUID] = []
    var blockDuringBreaks = false
    var wholeMac = false
    var freezeMode: BlockFreeze.Mode = .shield
    var kept: [BlockAppRule] = []
    var red = false
    var intensity = 0.6
    var brightness: Double?
    var surveillance: JevInterventionSettings?
    // Arrêt
    var lock: BlockLock = .free

    var trimmedIntent: String { intent.trimmingCharacters(in: .whitespacesAndNewlines) }
    var holdsScreen: Bool { red || brightness != nil }

    var composer: FocusComposerDraft {
        var draft = FocusComposerDraft()
        draft.intent = intent
        draft.kind = pomodoro ? .pomodoro : .free
        draft.rhythm = rhythm == 1 ? .long : rhythm == 2 ? .custom : .classic
        (draft.work, draft.shortBreak, draft.longBreak, draft.every) = (work, shortBreak, longBreak, every)
        draft.cycles = cycles
        draft.blockListIds = Set(listIDs)
        draft.blockDuringBreaks = blockDuringBreaks
        draft.lock = lock == .locked
        if case .minutes(let value) = span { draft.free = .minutes(value) }
        return draft
    }

    var ruleDraft: BlockRuleDraft {
        var draft = BlockRuleDraft()
        draft.listIDs = Set(listIDs)
        draft.red = red; draft.intensity = intensity; draft.brightness = brightness
        draft.surveillance = surveillance
        draft.lock = lock
        return draft
    }

    /// The end of « Jusqu’à… »: the next time this minute of the day comes.
    static func untilDate(minute: Int, now: Date, calendar: Calendar = .current) -> Date {
        let date = calendar.date(byAdding: .minute, value: minute, to: calendar.startOfDay(for: now)) ?? now
        return date > now ? date : calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }

    func minutes(now: Date) -> Int {
        switch span {
        case .minutes(let value): return value
        case .until(let minute): return max(1, Int((Self.untilDate(minute: minute, now: now).timeIntervalSince(now) / 60).rounded()))
        }
    }

    /// « 1 h · Réseaux sociaux, Jeux · Mot de passe »: how long, what, how it stops.
    func summary(listNames: [UUID: String]) -> String {
        var length: String
        if pomodoro {
            let phases = rhythm == 0 ? "25 / 5" : rhythm == 1 ? "50 / 10" : "\(work) / \(shortBreak)"
            length = "Pomodoro \(phases), " + (cycles.map { "\($0) cycles" } ?? "jusqu’à l’arrêt")
        } else {
            switch span {
            case .minutes(let value): length = BlockingFormat.duration(minutes: value)
            case .until(let minute): length = String(format: "Jusqu’à %02d:%02d", minute / 60 % 24, minute % 60)
            }
        }
        var what: [String] = []
        if wholeMac { what.append("tout le Mac") } else { what += listIDs.compactMap { listNames[$0] } }
        if red { what.append("écran rouge") }
        if brightness != nil { what.append("luminosité") }
        if surveillance != nil { what.append("surveillance") }
        let stop = wholeMac ? BlockLock.locked.title : lock.title
        return [length, what.isEmpty ? "rien à bloquer" : what.joined(separator: ", "), stop].joined(separator: " · ")
    }
}

/// The global shortcut that relaunches the last session. A few fixed choices: none is taken by macOS.
enum RelaunchShortcut: String, Codable, CaseIterable {
    case none, controlOptionCommandR, controlOptionCommandS, controlOptionCommandL

    var title: String {
        switch self {
        case .none: return "Aucun"
        case .controlOptionCommandR: return "⌃⌥⌘R"
        case .controlOptionCommandS: return "⌃⌥⌘S"
        case .controlOptionCommandL: return "⌃⌥⌘L"
        }
    }

    /// The Carbon key code and modifiers (`cmdKey | optionKey | controlKey`). Nil = no shortcut.
    var key: (code: UInt32, modifiers: UInt32)? {
        let modifiers: UInt32 = 0x0100 | 0x0800 | 0x1000
        switch self {
        case .none: return nil
        case .controlOptionCommandR: return (0x0F, modifiers)
        case .controlOptionCommandS: return (0x01, modifiers)
        case .controlOptionCommandL: return (0x25, modifiers)
        }
    }
}

/// The prepared sessions, the last one started, and the shortcut. One JSON document in the preferences.
@MainActor final class PreparedSessionStore: ObservableObject {
    struct Document: Codable, Equatable {
        var schema = 1
        var sessions: [PreparedSession] = []
        var last: PreparedSession?
        var shortcut: RelaunchShortcut = .none
    }

    static let shared = PreparedSessionStore()
    static let storageKey = "goalong.sessions.prepared.v1"
    static let unreadableText = "Séances préparées illisibles : elles reviendront au prochain enregistrement."
    @Published private(set) var document = Document()
    @Published private(set) var error: String?
    /// A session that needs the window (a protected stop, the whole Mac, a refusal): the page « Blocages » opens it.
    @Published var request: PreparedSession?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = GoalongDefaults.standard) {
        self.defaults = defaults
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= 512_000,
              let value = try? JSONDecoder().decode(Document.self, from: data), value.schema == 1 else {
            error = Self.unreadableText
            return
        }
        document = value
    }

    func contains(_ id: UUID) -> Bool { document.sessions.contains { $0.id == id } }

    /// Adds the session, or replaces the one with its id.
    func save(_ session: PreparedSession) {
        var next = document
        if let index = next.sessions.firstIndex(where: { $0.id == session.id }) { next.sessions[index] = session }
        else { next.sessions.append(session) }
        write(next)
    }

    func delete(_ id: UUID) {
        var next = document
        next.sessions.removeAll { $0.id == id }
        write(next)
    }

    func recordLast(_ session: PreparedSession) {
        guard document.last != session else { return }
        var next = document
        next.last = session
        write(next)
    }

    func setShortcut(_ shortcut: RelaunchShortcut) {
        var next = document
        next.shortcut = shortcut
        write(next)
    }

    private func write(_ next: Document) {
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.storageKey)
        document = next; error = nil
    }
}

/// « Lancer » and « Relancer » in one click (P2). A stop that asks a confirmation or a consent (« Mot de passe »,
/// « Verrouillé », the whole Mac) opens the window instead: its alerts stay the only way to promise them.
@MainActor enum PreparedSessionLauncher {
    enum Path: Equatable { case focus, block, watch, editor }
    enum Outcome: Equatable { case started, needsEditor }

    /// Pure: which engine starts the session at once, or `.editor` when it needs the window.
    static func path(_ session: PreparedSession, hasFocus: Bool, hasBlocking: Bool, hasBraise: Bool,
                     lists: Set<UUID>) -> Path {
        if hasFocus, session.pomodoro || !session.trimmedIntent.isEmpty {
            return session.lock == .locked ? .editor : .focus
        }
        if session.pomodoro || session.wholeMac { return .editor }
        if session.holdsScreen, !hasBraise { return .editor }
        if session.listIDs.allSatisfy({ !lists.contains($0) }), !session.holdsScreen {
            return session.surveillance == nil ? .editor : .watch
        }
        return !hasBlocking || session.lock.protectsLists ? .editor : .block
    }

    static func launch(_ session: PreparedSession, blocking: BlockingController?, braise: BraiseController?,
                       focus: ConcentrationController?, store: PreparedSessionStore = .shared) -> Outcome {
        let now = Date() // wall: page input; the controllers move it to their trusted frame
        let lists = Set(blocking?.lists.map(\.id) ?? [])
        let ids = session.listIDs.filter(lists.contains)
        let plan: BlockingNowPlan
        switch session.span {
        case .minutes(let value): plan = BlockingNowPlan(later: false, startAt: now, minutes: value, now: now)
        case .until(let minute):
            plan = BlockingNowPlan(later: false, startAt: now, until: PreparedSession.untilDate(minute: minute, now: now), now: now)
        }
        switch path(session, hasFocus: focus != nil, hasBlocking: blocking != nil, hasBraise: braise != nil, lists: lists) {
        case .editor: return .needsEditor
        case .watch:
            mark(.own, id: UUID(), session: session, start: plan.start, end: plan.end)
        case .focus:
            guard let focus, focus.currentSession == nil else { return .needsEditor }
            var draft = session.composer
            if draft.kind == .free { draft.free = .minutes(session.minutes(now: now)) }
            do {
                focus.refresh()
                try focus.startSession(intent: session.trimmedIntent.isEmpty ? BlockRuleEditor.defaultIntent : session.trimmedIntent,
                                       mode: draft.mode, planItemId: focus.openPlanItemID(nil), blockListIds: ids,
                                       blockDuringBreaks: session.pomodoro && session.blockDuringBreaks, lock: false)
            } catch {
                focus.error = FocusUIError.message(error)
                return .needsEditor
            }
            if let id = focus.currentSession?.id { mark(.focus, id: id, session: session) }
        case .block:
            guard let blocking else { return .needsEditor }
            let span: BlockingNowComposer.Span
            if case .minutes(let value) = session.span { span = .minutes(value) } else { span = .until }
            var started: UUID?
            guard BlockingNowStart.run(plan, listIDs: ids, lock: session.lock, controller: blocking,
                                       braise: session.holdsScreen ? braise : nil, red: session.red,
                                       intensity: session.intensity, brightness: session.brightness,
                                       refusal: BlockingNowComposer.refusal(span, freeze: false),
                                       started: { started = $0 }) else { return .needsEditor }
            if let started { mark(.block, id: started, session: session) }
            else { mark(.own, id: UUID(), session: session, start: plan.start, end: plan.end) }
        }
        store.recordLast(session)
        return .started
    }

    /// The session's « Surveillance » choice, checked or not: Jev follows it, and the next session starts with it.
    static func mark(_ kind: JevSessionMark.Kind, id: UUID, surveillance: JevInterventionSettings?, lock: BlockLock,
                     start: Date? = nil, end: Date? = nil) {
        let mark = JevSessionMark(id: id, kind: kind, on: surveillance != nil, start: start, end: end, lock: lock,
                                  settings: surveillance ?? JevSurveillanceStore.shared.document.sessionSettings)
        JevSurveillanceStore.shared.mark(mark, now: GoalongToday.now, alive: JevMonitor.aliveSessions())
    }

    private static func mark(_ kind: JevSessionMark.Kind, id: UUID, session: PreparedSession, start: Date? = nil, end: Date? = nil) {
        mark(kind, id: id, surveillance: session.surveillance, lock: session.lock, start: start, end: end)
    }
}

/// The prepared sessions in « Séances », with « Relancer la dernière séance » and its shortcut.
@MainActor struct PreparedSessionsList: View {
    @ObservedObject var store: PreparedSessionStore
    let lists: [BlockList]
    let launch: (PreparedSession) -> PreparedSessionLauncher.Outcome
    let onOpen: (PreparedSession) -> Void

    private var names: [UUID: String] { Dictionary(lists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    /// Nothing saved, nothing relaunched: no view at all, so the section keeps its spacing.
    private var isEmpty: Bool { store.error == nil && store.document.last == nil && store.document.sessions.isEmpty }

    var body: some View {
        if !isEmpty { rows }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = store.error {
                GoalongNote(error, tone: .warning).accessibilityIdentifier("blocages-prepared-error")
            }
            if let last = store.document.last {
                HStack(spacing: 10) {
                    Button { run(last) } label: { Label("Relancer la dernière séance", systemImage: "arrow.clockwise") }
                        .buttonStyle(LHSecondaryButtonStyle())
                        .accessibilityIdentifier("blocages-relaunch")
                    Text(last.summary(listNames: names)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    GoalongMenuPicker("Raccourci", selection: Binding(get: { store.document.shortcut }, set: store.setShortcut),
                                      options: RelaunchShortcut.allCases.map { ($0, $0 == .none ? "Sans raccourci" : $0.title) })
                        .fixedSize()
                        .accessibilityIdentifier("blocages-relaunch-shortcut")
                }
            }
            ForEach(store.document.sessions) { session in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name).font(.system(size: 13, weight: .medium))
                        Text(session.summary(listNames: names)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Button("Modifier…") { onOpen(session) }.buttonStyle(LHQuietButtonStyle())
                        .accessibilityIdentifier("blocages-prepared-edit")
                    Button("Lancer") { run(session) }.buttonStyle(LHSecondaryButtonStyle())
                        .accessibilityIdentifier("blocages-prepared-launch")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("blocages-prepared-\(session.id.uuidString)")
            }
        }
    }

    private func run(_ session: PreparedSession) {
        if launch(session) == .needsEditor { onOpen(session) }
    }
}
#endif
