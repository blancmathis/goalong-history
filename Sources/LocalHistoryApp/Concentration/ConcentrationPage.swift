#if os(macOS)
import AppKit
import SwiftUI

/// The module on one page: the session (start one, or the one running), today's plan, the
/// engagements of the day and the week, today's sessions, then the settings, folded.
@MainActor struct ConcentrationPage: View {
    @ObservedObject private var runtime = ConcentrationRuntime.shared

    var body: some View {
        if let controller = runtime.controller {
            ConcentrationPageContent(controller: controller)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Concentration").goalongPageTitle()
                Text(runtime.error == nil ? "Le module est désactivé. Activez-le dans Réglages › Modules."
                                          : "Concentration n’a pas pu démarrer. Vos données restent intactes.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            }
            .padding(.horizontal, LHTheme.pageInset).padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LHTheme.pageBackground)
        }
    }
}

@MainActor struct ConcentrationPageContent: View {
    @ObservedObject var controller: ConcentrationController
    /// Renders and tests pin the clock and the measures; the app follows the controller.
    var now: Date?
    var measures: [FocusItemMeasure]?
    @ObservedObject private var modules = GoalongModuleStore.shared
    @State private var draft: FocusComposerDraft
    @State private var reviewing = false
    @State private var editingCommitment: FocusCommitmentEditRequest?
    @State private var settingsOpen: Bool
    @FocusState private var addFocused: Bool

    init(controller: ConcentrationController, now: Date? = nil, measures: [FocusItemMeasure]? = nil,
         draft: FocusComposerDraft = .remembered(), settingsOpen: Bool = false) {
        self.controller = controller
        self.now = now
        self.measures = measures
        _draft = State(initialValue: draft)
        _settingsOpen = State(initialValue: settingsOpen)
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            let now = self.now ?? context.date
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
                        header
                        if let session = controller.currentSession {
                            FocusActiveSession(controller: controller, session: session, now: now, live: self.now == nil)
                        } else {
                            FocusComposer(controller: controller, now: now, draft: $draft,
                                          blockingEnabled: modules.isEnabled(.blocking))
                        }
                        if let error = controller.error {
                            GoalongNote(FocusUIError.message(raw: error), tone: .warning)
                                .onTapGesture { controller.error = nil }
                                .accessibilityIdentifier("concentration-error")
                        }
                        FocusPlanSection(controller: controller, now: now, measures: measures ?? controller.itemMeasures,
                                         draft: $draft, addFocused: $addFocused, onReview: { reviewing = true })
                            .id("plan")
                        FocusCommitmentsSection(controller: controller, now: now, onEdit: { editingCommitment = $0 })
                        FocusSessionsSection(controller: controller, now: now)
                        FocusSettingsSection(controller: controller, open: $settingsOpen)
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
                    .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onAppear { openRequestedEditor(controller.requestedEditor, proxy: proxy) }
                .onChange(of: controller.requestedEditor) { kind in openRequestedEditor(kind, proxy: proxy) }
            }
        }
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("concentration-page")
        .sheet(isPresented: $reviewing) {
            ConcentrationReviewSheet(controller: controller, plan: controller.plan, review: controller.review,
                                     onClose: { reviewing = false })
                .goalongControls()
        }
        .sheet(item: $editingCommitment) { request in
            FocusCommitmentEditor(controller: controller, request: request, now: Date(), onClose: { editingCommitment = nil })
                .goalongControls()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Concentration").goalongPageTitle()
                Text("Une chose à la fois. Goalong garde le temps et la mesure.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            }
            Spacer(minLength: 12)
            FocusStatusLabel(status: controller.status)
        }
    }

    /// « Faire maintenant » from a prompt: the morning goes to the plan, the evening opens the review.
    private func openRequestedEditor(_ kind: FocusPanel.Kind?, proxy: ScrollViewProxy) {
        guard let kind else { return }
        if kind == .evening {
            reviewing = true
        } else {
            proxy.scrollTo("plan", anchor: .top)
            addFocused = true
        }
        controller.dismissEditor()
    }
}

// MARK: - Status

/// The live state a desk light would mirror: a mark, then the word.
struct FocusStatusLabel: View {
    let status: FocusStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(words).font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
        }
        .help("Statut de concentration : le même que `goalong focus status`.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("concentration-status")
    }

    private var words: String {
        switch status.state {
        case "focus": return status.source == "detected" ? "Concentré, détecté" : "Concentré"
        case "break": return "En pause"
        case "active": return "Actif"
        case "away": return "Absent"
        default: return "Non observé"
        }
    }

    private var color: Color {
        switch status.state {
        case "focus": return LHTheme.accent
        case "break", "active": return LHTheme.text.opacity(0.55)
        default: return LHTheme.text.opacity(0.22)
        }
    }
}

// MARK: - Composer

/// What the next session will be. Kept between visits to the page: the rhythm is remembered,
/// the intention is not.
struct FocusComposerDraft: Equatable {
    enum Free: Hashable { case minutes(Int), open, custom }
    enum Rhythm: Hashable { case classic, long, custom }

    var intent = ""
    var planItemId: UUID?
    var kind: FocusMode.Kind = .free
    var free: Free = .minutes(50)
    var customMinutes = 45
    var rhythm: Rhythm = .classic
    var work = 25, shortBreak = 5, longBreak = 15, every = 4
    var cycles: Int?
    var blockListIds: Set<UUID> = []
    var blockDuringBreaks = false
    var lock = false

    var mode: FocusMode {
        var mode = FocusMode()
        mode.kind = kind
        switch free {
        case .minutes(let value): mode.minutes = value
        case .open: mode.minutes = nil
        case .custom: mode.minutes = customMinutes
        }
        switch rhythm {
        case .classic: (mode.workMinutes, mode.shortBreakMinutes, mode.longBreakMinutes, mode.longBreakEvery) = (25, 5, 15, 4)
        case .long: (mode.workMinutes, mode.shortBreakMinutes, mode.longBreakMinutes, mode.longBreakEvery) = (50, 10, 20, 3)
        case .custom: (mode.workMinutes, mode.shortBreakMinutes, mode.longBreakMinutes, mode.longBreakEvery) = (work, shortBreak, longBreak, every)
        }
        mode.cycles = kind == .pomodoro ? cycles : nil
        return mode
    }

    /// A free session without an end cannot be locked (Blocking needs an end).
    var canLock: Bool { !(kind == .free && free == .open) }

    private static let key = "goalong.concentration.composer.v1"

    static func remembered(_ defaults: UserDefaults = .standard) -> FocusComposerDraft {
        var draft = FocusComposerDraft()
        guard let values = defaults.dictionary(forKey: key) as? [String: Int] else { return draft }
        draft.kind = values["pomodoro"] == 1 ? .pomodoro : .free
        switch values["free"] {
        case -1: draft.free = .open
        case -2: draft.free = .custom
        case let value? where [25, 50, 90].contains(value): draft.free = .minutes(value)
        default: break
        }
        draft.customMinutes = values["customMinutes"].map { min(240, max(5, $0)) } ?? 45
        draft.rhythm = values["rhythm"] == 1 ? .long : values["rhythm"] == 2 ? .custom : .classic
        draft.work = values["work"].map { min(120, max(5, $0)) } ?? 25
        draft.shortBreak = values["short"].map { min(30, max(1, $0)) } ?? 5
        draft.longBreak = values["long"].map { min(60, max(5, $0)) } ?? 15
        draft.every = values["every"].map { min(8, max(2, $0)) } ?? 4
        draft.cycles = values["cycles"].flatMap { (1...16).contains($0) ? $0 : nil }
        return draft
    }

    func remember(_ defaults: UserDefaults = .standard) {
        var values = ["pomodoro": kind == .pomodoro ? 1 : 0, "customMinutes": customMinutes,
                      "rhythm": rhythm == .classic ? 0 : rhythm == .long ? 1 : 2,
                      "work": work, "short": shortBreak, "long": longBreak, "every": every]
        switch free {
        case .minutes(let value): values["free"] = value
        case .open: values["free"] = -1
        case .custom: values["free"] = -2
        }
        if let cycles { values["cycles"] = cycles }
        defaults.set(values, forKey: Self.key)
    }
}

@MainActor struct FocusComposer: View {
    @ObservedObject var controller: ConcentrationController
    let now: Date
    @Binding var draft: FocusComposerDraft
    var blockingEnabled: Bool
    @State private var confirmingLock = false

    private var openItems: [FocusPlanItem] { controller.plan.items.filter { $0.status == .open } }
    private var lists: [BlockList] { blockingEnabled ? controller.blockLists : [] }
    private var chosenLists: [UUID] { lists.map(\.id).filter(draft.blockListIds.contains) }
    private var preview: FocusThreadModel { FocusThreadModel.preview(mode: draft.mode, at: now) }
    private var plannedEnd: Date? {
        var session = FocusSession(intent: "·", mode: draft.mode, startedAt: now, events: [.init(kind: .start, at: now)])
        session.plannedEndAt = nil
        return FocusPhases.plannedEnd(session)
    }
    private var intent: String { draft.intent.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Je fais…", text: $draft.intent)
                        .textFieldStyle(GoalongFieldStyle())
                        .font(.system(size: 17, weight: .medium))
                        .onSubmit { if !intent.isEmpty { begin() } }
                        .accessibilityLabel("Ce que vous faites pendant la séance")
                        .accessibilityIdentifier("concentration-intent")
                    if !openItems.isEmpty {
                        BlockingFlow(spacing: 6) {
                            ForEach(openItems) { item in
                                FocusPlanChip(title: item.title, selected: draft.planItemId == item.id) {
                                    if draft.planItemId == item.id { draft.planItemId = nil } else {
                                        draft.planItemId = item.id; draft.intent = item.title
                                    }
                                }
                            }
                        }
                    }
                }
                row("Rythme") {
                    VStack(alignment: .leading, spacing: 12) {
                        GoalongSegmentedControl("Rythme", selection: $draft.kind, options: [.free, .pomodoro]) {
                            $0 == .free ? "Libre" : "Pomodoro"
                        }
                        if draft.kind == .free { freeOptions } else { pomodoroOptions }
                        FocusSessionThread(model: preview, now: nil)
                            .accessibilityLabel(previewDescription)
                    }
                }
                if !lists.isEmpty { blockingRow }
                if let mark = controller.sessionStartLimitWarnings.last {
                    Label(FocusUIFormat.limitLine(mark, settings: controller.settings), systemImage: "flag")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                HStack {
                    Spacer()
                    Button {
                        if draft.lock && draft.canLock && !chosenLists.isEmpty { confirmingLock = true } else { begin() }
                    } label: {
                        Label(startTitle, systemImage: draft.lock && !chosenLists.isEmpty ? "lock.fill" : "play.fill")
                    }
                    .buttonStyle(LHPrimaryButtonStyle())
                    .disabled(intent.isEmpty)
                    .accessibilityIdentifier("concentration-start")
                }
            }
        }
        .alert("Verrouiller chaque phase de travail ?", isPresented: $confirmingLock) {
            Button("Annuler", role: .cancel) {}
            Button("Verrouiller") { begin() }
        } message: {
            Text("Pendant le travail, ni la séance ni le blocage ne pourront être arrêtés ou passés avant la fin de la phase. Quitter Goalong ou redémarrer ne les arrête pas.")
        }
    }

    private var startTitle: String {
        guard let end = plannedEnd else { return "Commencer" }
        return "Commencer · jusqu’à \(BlockingFormat.time(end))"
    }

    private var previewDescription: String {
        let mode = draft.mode
        if mode.kind == .free { return mode.minutes.map { "Une séance de \(BlockingFormat.duration(minutes: $0))" } ?? "Une séance sans fin" }
        return "\(mode.workMinutes) min de travail, \(mode.shortBreakMinutes) min de pause, \(mode.longBreakMinutes) min toutes les \(mode.longBreakEvery) phases"
    }

    private var freeOptions: some View {
        HStack(spacing: 10) {
            GoalongSegmentedControl("Durée", selection: $draft.free,
                                    options: [.minutes(25), .minutes(50), .minutes(90), .open, .custom]) {
                switch $0 {
                case .minutes(let value): return BlockingFormat.duration(minutes: value)
                case .open: return "Sans fin"
                case .custom: return "Autre"
                }
            }
            if draft.free == .custom {
                Stepper(value: $draft.customMinutes, in: 5...240, step: 5) {
                    Text(BlockingFormat.duration(minutes: draft.customMinutes)).monospacedDigit()
                }
                .fixedSize()
            }
        }
    }

    private var pomodoroOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GoalongSegmentedControl("Phases", selection: $draft.rhythm, options: [.classic, .long, .custom]) {
                    switch $0 {
                    case .classic: return "25 / 5"
                    case .long: return "50 / 10"
                    case .custom: return "Autre"
                    }
                }
                GoalongSegmentedControl("Cycles", selection: $draft.cycles, options: [nil, 2, 4, 6]) {
                    $0.map { "\($0) cycles" } ?? "Jusqu’à l’arrêt"
                }
            }
            if draft.rhythm == .custom {
                HStack(spacing: 14) {
                    stepper("Travail", value: $draft.work, range: 5...120, unit: "min")
                    stepper("Pause", value: $draft.shortBreak, range: 1...30, unit: "min")
                    stepper("Longue", value: $draft.longBreak, range: 5...60, unit: "min")
                    stepper("Toutes les", value: $draft.every, range: 2...8, unit: "")
                }
            }
        }
    }

    private var blockingRow: some View {
        row("Bloquer") {
            VStack(alignment: .leading, spacing: 10) {
                BlockingFlow(spacing: 8) {
                    ForEach(lists) { list in
                        BlockingListChip(list: list, selected: draft.blockListIds.contains(list.id)) {
                            if draft.blockListIds.contains(list.id) { draft.blockListIds.remove(list.id) } else { draft.blockListIds.insert(list.id) }
                        }
                    }
                }
                if !chosenLists.isEmpty {
                    HStack(spacing: 18) {
                        if draft.kind == .pomodoro {
                            Toggle("Aussi pendant les pauses", isOn: $draft.blockDuringBreaks).toggleStyle(.goalongCheckbox)
                        }
                        Toggle("Verrouiller", isOn: $draft.lock).toggleStyle(.goalongCheckbox)
                            .disabled(!draft.canLock)
                            .help(draft.canLock ? "Impossible d’arrêter une phase de travail avant sa fin."
                                                : "Une séance sans fin ne peut pas être verrouillée.")
                    }
                    .font(.system(size: 13))
                }
            }
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        Stepper(value: value, in: range) {
            Text("\(title) \(value.wrappedValue)\(unit.isEmpty ? "" : " \(unit)")").monospacedDigit()
        }
        .fixedSize()
    }

    private func begin() {
        guard !intent.isEmpty else { return }
        let ids = chosenLists
        do {
            try controller.startSession(intent: intent, mode: draft.mode, planItemId: draft.planItemId, blockListIds: ids,
                                        blockDuringBreaks: draft.kind == .pomodoro && draft.blockDuringBreaks,
                                        lock: draft.lock && draft.canLock && !ids.isEmpty)
            draft.remember()
            draft.intent = ""; draft.planItemId = nil
        } catch {
            controller.error = FocusUIError.message(error)
        }
    }

    /// The label sits on the centre line of the first row of controls (32 points high).
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 64, height: 32, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A plan item offered as the session's intention: selected = lime outline and a link mark.
struct FocusPlanChip: View {
    let title: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "link" : "plus").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? LHTheme.accent : LHTheme.tertiaryText)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background {
                let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius - 1, style: .continuous)
                shape.fill(selected ? LHTheme.selectionBackground : LHTheme.controlBackground)
                    .overlay(shape.strokeBorder(selected ? LHTheme.accent : LHTheme.controlBorder, lineWidth: selected ? 1.5 : 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Séance liée à cette tâche du plan" : "Faire de cette tâche l’intention de la séance")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Running session

/// The session set on the page: phase, intention, the time left as the one hero figure, then the
/// session drawn as a thread with the present as a lime point.
@MainActor struct FocusActiveSession: View {
    @ObservedObject var controller: ConcentrationController
    let session: FocusSession
    let now: Date
    var live = true

    private var phase: FocusPhase { controller.phase ?? FocusPhases.phase(session, at: now) }
    private var locked: Bool { controller.hasLockedBlock }
    private var lists: [BlockList] { session.blockListIds.compactMap { id in controller.blockLists.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                phaseLine
                Text(session.intent).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("concentration-current-intent")
            }
            Group {
                if live {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in clock(at: context.date) }
                } else {
                    clock(at: now)
                }
            }
            FocusSessionThread(model: FocusThreadModel.make(session, now: now), now: now, locked: locked)
            HStack(alignment: .center, spacing: 12) {
                if !lists.isEmpty {
                    BlockingIconCluster(lists: lists, size: 20, limit: 6)
                    Text(blockingWords).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 12)
                if locked {
                    Label("Verrouillé jusqu’à \(phase.endsAt.map(BlockingFormat.time) ?? "la fin")", systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                } else {
                    if session.mode.kind == .pomodoro {
                        Button(phase.isWork ? "Passer à la pause" : "Reprendre le travail") { act { try controller.skipPhase() } }
                            .accessibilityIdentifier("concentration-skip")
                    }
                    Button("Arrêter") { act { try controller.stopSession() } }
                        .accessibilityIdentifier("concentration-stop")
                }
            }
        }
        .accessibilityIdentifier("concentration-session")
    }

    private var phaseLine: some View {
        let symbol: String, words: String
        switch (session.mode.kind, phase.kind) {
        case (.free, _):
            symbol = "scope"
            words = phase.endsAt.map { "Séance libre · jusqu’à \(BlockingFormat.time($0))" } ?? "Séance libre, sans fin"
        case (_, .work):
            symbol = "scope"
            words = "Travail · cycle \(phase.cycle)\(session.mode.cycles.map { " sur \($0)" } ?? "")"
        case (_, .longBreak):
            symbol = "cup.and.saucer"; words = "Pause longue · jusqu’à \(phase.endsAt.map(BlockingFormat.time) ?? "")"
        default:
            symbol = "cup.and.saucer"; words = "Pause · jusqu’à \(phase.endsAt.map(BlockingFormat.time) ?? "")"
        }
        return Label(words, systemImage: locked ? "lock.fill" : symbol)
            .font(.system(size: 13, weight: .medium))
            .accessibilityIdentifier("concentration-phase")
    }

    @ViewBuilder private func clock(at date: Date) -> some View {
        if let end = phase.endsAt {
            Text(FocusUIFormat.clock(end.timeIntervalSince(date)))
                .font(LHTheme.heroFont.monospacedDigit()).tracking(LHTheme.heroTracking)
                .accessibilityLabel("Encore \(BlockingFormat.remaining(end.timeIntervalSince(date)))")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(FocusUIFormat.clock(date.timeIntervalSince(session.startedAt)))
                    .font(LHTheme.heroFont.monospacedDigit()).tracking(LHTheme.heroTracking)
                Text("écoulées").font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var blockingWords: String {
        let names = lists.map(\.name).joined(separator: ", ")
        if !phase.isWork && !session.blockDuringBreaks { return "\(names) : libre pendant la pause" }
        return lists.allSatisfy { $0.effectiveAction == .slowDown } ? "\(names) : ralenti" : "\(names) : bloqué"
    }

    private func act(_ action: () throws -> Void) {
        do { try action() } catch { controller.error = FocusUIError.message(error) }
    }
}

/// A session drawn as the app's thread: work phases are thick, breaks are the bare line, what has
/// passed is ink, what remains is quieter, and the present is the lime point. A session without
/// an end trails off in dots.
struct FocusSessionThread: View {
    let model: FocusThreadModel
    /// `nil` draws a preview: no present, every phase to come.
    var now: Date?
    var locked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                let total = model.end.timeIntervalSince(model.start)
                guard total > 0, size.width > 0 else { return }
                func x(_ date: Date) -> CGFloat {
                    CGFloat(min(1, max(0, date.timeIntervalSince(model.start) / total))) * size.width
                }
                let mid = size.height / 2
                let drawnEnd = model.openEnded ? x(model.segments.last?.end ?? model.start) : size.width
                var line = Path()
                line.move(to: CGPoint(x: 0, y: mid)); line.addLine(to: CGPoint(x: drawnEnd, y: mid))
                context.stroke(line, with: .color(LHTheme.text.opacity(0.3)), lineWidth: 1)
                if model.openEnded {
                    var tail = Path()
                    tail.move(to: CGPoint(x: drawnEnd, y: mid)); tail.addLine(to: CGPoint(x: size.width, y: mid))
                    context.stroke(tail, with: .color(LHTheme.text.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                for segment in model.segments where segment.work {
                    var a = x(segment.start)
                    // A sliver left of the point reads as a stray half-moon: start the capsule at the point.
                    if let now, x(now) > a, x(now) - a < 15 { a = x(now) }
                    let b = max(a + 8, x(segment.end))
                    let capsule = Path(roundedRect: CGRect(x: a, y: mid - 4, width: b - a, height: 8), cornerRadius: 4)
                    guard let now else {
                        context.fill(capsule, with: .color(LHTheme.text.opacity(0.55))); continue
                    }
                    context.fill(capsule, with: .color(LHTheme.text.opacity(0.18)))
                    let split = min(b, max(a, x(now)))
                    if split > a {
                        context.drawLayer { layer in
                            layer.clip(to: Path(CGRect(x: 0, y: 0, width: split, height: size.height)))
                            layer.fill(capsule, with: .color(LHTheme.text))
                        }
                    }
                }
                if let now {
                    let point = CGPoint(x: min(max(9, x(now)), size.width - 9), y: mid)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)),
                                 with: .color(LHTheme.pageBackground))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                                 with: .color(LHTheme.accent))
                }
            }
            .frame(height: 18)
            HStack {
                Text(BlockingFormat.time(model.start))
                Spacer()
                if locked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)) }
                Text(model.openEnded ? "sans fin" : BlockingFormat.time(model.end))
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(LHTheme.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.openEnded ? "Depuis \(BlockingFormat.time(model.start)), sans fin"
                                            : "De \(BlockingFormat.time(model.start)) à \(BlockingFormat.time(model.end))")
    }
}

/// The phases of a session laid on a time axis. Phases are recomputed from the mode and the
/// events, never stored.
struct FocusThreadModel: Equatable {
    struct Segment: Equatable { var work: Bool; var start: Date; var end: Date }
    var segments: [Segment]
    var start: Date
    var end: Date
    var openEnded: Bool

    static func preview(mode: FocusMode, at now: Date) -> FocusThreadModel {
        if mode.kind == .free, mode.minutes == nil {
            return FocusThreadModel(segments: [], start: now, end: now.addingTimeInterval(3_600), openEnded: true)
        }
        let session = FocusSession(intent: "·", mode: mode, startedAt: now, events: [.init(kind: .start, at: now)])
        return make(session, now: now)
    }

    static func make(_ session: FocusSession, now: Date) -> FocusThreadModel {
        let start = session.startedAt
        if session.mode.kind == .free {
            if let end = FocusPhases.plannedEnd(session) {
                return FocusThreadModel(segments: [Segment(work: true, start: start, end: end)], start: start, end: end, openEnded: false)
            }
            let lead = max(now, start.addingTimeInterval(60))
            let tail = max(15 * 60, lead.timeIntervalSince(start) * 0.25)
            return FocusThreadModel(segments: [Segment(work: true, start: start, end: lead)], start: start,
                                    end: lead.addingTimeInterval(tail), openEnded: true)
        }
        let horizon = session.mode.cycles == nil ? nil : FocusPhases.plannedEnd(session)
        var segments: [Segment] = []
        var cursor = start
        for _ in 0..<48 {
            let phase = FocusPhases.phase(session, at: cursor.addingTimeInterval(0.5))
            guard phase.kind != .ended, let end = phase.endsAt else { break }
            if segments.last?.start != phase.startedAt {
                if var last = segments.popLast() { last.end = min(last.end, phase.startedAt); segments.append(last) }
                segments.append(Segment(work: phase.isWork, start: phase.startedAt, end: end))
            }
            cursor = end
            if let horizon, end >= horizon { break }
            if horizon == nil, phase.kind == .longBreak, phase.startedAt > now { break }
        }
        if segments.count > 16 { segments = Array(segments.suffix(16)) }
        let first = segments.first?.start ?? start
        let open = session.mode.cycles == nil
        let last = segments.last?.end ?? now
        return FocusThreadModel(segments: segments, start: first,
                                end: open ? last.addingTimeInterval(Double(session.mode.workMinutes * 60) * 0.6) : last,
                                openEnded: open)
    }
}

// MARK: - Plan

@MainActor struct FocusPlanSection: View {
    @ObservedObject var controller: ConcentrationController
    let now: Date
    let measures: [FocusItemMeasure]
    @Binding var draft: FocusComposerDraft
    var addFocused: FocusState<Bool>.Binding
    var onReview: () -> Void
    @State private var newTitle = ""
    @State private var newProject = ""
    @State private var newEstimate = ""
    @State private var addError: String?
    @State private var editingIntention = false
    @State private var intention = ""

    private var plan: FocusPlan { controller.plan }

    var body: some View {
        GoalongSection(title: "Plan du jour", subtitle: subtitle) {
            if !plan.items.isEmpty {
                Button(controller.review == nil ? "Faire le bilan" : "Modifier le bilan", action: onReview)
                    .buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("concentration-open-review")
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if plan.items.isEmpty {
                    Text("Une à dix tâches, écrites par vous. Goalong mesure le temps passé sur chacune.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                }
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        if !plan.items.isEmpty {
                            intentionRow
                            GoalongRowDivider(inset: LHTheme.cardInset)
                        }
                        ForEach(plan.items) { item in
                            itemRow(item)
                            GoalongRowDivider(inset: LHTheme.cardInset + 30)
                        }
                        addRow
                    }
                }
                if let review = controller.review {
                    Label(reviewLine(review), systemImage: "moon")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
            }
        }
    }

    private var subtitle: String? {
        guard !plan.items.isEmpty else { return nil }
        let done = plan.items.filter { $0.status == .done }.count
        return "\(done) sur \(plan.items.count) faites."
    }

    @ViewBuilder private var intentionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.quote").font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 20).accessibilityHidden(true)
            if editingIntention {
                TextField("L’important aujourd’hui", text: $intention)
                    .textFieldStyle(GoalongFieldStyle())
                    .onSubmit(saveIntention)
                Button("Enregistrer", action: saveIntention)
            } else if let value = plan.intention, !value.isEmpty {
                Text(value).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Spacer(minLength: 8)
                Button("Modifier") { intention = value; editingIntention = true }.buttonStyle(LHQuietButtonStyle())
            } else {
                Button("Ajouter une intention du jour") { intention = ""; editingIntention = true }
                    .buttonStyle(LHQuietButtonStyle())
                Spacer()
            }
        }
        .padding(.horizontal, LHTheme.cardInset).frame(minHeight: 48)
    }

    private func itemRow(_ item: FocusPlanItem) -> some View {
        let done = item.status == .done, closed = item.status != .open
        let running = controller.currentSession?.planItemId == item.id
        return HStack(spacing: 10) {
            // No label in the style: a hidden one still takes its height, one letter per line.
            Toggle(isOn: Binding(get: { done }, set: { setDone(item, $0) })) { EmptyView() }
                .toggleStyle(.goalongCheckbox)
                .accessibilityLabel(item.title)
                .disabled(item.status == .moved)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .strikethrough(done, color: LHTheme.tertiaryText)
                    .foregroundStyle(closed ? LHTheme.secondaryText : LHTheme.text)
                if let meta = meta(item, running: running) {
                    Text(meta).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            measure(item)
            if item.status == .open, controller.currentSession == nil {
                Button {
                    draft.planItemId = item.id; draft.intent = item.title
                } label: {
                    Image(systemName: "scope").font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("En faire l’intention de la prochaine séance")
                .accessibilityLabel("Préparer une séance sur \(item.title)")
            }
            Menu {
                if item.status == .open {
                    Button("Déplacer à demain") { act { try controller.movePlanItem(item.id, day: plan.day, to: tomorrow) } }
                    Button("Abandonner") { act { try controller.setItemStatus(item.id, day: plan.day, status: .dropped) } }
                } else if item.status != .moved {
                    Button("Rouvrir") { reopen(item) }
                }
                Divider()
                Button("Retirer du plan", role: .destructive) { remove(item) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(LHTheme.secondaryText)
            .accessibilityLabel("Actions pour \(item.title)")
        }
        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 8).frame(minHeight: 52)
        .accessibilityIdentifier("concentration-plan-item")
    }

    private func meta(_ item: FocusPlanItem, running: Bool) -> String? {
        var parts: [String] = []
        if running { parts.append("en cours") }
        if let project = item.project { parts.append(project) }
        switch item.status {
        case .moved: parts.append(item.toDay == tomorrow ? "déplacée à demain" : "déplacée au \(item.toDay ?? "")")
        case .dropped: parts.append("abandonnée")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func measure(_ item: FocusPlanItem) -> some View {
        let value = measures.first { $0.id == item.id }
        let measured = value?.measuredMinutes ?? value.map(\.sessionMinutes)
        if let estimate = item.estimateMinutes {
            VStack(alignment: .trailing, spacing: 4) {
                Text(measured.map { "mesuré \(Int($0.rounded())) · prévu \(estimate) min" } ?? "prévu \(estimate) min")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                if let measured {
                    BlockingMeter(fraction: measured / Double(estimate)).frame(width: 120)
                }
            }
            .help(value?.measuredMinutes == nil && measured != nil ? "Temps de séance seulement : la mesure du projet est indisponible." : "")
        } else if let measured, measured >= 1 {
            Text("mesuré \(Int(measured.rounded())) min").font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 20).accessibilityHidden(true)
                TextField(plan.items.isEmpty ? "Première tâche du jour" : "Ajouter une tâche", text: $newTitle)
                    .textFieldStyle(GoalongFieldStyle())
                    .focused(addFocused)
                    .onSubmit(add)
                    .accessibilityIdentifier("concentration-add-item")
                TextField("Projet", text: $newProject)
                    .textFieldStyle(GoalongFieldStyle()).frame(width: 120)
                    .onSubmit(add)
                    .help("Facultatif. Relié par son nom à une tâche de « Mon travail » pour mesurer le temps.")
                TextField("min", text: $newEstimate)
                    .textFieldStyle(GoalongFieldStyle()).frame(width: 64)
                    .onSubmit(add)
                    .help("Estimation, facultative : de 5 à 600 minutes.")
                    .accessibilityLabel("Estimation en minutes")
                if let ratio = controller.estimateRatio {
                    Text("×\(FocusUIFormat.decimal(ratio))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                        .help("Vos estimations : ×\(FocusUIFormat.decimal(ratio)). Médiane du temps mesuré sur le temps prévu, sur vos 20 dernières tâches estimées.")
                }
                Button("Ajouter", action: add)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || plan.items.count >= 10)
            }
            if let addError {
                Text(addError).font(.system(size: 12)).foregroundStyle(LHTheme.warning).padding(.leading, 28)
            } else if plan.items.count >= 10 {
                Text("Le plan compte déjà dix tâches.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).padding(.leading, 28)
            }
        }
        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 12)
    }

    private var tomorrow: String {
        BlockingController.dayKey(Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now)
    }

    private func reviewLine(_ review: FocusReview) -> String {
        if let first = review.tomorrowFirst, !first.isEmpty { return "Bilan fait. Demain, vous commencez par « \(first) »." }
        return "Bilan du jour fait."
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var estimate: Int?
        let rawEstimate = newEstimate.trimmingCharacters(in: .whitespaces)
        if !rawEstimate.isEmpty {
            guard let value = Int(rawEstimate), (5...600).contains(value) else {
                addError = "L’estimation va de 5 à 600 minutes."; return
            }
            estimate = value
        }
        let project = newProject.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try controller.addPlanItem(title: title, day: plan.day, project: project.isEmpty ? nil : project, estimateMinutes: estimate)
            newTitle = ""; newProject = ""; newEstimate = ""; addError = nil
        } catch {
            addError = FocusUIError.message(error)
        }
    }

    private func setDone(_ item: FocusPlanItem, _ done: Bool) {
        if done { act { try controller.setItemStatus(item.id, day: plan.day, status: .done) } } else { reopen(item) }
    }

    private func reopen(_ item: FocusPlanItem) {
        var next = plan
        guard let index = next.items.firstIndex(where: { $0.id == item.id }) else { return }
        next.items[index].status = .open; next.items[index].toDay = nil
        act { try controller.setPlan(next) }
    }

    private func remove(_ item: FocusPlanItem) {
        var next = plan
        next.items.removeAll { $0.id == item.id }
        // A plan file needs at least one item: removing the last one keeps an emptied intention-free plan out.
        guard !next.items.isEmpty else { addError = "Le plan garde au moins une tâche. Abandonnez-la plutôt."; return }
        act { try controller.setPlan(next) }
    }

    private func saveIntention() {
        var next = plan
        let value = intention.trimmingCharacters(in: .whitespacesAndNewlines)
        next.intention = value.isEmpty ? nil : String(value.prefix(140))
        act { try controller.setPlan(next) }
        editingIntention = false
    }

    private func act(_ action: () throws -> Void) {
        do { try action() } catch { controller.error = FocusUIError.message(error) }
    }
}

// MARK: - Sessions of the day

@MainActor struct FocusSessionsSection: View {
    @ObservedObject var controller: ConcentrationController
    let now: Date

    private var finished: [FocusSession] { controller.sessions.filter { $0.endedAt != nil }.sorted { $0.startedAt < $1.startedAt } }

    var body: some View {
        if !finished.isEmpty {
            GoalongSection(title: "Séances", subtitle: subtitle) {
                VStack(spacing: 0) {
                    ForEach(finished) { session in
                        row(session)
                        if session.id != finished.last?.id { Rectangle().fill(LHTheme.separator).frame(height: 1) }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let seconds = finished.reduce(0.0) { total, session in
            total + FocusMeasurement.workIntervals(session, until: now).reduce(0) { $0 + $1.duration }
        }
        let count = finished.count == 1 ? "1 séance" : "\(finished.count) séances"
        return "\(count) · \(BlockingFormat.duration(minutes: Int((seconds / 60).rounded()))) de phases de travail."
    }

    private func row(_ session: FocusSession) -> some View {
        HStack(spacing: 14) {
            Text("\(BlockingFormat.time(session.startedAt))–\(session.endedAt.map(BlockingFormat.time) ?? "")")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.intent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let note = session.note, !note.isEmpty {
                    Text(note).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Menu {
                ForEach([FocusSession.Outcome.done, .partly, .notDone], id: \.self) { outcome in
                    Button(FocusUIFormat.outcome(outcome)) { record(session, outcome) }
                }
                Divider()
                Button("Sans réponse") { record(session, nil) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: FocusUIFormat.outcomeSymbol(session.outcome)).font(.system(size: 11, weight: .semibold))
                    Text(session.outcome.map(FocusUIFormat.outcome) ?? "C’est fait ?")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(session.outcome == nil ? LHTheme.tertiaryText : LHTheme.text)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Résultat de la séance \(session.intent)")
        }
        .frame(minHeight: 44)
    }

    private func record(_ session: FocusSession, _ outcome: FocusSession.Outcome?) {
        do { try controller.recordOutcome(sessionID: session.id, outcome: outcome, note: session.note) }
        catch { controller.error = FocusUIError.message(error) }
    }
}

// MARK: - Settings

@MainActor struct FocusSettingsSection: View {
    @ObservedObject var controller: ConcentrationController
    @Binding var open: Bool
    @State private var daily = ""
    @State private var weekly = ""
    @State private var end = ""
    @State private var limitError: String?

    var body: some View {
        GoalongDisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 20) {
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        switchRow("Détecter la concentration",
                                  detail: "Hors séance, le statut passe à « concentré » après 16 minutes actives sur 20, sans « hors travail » devant.",
                                  isOn: setting(\.detectionEnabled))
                        GoalongRowDivider(inset: LHTheme.cardInset)
                        switchRow("Son au changement de phase", detail: nil, isOn: setting(\.phaseSound))
                        GoalongRowDivider(inset: LHTheme.cardInset)
                        promptRow("Plan du matin", detail: "À la première activité après cette heure, si le plan est vide.",
                                  isOn: setting(\.morningPrompt), minute: setting(\.morningMinute))
                        GoalongRowDivider(inset: LHTheme.cardInset)
                        promptRow("Bilan du soir", detail: "À cette heure, si le bilan n’est pas fait. La fin de journée la remplace.",
                                  isOn: setting(\.eveningPrompt), minute: setting(\.eveningMinute))
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Limites").font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    LHCard(padding: 0) {
                        VStack(spacing: 0) {
                            limitRow("Travail par jour", detail: nil, text: $daily, placeholder: "—", width: 64)
                            GoalongRowDivider(inset: LHTheme.cardInset)
                            limitRow("Travail par semaine",
                                     detail: "Au-delà d’environ 50 h par semaine, la production par heure baisse (Pencavel, 2014).",
                                     text: $weekly, placeholder: "—", width: 64)
                            GoalongRowDivider(inset: LHTheme.cardInset)
                            endRow
                        }
                    }
                    if let limitError {
                        Text(limitError).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                    }
                    Text("Vide = pas de limite. Goalong prévient une fois, sans jamais bloquer le travail. Le travail suit votre définition ; sans définition, le temps actif.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Engagements").font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    LHCard(padding: 0) {
                        HStack(alignment: .center, spacing: 12) {
                            labels("Jokers par mois", "Un joker garde la série et lève l’enjeu d’une période non tenue.")
                            Spacer(minLength: 12)
                            Stepper(value: joker(\.day), in: 0...5) { Text("\(controller.settings.jokerSettings.day) pour les jours").monospacedDigit() }
                                .fixedSize()
                            Stepper(value: joker(\.week), in: 0...2) { Text("\(controller.settings.jokerSettings.week) pour les semaines").monospacedDigit() }
                                .fixedSize()
                        }
                        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 10).frame(minHeight: 52)
                    }
                }
                GoalongNote("Tout se pilote aussi avec la commande goalong : session, plan, review, commitment, focus watch. Voir la page Terminal.",
                            symbol: "terminal")
            }
            .padding(.top, 14)
        } label: {
            Text("Réglages").font(LHTheme.sectionTitleFont).tracking(-0.2)
        }
        .onAppear(perform: load)
        .accessibilityIdentifier("concentration-settings")
    }

    private func load() {
        let limits = controller.settings.limits
        daily = limits.dailyHours.map(String.init) ?? ""
        weekly = limits.weeklyHours.map(String.init) ?? ""
        end = limits.endMinute.map(BlockingFormat.minuteOfDay) ?? ""
    }

    private func setting<T>(_ path: WritableKeyPath<FocusSettings, T>) -> Binding<T> {
        Binding(get: { controller.settings[keyPath: path] }, set: { value in
            var next = controller.settings; next[keyPath: path] = value; save(next)
        })
    }

    private func joker(_ path: WritableKeyPath<FocusJokerSettings, Int>) -> Binding<Int> {
        Binding(get: { controller.settings.jokerSettings[keyPath: path] }, set: { value in
            var next = controller.settings, jokers = next.jokerSettings
            jokers[keyPath: path] = value; next.commitmentJokers = jokers; save(next)
        })
    }

    private func save(_ next: FocusSettings) {
        do { try controller.updateSettings(next); limitError = nil } catch { limitError = FocusUIError.message(error) }
    }

    private func switchRow(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            labels(title, detail)
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).toggleStyle(.goalongSwitchOnly).fixedSize()
        }
        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 10).frame(minHeight: 48)
    }

    private func promptRow(_ title: String, detail: String, isOn: Binding<Bool>, minute: Binding<Int>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            labels(title, detail)
            Spacer(minLength: 12)
            DatePicker(title, selection: Binding(get: { Self.date(minute.wrappedValue) }, set: { minute.wrappedValue = Self.minute($0) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden().fixedSize().disabled(!isOn.wrappedValue)
                .environment(\.locale, Locale(identifier: "fr_FR"))
            Toggle(title, isOn: isOn).toggleStyle(.goalongSwitchOnly).fixedSize()
        }
        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 10).frame(minHeight: 48)
    }

    private func limitRow(_ title: String, detail: String?, text: Binding<String>, placeholder: String, width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            labels(title, detail)
            Spacer(minLength: 12)
            TextField(placeholder, text: text)
                .textFieldStyle(GoalongFieldStyle()).frame(width: width)
                .multilineTextAlignment(.trailing)
                .onSubmit(commitLimits)
                .onChange(of: text.wrappedValue) { _ in commitLimits() }
                .accessibilityLabel("\(title), en heures")
            Text("h").foregroundStyle(LHTheme.secondaryText)
        }
        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 10).frame(minHeight: 48)
    }

    private var endRow: some View {
        let weekdays = controller.settings.limits.weekdays
        return HStack(alignment: .center, spacing: 12) {
            labels("Fin de journée", "Prévient à cette heure, ces jours-là.")
            Spacer(minLength: 12)
            HStack(spacing: 3) {
                ForEach(1...7, id: \.self) { day in
                    let on = weekdays.contains(day)
                    Button {
                        var next = controller.settings
                        if on { next.limits.weekdays.remove(day) } else { next.limits.weekdays.insert(day) }
                        if next.limits.endMinute != nil, next.limits.weekdays.isEmpty { return }
                        save(next)
                    } label: {
                        Text(BlockingFormat.weekdayLetters[day - 1]).font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .foregroundStyle(on ? LHTheme.onAccent : LHTheme.secondaryText)
                            .background(on ? LHTheme.actionBackground : LHTheme.insetBackground,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.settings.limits.endMinute == nil)
                    .accessibilityLabel(BlockingFormat.weekdayShort[day - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .opacity(controller.settings.limits.endMinute == nil ? 0.5 : 1)
            TextField("hh:mm", text: $end)
                .textFieldStyle(GoalongFieldStyle()).frame(width: 72)
                .multilineTextAlignment(.trailing)
                .onSubmit(commitLimits)
                .onChange(of: end) { _ in commitLimits() }
                .accessibilityLabel("Heure de fin de journée")
        }
        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 10).frame(minHeight: 52)
    }

    /// Empty means no limit. A partial entry waits silently; a complete invalid one says why.
    private func commitLimits() {
        var next = controller.settings
        let dailyValue = daily.trimmingCharacters(in: .whitespaces), weeklyValue = weekly.trimmingCharacters(in: .whitespaces)
        if dailyValue.isEmpty { next.limits.dailyHours = nil } else if let value = Int(dailyValue), (2...16).contains(value) {
            next.limits.dailyHours = value
        } else if dailyValue.count >= 2 || Int(dailyValue) == nil { limitError = "Travail par jour : de 2 à 16 h."; return } else { return }
        if weeklyValue.isEmpty { next.limits.weeklyHours = nil } else if let value = Int(weeklyValue), (10...80).contains(value) {
            next.limits.weeklyHours = value
        } else if weeklyValue.count >= 2 || Int(weeklyValue) == nil { limitError = "Travail par semaine : de 10 à 80 h."; return } else { return }
        let endValue = end.trimmingCharacters(in: .whitespaces)
        if endValue.isEmpty { next.limits.endMinute = nil } else if let minute = FocusUIFormat.minute(endValue) {
            next.limits.endMinute = minute
            if next.limits.weekdays.isEmpty { next.limits.weekdays = Set(1...5) }
        } else if endValue.count >= 4 { limitError = "Fin de journée : une heure comme 18:30."; return } else { return }
        guard next != controller.settings else { limitError = nil; return }
        save(next)
    }

    private func labels(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func date(_ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minute(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

// MARK: - Words

enum FocusUIFormat {
    /// « 18:42 », « 1:05:00 ».
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return total >= 3_600 ? String(format: "%d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
                              : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func outcome(_ value: FocusSession.Outcome) -> String {
        switch value {
        case .done: return "Fait"
        case .partly: return "En partie"
        case .notDone: return "Pas fait"
        }
    }

    static func outcomeSymbol(_ value: FocusSession.Outcome?) -> String {
        switch value {
        case .done: return "checkmark"
        case .partly: return "circle.lefthalf.filled"
        case .notDone: return "xmark"
        case nil: return "questionmark"
        }
    }

    /// « 18:30 », « 18h30 », « 18 h », « 1830 ».
    static func minute(_ raw: String) -> Int? {
        let digits = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "h", with: ":")
        let parts = digits.split(separator: ":", omittingEmptySubsequences: false)
        var hour: Int?, minute = 0
        if parts.count == 1, let value = Int(parts[0]) {
            if parts[0].count <= 2 { hour = value } else if parts[0].count == 4 { hour = value / 100; minute = value % 100 }
        } else if parts.count == 2, let h = Int(parts[0]) {
            hour = h; minute = parts[1].isEmpty ? 0 : Int(parts[1]) ?? -1
        }
        guard let hour, (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func limitLine(_ mark: FocusLimitMark, settings: FocusSettings) -> String {
        let what = mark.usesActiveTime ? "d’activité" : "de travail"
        switch mark.kind {
        case "weekly": return "\(settings.limits.weeklyHours ?? 0) h \(what) cette semaine : votre limite est passée."
        case "daily": return "\(settings.limits.dailyHours ?? 0) h \(what) aujourd’hui : votre limite est passée."
        default: return "Votre fin de journée est passée."
        }
    }

    /// « 1re », « 2e », « 3e ».
    static func ordinal(_ value: Int) -> String { value == 1 ? "1re" : "\(value)e" }
}

enum FocusUIError {
    static func message(_ error: Error) -> String {
        if let failure = error as? FocusFailure { return message(raw: failure.rawValue) }
        return "L’action n’a pas abouti."
    }

    /// The controller keeps raw failure names; the page says what they mean.
    static func message(raw: String) -> String {
        switch FocusFailure(rawValue: raw) {
        case .locked: return "Le blocage de cette phase est verrouillé jusqu’à sa fin."
        case .invalidArgument: return "Vérifiez le texte et les durées."
        case .notFound: return "Cet élément n’existe plus."
        case .storageFailed: return "Enregistrement impossible. Les données déjà enregistrées restent intactes."
        case .moduleDisabled: return "Activez Blocage dans Réglages › Modules pour bloquer pendant une séance."
        case .appNotRunning: return "Goalong ne répond pas."
        case nil: return raw.count < 120 && !raw.contains("Error") ? raw : "L’action n’a pas abouti."
        }
    }
}
#endif
