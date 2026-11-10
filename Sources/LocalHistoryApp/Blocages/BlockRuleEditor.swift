#if os(macOS)
import AppKit
import SwiftUI

/// Observes an object that may be absent (a module that is off): the content is drawn again on each of its
/// changes, and still draws without it.
struct ObservedOptional<Object: ObservableObject, Content: View>: View {
    let object: Object?
    let content: (Object?) -> Content

    init(object: Object?, @ViewBuilder content: @escaping (Object?) -> Content) {
        self.object = object
        self.content = content
    }

    var body: some View {
        if let object { Present(object: object, content: content) } else { content(nil) }
    }

    private struct Present: View {
        @ObservedObject var object: Object
        let content: (Object?) -> Content
        var body: some View { content(object) }
    }
}

/// The one editor of « Blocages » (docs/spec-blocages-20261110.md): a rule is a trigger, what it applies and
/// its stop rule. « Maintenant » hands over to the existing composers, « Horaire » writes ranges through
/// `BlockRulePlan`, « Jev » is the existing monitoring form. The engines keep every check and every refusal.
@MainActor struct BlockRuleEditor: View {
    enum Subject: Identifiable {
        case new
        case session(FocusComposerDraft)
        case rule(BlockRule)
        case jev

        var id: String {
            switch self {
            case .new: return "new"
            case .session: return "session"
            case .rule(let rule): return "rule-\(rule.id)"
            case .jev: return "jev"
            }
        }
    }

    enum Trigger: Hashable, CaseIterable {
        case now, schedule, jev
        var title: String {
            switch self {
            case .now: return "Maintenant"
            case .schedule: return "Horaire"
            case .jev: return "Jev"
            }
        }
    }

    static let width: CGFloat = 660
    static let jevTitle = "Quand Jev me voit décrocher"

    let subject: Subject
    var blocking: BlockingController?
    var braise: BraiseController?
    var focus: ConcentrationController?
    /// Fixed in the gallery and the tests; the clock otherwise.
    var now: Date?
    /// The gallery shows the whole form: it replaces the height limit of the sheet.
    var maxHeight: CGFloat?
    var onOpenRecording: () -> Void
    var onOpenWork: () -> Void
    var onPrepareRed: () -> Void
    var onClose: () -> Void

    @State private var trigger: Trigger
    @State private var asSession: Bool
    @State private var sessionDraft: FocusComposerDraft
    @State private var draft: BlockRuleDraft
    @State private var refusal: String?
    @State private var unreadableFields: Set<String> = []
    @State private var confirmingDelete = false

    init(subject: Subject, blocking: BlockingController?, braise: BraiseController?, focus: ConcentrationController?,
         now: Date? = nil, trigger: Trigger? = nil, maxHeight: CGFloat? = nil, sessionDraft: FocusComposerDraft? = nil,
         onOpenRecording: @escaping () -> Void = {},
         onOpenWork: @escaping () -> Void = {}, onPrepareRed: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.subject = subject
        self.blocking = blocking
        self.braise = braise
        self.focus = focus
        self.now = now
        self.maxHeight = maxHeight
        self.onOpenRecording = onOpenRecording
        self.onOpenWork = onOpenWork
        self.onPrepareRed = onPrepareRed
        self.onClose = onClose
        // Nil = the remembered session draft (the app). A render gives a fixed one: it reads no preference.
        var first = Trigger.now, session = false, composer = sessionDraft, rule = BlockRuleDraft()
        switch subject {
        case .new: break
        case .session(let value): session = true; composer = value
        case .rule(let value): first = .schedule; rule = BlockRuleDraft(value)
        case .jev: first = .jev
        }
        _trigger = State(initialValue: trigger ?? first)
        _asSession = State(initialValue: session)
        _sessionDraft = State(initialValue: composer ?? .remembered())
        _draft = State(initialValue: rule)
    }

    private var rule: BlockRule? {
        if case .rule(let rule) = subject { return rule }
        return nil
    }

    private var title: String {
        switch subject {
        case .new, .session: return "Nouvelle règle"
        case .rule: return "Modifier la règle"
        case .jev: return Self.jevTitle
        }
    }

    /// The composer of a block that starts now has its own buttons: the sheet adds no footer then.
    private var showsComposer: Bool { trigger == .now && blocking != nil && !(asSession && focus != nil) }
    private var showsConsent: Bool {
        RedScreenRangeEditor.showsConsent(lock: draft.lock, needed: BlockingRuntime.shared.guardNeedsConsent)
    }
    private var cap: CGFloat { maxHeight ?? min(640, (NSScreen.main?.visibleFrame.height ?? 900) * 0.7) }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in // wall: display tick
            let now = self.now ?? GoalongToday.timeline(context.date)
            ObservedOptional(object: blocking) { _ in
                ObservedOptional(object: braise) { _ in
                    VStack(spacing: 0) {
                        GoalongSheetScroll(cap: cap) {
                            VStack(alignment: .leading, spacing: 20) {
                                Text(title).font(LHTheme.sheetTitleFont).tracking(-0.4).accessibilityAddTraits(.isHeader)
                                whenRow
                                switch trigger {
                                case .now: nowPane(now: now)
                                case .schedule: schedulePane
                                case .jev: jevPane
                                }
                            }
                            .padding(28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        footer
                    }
                }
            }
        }
        .font(.system(size: 13))
        .frame(width: Self.width)
        .background(LHTheme.pageBackground)
        .foregroundStyle(LHTheme.text)
        .onChange(of: trigger) { _ in refusal = nil }
        .alert("Supprimer cette règle ?", isPresented: $confirmingDelete) {
            Button("Supprimer", role: .destructive) { delete() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les listes restent. Seules leurs plages à ces heures sont retirées.")
        }
        // A container: without it the sheet's identifier replaces the ones of the footer buttons.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("block-rule-editor")
    }

    // MARK: Rows

    /// The composer's row (`BlockingNowComposer.row`): the labels of both forms stay on one line.
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 64, height: 32, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func help(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(warning ? LHTheme.warning : LHTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var whenRow: some View {
        switch subject {
        case .new, .session:
            row("Quand") {
                GoalongSegmentedControl("Quand", selection: $trigger, options: Trigger.allCases) { $0.title }
                    .accessibilityIdentifier("block-rule-when")
            }
        case .rule:
            row("Quand") { Text("Horaire").frame(height: 32) }
        case .jev:
            EmptyView()
        }
    }

    private var moduleOff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Les listes de sites et d’apps viennent du module Blocage.").foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Activer Blocage") { GoalongModuleStore.shared.setEnabled(.blocking, true) }
                .buttonStyle(LHSecondaryButtonStyle())
                .accessibilityIdentifier("block-rule-enable-blocking")
        }
        .frame(minHeight: 32, alignment: .leading)
    }

    // MARK: Maintenant

    @ViewBuilder private func nowPane(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if focus != nil {
                row("Séance") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Séance de travail", isOn: $asSession).toggleStyle(.goalongSwitchInline)
                            .frame(minHeight: 32)
                            .accessibilityIdentifier("block-rule-session")
                        help("Une intention, un minuteur ou des Pomodoro. Les listes choisies sont bloquées pendant la séance.")
                    }
                }
            }
            if asSession, let focus {
                BlockRuleSessionPane(controller: focus, now: now, draft: $sessionDraft, onStarted: onClose)
            } else if let blocking {
                BlockingNowComposer(controller: blocking, now: now, bare: true, braise: braise, onCancel: onClose, onDone: onClose)
                if let error = blocking.error {
                    GoalongNote(error, tone: .warning).accessibilityIdentifier("block-rule-error")
                }
            } else {
                row("Quoi") { moduleOff }
            }
        }
    }

    // MARK: Horaire

    private var hoursHint: String {
        if draft.weekdays.isEmpty || draft.startMinute == draft.endMinute {
            return "Choisissez au moins un jour et deux heures différentes."
        }
        return draft.endMinute <= draft.startMinute ? "La plage finit le lendemain à \(BlockingFormat.rangeEnd(draft.endMinute))."
                                                    : "La plage commence et se termine le même jour."
    }

    @ViewBuilder private var schedulePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let rule, rule.lock != .free, case .running = rule.state {
                GoalongNote("Cette règle est en cours et protégée. Un changement qui l’affaiblit est refusé jusqu’à sa fin.",
                            symbol: rule.lock.symbol)
                    .accessibilityIdentifier("block-rule-protected")
            }
            row("Jours") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(BlockingFormat.weekdayShort[day - 1], isOn: Binding(get: { draft.weekdays.contains(day) }, set: { on in
                                if on { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) }
                            })).toggleStyle(.goalongCheckbox)
                        }
                    }
                    .frame(minHeight: 32)
                    GoalongSegmentedControl("Raccourcis de jours",
                                            selection: Binding(get: { BraiseDayPreset(weekdays: draft.weekdays) },
                                                               set: { if let preset = $0 { draft.weekdays = preset.weekdays } }),
                                            options: BraiseDayPreset.allCases.map(Optional.some), title: { $0?.title ?? "" })
                }
            }
            row("Heures") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 24) {
                        time("Début", minute: $draft.startMinute)
                        time("Fin", minute: Binding(get: { draft.endMinute % 1_440 }, set: { draft.endMinute = $0 == 0 ? 1_440 : $0 }))
                    }
                    .frame(minHeight: 32)
                    help(hoursHint)
                }
            }
            row("Quoi") { listsPart }
            row("Écran") { screenPart }
            row("Arrêt") { stopPart }
            if rule != nil, draft.listIDs.isEmpty, draft.hasRedPart {
                row("État") {
                    Toggle("Mettre la règle en pause", isOn: $draft.paused).toggleStyle(.goalongSwitchInline)
                        .frame(minHeight: 32)
                        .accessibilityIdentifier("block-rule-paused")
                }
            }
            if let refusal {
                GoalongNote(refusal, tone: .warning).accessibilityIdentifier("block-rule-refusal")
            }
        }
    }

    private func time(_ title: String, minute: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            Text(title)
            ScheduleTimeField(title: title, minute: minute, onValidity: { valid in
                if valid { unreadableFields.remove(title) } else { unreadableFields.insert(title) }
            })
        }
    }

    @ViewBuilder private var listsPart: some View {
        if let blocking {
            VStack(alignment: .leading, spacing: 6) {
                BlockingFlow(spacing: 8) {
                    ForEach(blocking.lists) { list in
                        BlockingListChip(list: list, selected: draft.listIDs.contains(list.id)) {
                            if draft.listIDs.contains(list.id) { draft.listIDs.remove(list.id) } else { draft.listIDs.insert(list.id) }
                        }
                    }
                    BlockingNewListChip { draft.listIDs.insert($0) }
                }
                .frame(minHeight: 32, alignment: .leading)
                if draft.listIDs.isEmpty, !draft.hasRedPart {
                    help("Choisissez au moins une liste, l’écran rouge ou la luminosité.")
                }
            }
        } else {
            moduleOff
        }
    }

    @ViewBuilder private var screenPart: some View {
        if let braise {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Écran rouge", isOn: $draft.red).toggleStyle(.goalongSwitchInline)
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("block-rule-red")
                if draft.red {
                    level("Rouge à", value: $draft.intensity, in: 0.05...1, spoken: "Intensité du rouge")
                }
                Toggle("Luminosité bloquée", isOn: Binding(get: { draft.brightness != nil }, set: { draft.brightness = $0 ? 0.4 : nil }))
                    .toggleStyle(.goalongSwitchInline)
                    .disabled(draft.brightness == nil && !braise.canControlBrightness)
                    .accessibilityIdentifier("block-rule-brightness")
                if let value = draft.brightness {
                    level("Luminosité à", value: Binding(get: { value }, set: { draft.brightness = $0 }),
                          in: BrightnessLockRules.levelRange, spoken: "Luminosité bloquée")
                } else if !braise.canControlBrightness {
                    help("Aucun écran de ce Mac ne peut être réglé par Goalong.")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("L’écran rouge n’est pas prêt sur ce Mac.").foregroundStyle(LHTheme.secondaryText)
                Button("Préparer l’écran rouge", action: onPrepareRed).buttonStyle(LHSecondaryButtonStyle())
                    .accessibilityIdentifier("block-rule-prepare-red")
            }
            .frame(minHeight: 32, alignment: .leading)
        }
    }

    private func level(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(GoalongUIFormat.percent(value.wrappedValue * 100)).monospacedDigit().foregroundStyle(LHTheme.secondaryText)
            }
            Slider(value: value, in: range).accessibilityLabel(spoken)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) pour cent")
        }
    }

    @ViewBuilder private var stopPart: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let blocking {
                BlockingLockPicker(controller: blocking, lock: $draft.lock)
            } else {
                GoalongSegmentedControl("Arrêt", selection: $draft.lock, options: BlockLock.ordered.filter { $0 != .password }) { $0.title }
                BlockingLockExplainer(lock: draft.lock)
            }
            if showsConsent {
                help(GuardConsent.text).accessibilityIdentifier("block-rule-guard-consent")
            }
        }
    }

    // MARK: Jev

    private var jevPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            help("Jev lit votre activité en direct et vous prévient quand vous quittez le travail décrit. Il prévient seulement : il ne bloque rien.")
            JevMonitoringPage(onOpenRecording: { onClose(); onOpenRecording() }, onOpenWork: { onClose(); onOpenWork() },
                              embedded: true)
            row("Arrêt") {
                BlockingLockExplainer(lock: .free, text: "Vous arrêtez Jev quand vous voulez, ici ou depuis le menu Goalong.")
                    .frame(minHeight: 32)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch trigger {
        case .schedule:
            GoalongSheetFooter(inset: 28) {
                if rule != nil {
                    Button("Supprimer la règle", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(LHQuietButtonStyle())
                        .accessibilityIdentifier("block-rule-delete")
                }
                Spacer()
                Button("Annuler", action: onClose).buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save() }
                    .buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(draft.problem != nil || !unreadableFields.isEmpty)
                    .accessibilityIdentifier("block-rule-save")
            }
        case .jev:
            GoalongSheetFooter(inset: 28) {
                Spacer()
                Button("Fermer", action: onClose).buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("block-rule-close")
            }
        case .now:
            if !showsComposer {
                GoalongSheetFooter(inset: 28) {
                    Spacer()
                    Button("Annuler", action: onClose).buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    // MARK: Writes

    /// Both engines check before either writes (`BlockRulePlan.apply`); a refusal leaves the sheet open.
    private func save() {
        let consent = showsConsent
        let writes = BlockRulePlan.writes(draft, replacing: rule, lists: blocking?.lists ?? [], red: braise?.ranges)
        if let refusal = BlockRulePlan.apply(writes, blocking: blocking, braise: braise) {
            self.refusal = refusal
            return
        }
        // The consent is recorded only where its text was shown (T-048 B6).
        if consent { BlockingRuntime.shared.recordGuardConsent() }
        onClose()
    }

    private func delete() {
        guard let rule else { return }
        let writes = BlockRulePlan.writes(nil, replacing: rule, lists: blocking?.lists ?? [], red: braise?.ranges)
        if let refusal = BlockRulePlan.apply(writes, blocking: blocking, braise: braise) {
            self.refusal = refusal
            return
        }
        onClose()
    }
}

/// « Séance de travail » inside the editor: the composer of Concentration, unchanged. The sheet closes when
/// the session starts.
@MainActor private struct BlockRuleSessionPane: View {
    @ObservedObject var controller: ConcentrationController
    let now: Date
    @Binding var draft: FocusComposerDraft
    var onStarted: () -> Void
    @ObservedObject private var modules = GoalongModuleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controller.currentSession != nil {
                GoalongNote("Une séance est déjà en cours. Terminez-la pour en lancer une autre.")
                    .accessibilityIdentifier("block-rule-session-running")
            } else {
                FocusComposer(controller: controller, now: now, draft: $draft, blockingEnabled: modules.isEnabled(.blocking))
            }
            if let error = controller.error {
                GoalongNote(FocusUIError.message(raw: error), tone: .warning).accessibilityIdentifier("block-rule-session-error")
            }
        }
        .onChange(of: controller.currentSession?.id) { id in if id != nil { onStarted() } }
    }
}
#endif
