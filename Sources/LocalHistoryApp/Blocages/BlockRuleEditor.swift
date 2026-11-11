#if os(macOS)
import AppKit
import SwiftUI
import LocalHistoryCore

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

/// The one window of « Blocages » (T-050 A1, spec `t050/spec.md`): the same frame for a new rule, a rule, Jev and a
/// session. Three titled boxes, always in this order — « Quand », « Quoi », « Arrêt » — and one footer. A block that
/// the engine cannot do for this « Quand » stays shown, greyed, with a sentence that says why; a stop level a session's
/// engine refuses is hidden (T-050 B2, P4), a rule's stays greyed. The engines
/// keep every check and every refusal: « Toujours » and « Horaires » write ranges through `BlockRulePlan`, a « Séance »
/// starts through `BlockingNowStart` (Continu without an intention) or Concentration (Pomodoro, or an intention).
@MainActor struct BlockRuleEditor: View {
    enum Subject: Identifiable {
        case new
        case session(FocusComposerDraft)
        case rule(BlockRule)
        case jev
        /// A prepared session (T-050 B2), saved or the last one started.
        case prepared(PreparedSession)
        /// A new rule already filled: a template or a copy (T-050 B2b, A1 and A8).
        case preset(BlockRulePreset)

        var id: String {
            switch self {
            case .new: return "new"
            case .session: return "session"
            case .rule(let rule): return "rule-\(rule.id)"
            case .jev: return "jev"
            case .prepared(let session): return "prepared-\(session.id)"
            case .preset(let preset): return "preset-\(preset.id)"
            }
        }
    }

    enum Trigger: Hashable, CaseIterable {
        case always, schedule, session
        var title: String {
            switch self {
            case .always: return "Toujours"
            case .schedule: return "Planifié"
            case .session: return "Séance"
            }
        }
    }

    static let width: CGFloat = 660
    /// The « Jev » sheet keeps only what all rules share (T-050 B1 point 8).
    static let jevTitle = "Réglages de la surveillance"
    static let surveillanceToggle = "Prévenir quand je décroche"
    static let surveillanceHelp = "Un rappel quand une distraction dure, puis un voile sur l’écran si elle continue."
    static let surveillanceSetupReason = "La surveillance demande d’abord la clé de Jev et l’historique local."
    static let alwaysSentence = "Actif tout le temps, jusqu’à ce que vous l’arrêtiez."
    /// Product question raised in T-050: a locked rule without an end would never stop.
    static let alwaysLockedReason = "Une règle « Toujours » verrouillée ne s’arrêterait jamais."
    /// A range typed by hand in « Horaires » with the form of « Toujours » (every day, 00:00 → 24:00) and « Verrouillé ».
    static let hoursAlwaysLockedReason = "Tous les jours, de 00:00 à 24:00, c’est une règle « Toujours » : verrouillée, elle ne s’arrêterait jamais. Changez les heures ou le niveau d’arrêt."
    static let focusLockReason = "Une séance Pomodoro ou avec intention s’arrête librement ou se verrouille, sans autre niveau."
    static let focusScreenReason = "Une séance Pomodoro ou avec intention ne porte pas encore l’écran rouge ni la luminosité."
    static let laterScreenReason = "Un blocage programmé plus tard ne porte pas l’écran rouge ni la luminosité."
    static let freezeScreenReason = "Tout le Mac couvre déjà l’écran."
    static let freezeLockReason = "Tout le Mac est toujours verrouillé."
    static let wholeMacReason = "Tout le Mac ne se bloque que pendant une séance en Continu, sans intention."
    /// A session started without an intention still needs one for Concentration.
    static let defaultIntent = "Séance"

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
    /// Where « Enregistrer pour plus tard » and « Relancer » keep the sessions; renders give their own.
    let preparedStore: PreparedSessionStore

    @State private var trigger: Trigger
    @State private var draft: BlockRuleDraft
    @State private var refusal: String?
    @State private var unreadableFields: Set<String> = []
    @State private var confirmingDelete = false
    // Séance
    @State private var sessionDraft: FocusComposerDraft
    @State private var later = false
    @State private var startAt: Date
    @State private var span: BlockingNowComposer.Span = .minutes(60)
    @State private var until: Date
    @State private var wholeMac = false
    @State private var freezeMode: BlockFreeze.Mode = .shield
    @State private var kept: [BlockAppRule] = []
    @State private var picking = false
    @State private var settingPassword = false
    @State private var confirmingLock = false
    @State private var confirmingFreeze = false
    @State private var confirmingFocusLock = false
    @State private var confirmingJev = false
    // Séance préparée (T-050 B2)
    @State private var naming = false
    @State private var name = ""
    /// The window as it opened: a click outside asks first once it differs.
    private let initial: Snapshot
    @Environment(\.openJevSettings) private var openJevSettings
    /// The plan the open alert promises: a click on it keeps this end (R5-regressions-01).
    @State private var pending: BlockingNowPlan?
    @State private var pendingFreezePromise: BlockingFreezePromise?
    @State private var pendingFreezeAt = GoalongToday.now

    init(subject: Subject, blocking: BlockingController?, braise: BraiseController?, focus: ConcentrationController?,
         now: Date? = nil, trigger: Trigger? = nil, draft startDraft: BlockRuleDraft? = nil, maxHeight: CGFloat? = nil, sessionDraft: FocusComposerDraft? = nil,
         preparedStore: PreparedSessionStore = .shared, onOpenRecording: @escaping () -> Void = {},
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
        self.preparedStore = preparedStore
        // Nil = the remembered session draft (the app). A render gives a fixed one: it reads no preference.
        var first = Trigger.schedule, composer = sessionDraft, rule = BlockRuleDraft()
        switch subject {
        case .new: break
        case .session(let value):
            first = .session; composer = value
            rule.listIDs = value.blockListIds
            rule.lock = value.lock ? .locked : .free
        case .rule(let value): first = value.key.isAlways ? .always : .schedule; rule = BlockRuleDraft(value)
        case .jev: break
        case .prepared(let value): first = .session; composer = value.composer; rule = value.ruleDraft
        case .preset(let value): first = value.trigger; rule = value.draft
        }
        switch subject {
        case .rule, .prepared, .preset: break
        case .new, .session, .jev: if (trigger ?? first) == .session { rule.surveillance = Self.sessionSurveillance }
        }
        let clock = now ?? GoalongToday.now
        var start = Snapshot(trigger: trigger ?? first, draft: startDraft ?? rule, session: composer ?? .remembered(), later: false,
                             span: .minutes(60), wholeMac: false, freezeMode: .shield, kept: [], name: "")
        var end = Calendar.current.date(byAdding: .hour, value: 2, to: clock) ?? clock
        if case .preset(let value) = subject, let minutes = value.minutes { start.span = .minutes(minutes) }
        if case .prepared(let value) = subject {
            (start.name, start.wholeMac, start.freezeMode, start.kept) = (value.name, value.wholeMac, value.freezeMode, value.kept)
            switch value.span {
            case .minutes(let minutes): start.span = .minutes(minutes)
            case .until(let minute): start.span = .until; end = PreparedSession.untilDate(minute: minute, now: clock)
            }
        }
        initial = start
        _trigger = State(initialValue: start.trigger)
        _sessionDraft = State(initialValue: start.session)
        _draft = State(initialValue: start.draft)
        _startAt = State(initialValue: Calendar.current.date(byAdding: .hour, value: 1, to: clock) ?? clock)
        _until = State(initialValue: end)
        _span = State(initialValue: start.span)
        _name = State(initialValue: start.name)
        _wholeMac = State(initialValue: start.wholeMac)
        _freezeMode = State(initialValue: start.freezeMode)
        _kept = State(initialValue: start.kept)
    }

    /// The prepared session this window opened, if any.
    private var prepared: PreparedSession? {
        if case .prepared(let session) = subject { return session }
        return nil
    }

    /// A saved prepared session: « Modifier la séance », with « Enregistrer » and « Supprimer ».
    private var savedPrepared: PreparedSession? {
        prepared.flatMap { preparedStore.contains($0.id) ? $0 : nil }
    }

    /// « Surveillance » in a new session: checked as in the last one started (T-050 B1 point 4).
    static var sessionSurveillance: JevInterventionSettings? {
        let store = JevSurveillanceStore.shared
        return store.error == nil && store.document.sessionDefault ? store.document.sessionSettings : nil
    }

    private var rule: BlockRule? {
        if case .rule(let rule) = subject { return rule }
        return nil
    }

    /// The trigger is fixed once the rule exists: the selector stays shown, on its choice.
    var triggerIsFixed: Bool {
        switch subject {
        case .rule, .prepared: return true
        case .new, .session, .jev, .preset: return false
        }
    }

    var title: String {
        if savedPrepared != nil { return "Modifier la séance" }
        if trigger == .session { return "Nouvelle séance" }
        switch subject {
        case .rule, .jev: return "Modifier la règle"
        case .new, .session, .prepared, .preset: return "Nouvelle règle"
        }
    }

    /// « Quand » once the rule exists: only its choice stays shown, the others are hidden (T-050 B2 point 5).
    static func whenOptions(fixed: Bool, current: Trigger) -> [Trigger] {
        fixed ? [current] : Trigger.allCases
    }

    /// « Arrêt » of a session shows only the levels its engine has (P4): the impossible ones are hidden, with their
    /// reason under the control. Rules keep every level, greyed with its reason.
    var stopChoices: [BlockLock] {
        guard trigger == .session else { return BlockLock.ordered }
        return BlockLock.ordered.filter { lockUnavailable($0) == nil || $0 == stopLevel }
    }

    /// What the window holds: a change from the opening asks before a click outside closes it.
    struct Snapshot: Equatable {
        var trigger: Trigger
        var draft: BlockRuleDraft
        var session: FocusComposerDraft
        var later: Bool
        var span: BlockingNowComposer.Span
        var wholeMac: Bool
        var freezeMode: BlockFreeze.Mode
        var kept: [BlockAppRule]
        var name: String
    }

    /// A click outside closes the window at once until something changed; then it asks first.
    static func isDirty(initial: Snapshot?, now: Snapshot) -> Bool { initial.map { $0 != now } ?? false }

    private var snapshot: Snapshot {
        Snapshot(trigger: trigger, draft: draft, session: sessionDraft, later: later, span: span, wholeMac: wholeMac,
                 freezeMode: freezeMode, kept: kept, name: name)
    }

    /// The window as a prepared session: what « Enregistrer pour plus tard » keeps, and what « Relancer » starts again.
    func preparedSession(id: UUID = UUID(), name: String = "") -> PreparedSession {
        var value = PreparedSession(id: id, name: name)
        value.pomodoro = sessionDraft.kind == .pomodoro
        switch sessionDraft.rhythm {
        case .classic: value.rhythm = 0
        case .long: value.rhythm = 1
        case .custom: value.rhythm = 2
        }
        (value.work, value.shortBreak, value.longBreak, value.every) = (sessionDraft.work, sessionDraft.shortBreak,
                                                                        sessionDraft.longBreak, sessionDraft.every)
        value.cycles = sessionDraft.cycles
        value.intent = intent
        switch span {
        case .minutes(let minutes): value.span = .minutes(minutes)
        case .until:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: until)
            value.span = .until(minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
        value.listIDs = freezing ? [] : chosenIDs
        value.blockDuringBreaks = sessionDraft.blockDuringBreaks
        value.wholeMac = freezing
        value.freezeMode = freezeMode
        value.kept = kept
        let screen = screenUnavailable == nil
        value.red = screen && draft.red
        value.intensity = draft.intensity
        value.brightness = screen ? draft.brightness : nil
        value.surveillance = draft.surveillance
        value.lock = stopLevel
        value.pause = freezing ? nil : draft.pause
        return value
    }

    private var cap: CGFloat { maxHeight ?? min(680, (NSScreen.main?.visibleFrame.height ?? 900) * 0.75) }

    // MARK: Engines

    private var intent: String { sessionDraft.intent.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Pomodoro, or an intention: the session runs in Concentration. Continu without an intention is a block.
    var usesFocus: Bool { focus != nil && (sessionDraft.kind == .pomodoro || !intent.isEmpty) }
    private var freezing: Bool { trigger == .session && wholeMac && !usesFocus }
    /// Lists only: the whole Mac always starts now.
    private var scheduling: Bool { trigger == .session && later && !wholeMac && !usesFocus }
    private var lists: [BlockList] { blocking?.lists ?? [] }
    private var chosenIDs: [UUID] { lists.map(\.id).filter(draft.listIDs.contains) }

    /// Why the « Bloquer » block is greyed for this « Quand ». Nil = it works.
    var blockUnavailable: String? {
        nil
    }

    /// Why the red screen and the brightness are greyed for this « Quand ». Nil = they work.
    var screenUnavailable: String? {
        switch trigger {
        case .session:
            if usesFocus { return Self.focusScreenReason }
            if wholeMac { return Self.freezeScreenReason }
            if later { return Self.laterScreenReason }
        case .always, .schedule: break
        }
        if braise == nil { return "L’écran rouge n’est pas prêt sur ce Mac." }
        return nil
    }

    /// Why a stop level is greyed for this « Quand ». Nil = the engine has it.
    func lockUnavailable(_ lock: BlockLock) -> String? {
        switch trigger {
        case .always: if lock == .locked, !keepsAlwaysLock { return Self.alwaysLockedReason }
        case .session:
            if freezing { return lock == .locked ? nil : Self.freezeLockReason }
            if usesFocus {
                if lock == .typing || lock == .password { return Self.focusLockReason }
                if lock == .locked {
                    if !sessionDraft.canLock { return "Une séance sans fin ne peut pas être verrouillée." }
                    if chosenIDs.isEmpty { return "Le verrou porte sur les listes bloquées : choisissez-en une." }
                }
            }
        case .schedule: break
        }
        if lock == .password, blocking == nil { return "Le mot de passe vient du module Garde-fous." }
        return nil
    }

    /// A rule that already exists keeps its stored level in the form, even where a new rule could not have it: saving
    /// never weakens a stop in silence (T-050 lot A2). The engines still judge any real weakening.
    private var keepsAlwaysLock: Bool { rule?.key.isAlways == true && rule?.key.lock == .locked }

    /// The level the engine receives: the chosen one, or the nearest one it has.
    var stopLevel: BlockLock {
        if freezing { return .locked }
        if let rule, draft.lock == rule.key.lock { return draft.lock }
        return lockUnavailable(draft.lock) == nil ? draft.lock : .free
    }

    /// « Horaires » only: every day, 00:00 → 24:00, « Verrouillé ». Refused with its reason, never turned into « Libre ».
    var hoursAlwaysLocked: Bool {
        trigger == .schedule && draft.weekdays == Set(1...7) && draft.startMinute == 0 && draft.endMinute == 1_440
            && draft.lock == .locked && !keepsAlwaysLock
    }

    /// Why « Enregistrer » is greyed for a rule. Nil = the engines may judge it.
    var ruleProblem: String? {
        if hoursAlwaysLocked { return Self.hoursAlwaysLockedReason }
        return ruleDraft.problem
    }

    private var showsConsent: Bool {
        trigger != .session
            && RedScreenRangeEditor.showsConsent(lock: stopLevel, needed: BlockingRuntime.shared.guardNeedsConsent)
    }

    // MARK: Body

    var body: some View {
        if case .jev = subject { jevBody } else { ruleBody }
    }

    /// The « Jev » sheet: only what every rule shares — consent, connection, work context (T-050 B1 point 8).
    private var jevBody: some View {
        VStack(spacing: 0) {
            GoalongSheetScroll(cap: cap) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Self.jevTitle).font(LHTheme.sheetTitleFont).tracking(-0.4).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("block-rule-title")
                    LHCard {
                        JevMonitoringPage(onOpenRecording: { onClose(); onOpenRecording() }, onOpenWork: { onClose(); onOpenWork() },
                                          part: .when)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GoalongSheetFooter(inset: 28) {
                Spacer()
                // Jev's global settings are written as they change: there is nothing to cancel or to save.
                Button("Fermer", action: onClose).buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("block-rule-close")
            }
        }
        .font(.system(size: 13))
        .frame(width: Self.width)
        .background(LHTheme.pageBackground)
        .foregroundStyle(LHTheme.text)
        .goalongDismissOnOutsideClick(onCancel: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("block-rule-editor")
    }

    private var ruleBody: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in // wall: display tick
            let now = self.now ?? GoalongToday.timeline(context.date)
            ObservedOptional(object: blocking) { _ in
                ObservedOptional(object: braise) { _ in
                    ObservedOptional(object: focus) { _ in
                        VStack(spacing: 0) {
                            GoalongSheetScroll(cap: cap) {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(title).font(LHTheme.sheetTitleFont).tracking(-0.4).accessibilityAddTraits(.isHeader)
                                        .accessibilityIdentifier("block-rule-title")
                                    if case .new = subject {
                                        // A1: a template fills the window; nothing is saved before « Enregistrer ».
                                        BlockRuleTemplatesRow(lists: lists) { preset in
                                            trigger = preset.trigger; draft = preset.draft
                                            if let minutes = preset.minutes { span = .minutes(minutes) }
                                        }
                                    }
                                    box("Quand", id: "when") { whenBox(now: now) }
                                    box("Quoi", id: "what") { whatBox }
                                    box("Arrêt", id: "stop") { stopBox }
                                    notes
                                }
                                .padding(28)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            sentence(now: now)
                            footer(now: now)
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .frame(width: Self.width)
        .background(LHTheme.pageBackground)
        .foregroundStyle(LHTheme.text)
        .onChange(of: trigger) { next in
            refusal = nil; braise?.endPreview()
            if rule == nil, next == .session, draft.surveillance == nil { draft.surveillance = Self.sessionSurveillance }
        }
        .onDisappear { braise?.endPreview() }
        .goalongDismissOnOutsideClick(isDirty: { Self.isDirty(initial: initial, now: snapshot) }, onCancel: close)
        .alert(savedPrepared == nil ? "Supprimer cette règle ?" : "Supprimer cette séance ?", isPresented: $confirmingDelete) {
            Button("Supprimer", role: .destructive) { delete() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(savedPrepared == nil ? "Les listes restent. Seules leurs plages à ces heures sont retirées." : "Les listes et les règles restent.")
        }
        .alert("Enregistrer la séance", isPresented: $naming) {
            TextField("Nom", text: $name).accessibilityIdentifier("block-rule-session-name")
            Button("Annuler", role: .cancel) {}
            Button("Enregistrer") { savePrepared(id: UUID(), name: name) }
        } message: {
            Text("Elle sera dans « Séances » et dans la barre des menus, prête à lancer.")
        }
        .alert((pending ?? blockPlan(at: now ?? GoalongToday.now)).lockTitle(stopLevel), isPresented: $confirmingLock) {
            Button("Annuler", role: .cancel) {}
            Button(stopLevel == .password ? "Protéger" : "Verrouiller") {
                if let pending, watchOnly { startWatch(pending) }
                else if let pending, let blocking { blocking.recordGuardConsent(); startBlock(pending, blocking) }
            }
        } message: {
            let plan = pending ?? blockPlan(at: now ?? GoalongToday.now)
            // « Surveillance » alone holds no list and no guard: its own words (T-050 B2b point 5).
            Text(watchOnly ? plan.watchLockMessage(stopLevel)
                           : GuardConsent.message(plan.lockMessage(stopLevel), needed: BlockingRuntime.shared.guardNeedsConsent))
        }
        .alert("Bloquer tout le Mac \(pendingFreeze.phrase(now: pendingFreezeAt)) ?", isPresented: $confirmingFreeze) {
            Button("Annuler", role: .cancel) {}
            Button("Bloquer") { freeze() }
        } message: {
            Text(GuardConsent.message("\(pendingFreeze.phrase(now: pendingFreezeAt).capitalizedFirst), seul\(kept.isEmpty || freezeMode != .shield ? " Goalong reste accessible" : "es les apps gardées restent accessibles"). Impossible d’annuler. Éteindre le Mac reste possible ; au redémarrage, le gel reprend.",
                                      needed: BlockingRuntime.shared.guardNeedsConsent))
        }
        .alert(JevMonitoringPage.consentTitle, isPresented: $confirmingJev) {
            Button("Annuler", role: .cancel) {}
            Button(JevMonitoringPage.consentButton) {
                JevMonitor.shared.setEnabled(true)
                if GoalongCapabilityConsentStore.shared.isEnabled(.jevMonitoring) { draft.surveillance = Self.defaultSurveillance }
            }
        } message: {
            Text(JevMonitoringPage.consentMessage)
        }
        .alert("Verrouiller chaque phase de travail ?", isPresented: $confirmingFocusLock) {
            Button("Annuler", role: .cancel) {}
            Button("Verrouiller") { BlockingRuntime.shared.recordGuardConsent(); beginFocus() }
        } message: {
            Text(FocusComposer.lockMessage(BlockingRuntime.shared))
        }
        .sheet(isPresented: $settingPassword) {
            if let blocking {
                BlockingPasswordSheet(controller: blocking, purpose: .create) { settingPassword = false }.goalongControls()
            }
        }
        // A container: without it the sheet's identifier replaces the ones of the footer buttons.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("block-rule-editor")
    }

    // MARK: Frame

    /// One titled box: the same for every « Quand ».
    private func box<Content: View>(_ title: String, id: String, @ViewBuilder content: () -> Content) -> some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(LHTheme.cardTitleFont).accessibilityAddTraits(.isHeader)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("block-rule-box-\(id)")
    }

    /// The label sits on the centre line of the first row of controls (32 points high).
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 84, height: 32, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func help(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(warning ? LHTheme.warning : LHTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A block the engine does not allow here: shown, greyed, with its reason.
    private func greyed(_ reason: String?, id: String) -> some View {
        Group {
            if let reason { help(reason).accessibilityIdentifier("block-rule-reason-\(id)") }
        }
    }

    private var moduleOff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Les listes de sites et d’apps viennent du module Garde-fous.").foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Activer Garde-fous") { GoalongModuleStore.shared.setEnabled(.blocking, true) }
                .buttonStyle(LHSecondaryButtonStyle())
                .accessibilityIdentifier("block-rule-enable-blocking")
        }
        .frame(minHeight: 32, alignment: .leading)
    }

    // MARK: Quand

    @ViewBuilder private func whenBox(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let saved = savedPrepared {
                row("Nom") {
                    TextField("", text: $name).textFieldStyle(GoalongFieldStyle())
                        .goalongPlaceholder(saved.name, isEmpty: name.isEmpty)
                        .accessibilityLabel("Nom de la séance")
                        .accessibilityIdentifier("block-rule-session-name")
                        .frame(minHeight: 32)
                }
            }
            GoalongSegmentedControl("Quand", selection: $trigger,
                                    options: Self.whenOptions(fixed: triggerIsFixed, current: trigger)) { $0.title }
                .accessibilityIdentifier("block-rule-when")
            switch trigger {
            case .always:
                help(Self.alwaysSentence).accessibilityIdentifier("block-rule-always")
            case .schedule:
                scheduleRows
            case .session:
                sessionRows(now: now)
            }
            if let rule, rule.lock != .free, case .running = rule.state {
                GoalongNote("Cette règle est en cours et protégée. Un changement qui l’affaiblit est refusé jusqu’à sa fin.",
                            symbol: rule.lock.symbol)
                    .accessibilityIdentifier("block-rule-protected")
            }
            if rule != nil, draft.listIDs.isEmpty, draft.hasRedPart {
                row("État") {
                    Toggle("Désactiver la règle", isOn: $draft.paused).toggleStyle(.goalongSwitchInline)
                        .frame(minHeight: 32)
                        .accessibilityIdentifier("block-rule-paused")
                }
            }
        }
    }

    private var hoursHint: String {
        if hoursAlwaysLocked { return Self.hoursAlwaysLockedReason }
        if draft.weekdays.isEmpty || draft.startMinute == draft.endMinute {
            return "Choisissez au moins un jour et deux heures différentes."
        }
        return draft.endMinute <= draft.startMinute ? "La plage finit le lendemain à \(BlockingFormat.rangeEnd(draft.endMinute))."
                                                    : "La plage commence et se termine le même jour."
    }

    private var scheduleRows: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    help(hoursHint, warning: hoursAlwaysLocked).accessibilityIdentifier("block-rule-hours-hint")
                }
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

    // MARK: Séance

    @ViewBuilder private func sessionRows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if usesFocus, focus?.currentSession != nil {
                GoalongNote("Une séance est déjà en cours. Terminez-la pour en lancer une autre.")
                    .accessibilityIdentifier("block-rule-session-running")
            }
            row("Début") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        GoalongSegmentedControl("Début", selection: $later, options: [false, true],
                                                unavailable: { $0 ? laterUnavailable : nil }) { $0 ? "Plus tard" : "Tout de suite" }
                            .accessibilityIdentifier("block-rule-start")
                        if scheduling {
                            DatePicker("Début", selection: $startAt, in: now..., displayedComponents: [.date, .hourAndMinute])
                                .goalongDateField().labelsHidden()
                                .environment(\.locale, Locale(identifier: "fr_FR"))
                                .accessibilityIdentifier("blocking-start-at")
                        }
                    }
                    .frame(minHeight: 32)
                    if let reason = laterUnavailable { greyed(reason, id: "later") }
                }
            }
            row("Rythme") {
                VStack(alignment: .leading, spacing: 10) {
                    GoalongSegmentedControl("Rythme", selection: $sessionDraft.kind, options: [.free, .pomodoro],
                                            unavailable: { $0 == .pomodoro && focus == nil ? "Pomodoro vient du module Concentration." : nil }) {
                        $0 == .free ? "Continu" : "Pomodoro"
                    }
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("block-rule-rhythm")
                    if sessionDraft.kind == .pomodoro { phases }
                }
            }
            row("Pendant") { durationRow }
            if focus != nil {
                row("Intention") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("", text: $sessionDraft.intent)
                            .textFieldStyle(GoalongFieldStyle())
                            .goalongPlaceholder("Facultatif. Ex. : relire le contrat", isEmpty: sessionDraft.intent.isEmpty)
                            .accessibilityLabel("Intention, facultative")
                            .accessibilityIdentifier("concentration-intent")
                            .frame(minHeight: 32)
                        help(usesFocus ? "Avec une intention ou en Pomodoro, la séance a son minuteur, ses repos et son bilan."
                                       : "Sans intention, en Continu, c’est un blocage simple.")
                    }
                }
            }
        }
    }

    private var laterUnavailable: String? {
        if usesFocus { return "Une séance Pomodoro ou avec intention commence tout de suite." }
        if wholeMac { return "Tout le Mac se bloque tout de suite." }
        return nil
    }

    @ViewBuilder private var durationRow: some View {
        if sessionDraft.kind == .pomodoro {
            GoalongSegmentedControl("Cycles", selection: $sessionDraft.cycles, options: [nil, 2, 4, 6]) {
                $0.map { "\($0) cycles" } ?? "Jusqu’à l’arrêt"
            }
            .frame(minHeight: 32, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                GoalongSegmentedControl("Durée", selection: $span,
                                        options: [.minutes(25), .minutes(60), .minutes(120), .minutes(240), .until]) {
                    switch $0 {
                    case .minutes(let value): return BlockingFormat.duration(minutes: value)
                    case .until: return "Jusqu’à…"
                    }
                }
                if span == .until {
                    DatePicker("Heure de fin", selection: $until, displayedComponents: .hourAndMinute)
                        .goalongDateField().labelsHidden()
                        .environment(\.locale, Locale(identifier: "fr_FR"))
                }
            }
            .frame(minHeight: 32, alignment: .leading)
        }
    }

    private var phases: some View {
        VStack(alignment: .leading, spacing: 10) {
            GoalongSegmentedControl("Phases", selection: $sessionDraft.rhythm, options: [.classic, .long, .custom]) {
                switch $0 {
                case .classic: return "25 / 5"
                case .long: return "50 / 10"
                case .custom: return "Autre"
                }
            }
            if sessionDraft.rhythm == .custom {
                HStack(spacing: 14) {
                    stepper("Travail", value: $sessionDraft.work, range: 5...120, unit: "min")
                    stepper("Repos", value: $sessionDraft.shortBreak, range: 1...30, unit: "min")
                    stepper("Longue", value: $sessionDraft.longBreak, range: 5...60, unit: "min")
                    stepper("Toutes les", value: $sessionDraft.every, range: 2...8, unit: "")
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

    // MARK: Quoi

    @ViewBuilder private var whatBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Bloquer") { blockPart }
            row("Surveillance") { surveillancePart }
            row("Écran rouge") { redPart }
            row("Luminosité") { brightnessPart }
            if let notice = braise?.previewNotice {
                help(notice).accessibilityIdentifier("block-rule-preview-notice")
            }
        }
    }

    // MARK: Surveillance (T-050 B1 points 2 and 5)

    /// The settings a new « Surveillance » starts with: the last ones chosen for a session (the old ones after the
    /// migration).
    static var defaultSurveillance: JevInterventionSettings {
        JevSurveillanceStore.shared.document.sessionSettings
    }

    private var jevReady: Bool {
        JevActivationAvailability(hasKey: JevMonitor.shared.hasKey,
                                  localHistoryEnabled: GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory)).isReady
    }

    /// What a press on the « Surveillance » switch does. Pure.
    enum SurveillanceStep: Equatable { case off, on(JevInterventionSettings), askConsent }

    /// Checking « Surveillance » without consent opens the consent request of the Jev page (point 5).
    /// Point 7: the sentence under « Arrêt » when « Surveillance » is checked with a stop other than « Libre ».
    static func surveillanceStopNote(_ draft: BlockRuleDraft, stop: BlockLock) -> String? {
        draft.surveillance != nil && stop != .free ? JevStopGate.editorText : nil
    }

    static func surveillanceStep(_ on: Bool, consented: Bool, defaults: JevInterventionSettings) -> SurveillanceStep {
        guard on else { return .off }
        return consented ? .on(defaults) : .askConsent
    }

    private func setSurveillance(_ on: Bool) {
        switch Self.surveillanceStep(on, consented: GoalongCapabilityConsentStore.shared.isEnabled(.jevMonitoring),
                                     defaults: Self.defaultSurveillance) {
        case .off: draft.surveillance = nil
        case .on(let settings): draft.surveillance = settings
        case .askConsent: confirmingJev = true
        }
    }

    /// The preset whose veils match the settings, if any.
    static func strength(of settings: JevInterventionSettings) -> JevEffectStrength? {
        guard settings.effectsEnabled else { return nil }
        let levels = settings.stages.map(\.intensity)
        return JevEffectStrength.allCases.first { $0.intensities == levels }
    }

    @ViewBuilder private var surveillancePart: some View {
        let consented = GoalongCapabilityConsentStore.shared.isEnabled(.jevMonitoring)
        let blocked = !consented && !jevReady && draft.surveillance == nil
        VStack(alignment: .leading, spacing: 8) {
            Toggle(Self.surveillanceToggle, isOn: Binding(get: { draft.surveillance != nil }, set: setSurveillance))
                .toggleStyle(.goalongSwitchInline).frame(minHeight: 32)
                .disabled(blocked)
                .accessibilityLabel("Surveillance")
                .accessibilityIdentifier("block-rule-jev")
            if blocked {
                HStack(spacing: 10) {
                    help(Self.surveillanceSetupReason).accessibilityIdentifier("block-rule-reason-jev")
                    Button("Configurer…") { openJevSettings() }
                        .buttonStyle(LHQuietButtonStyle()).fixedSize()
                        .accessibilityIdentifier("block-rule-jev-setup")
                }
            } else if let settings = draft.surveillance {
                GoalongSegmentedControl("Force", selection: Binding(get: { Self.strength(of: settings) }, set: { value in
                    guard let value, var next = draft.surveillance else { return }
                    next.applyStrength(value); next.effectsEnabled = true
                    draft.surveillance = next
                }), options: JevEffectStrength.allCases.map(Optional.some), title: { $0?.title ?? "" })
                    .frame(minHeight: 32, alignment: .leading)
                    .accessibilityIdentifier("block-rule-jev-strength")
                help(Self.surveillanceHelp)
                GoalongDisclosureGroup("Personnaliser") {
                    JevInterventionControls(settings: Binding(get: { draft.surveillance ?? settings },
                                                              set: { draft.surveillance = $0 }))
                }
                .accessibilityIdentifier("block-rule-jev-custom")
            }
        }
    }

    @ViewBuilder private var blockPart: some View {
        if let blocking {
            VStack(alignment: .leading, spacing: 6) {
                BlockingFlow(spacing: 8) {
                    ForEach(blocking.lists) { list in
                        BlockingListChip(list: list, selected: !freezing && draft.listIDs.contains(list.id)) {
                            wholeMac = false
                            if draft.listIDs.contains(list.id) { draft.listIDs.remove(list.id) } else { draft.listIDs.insert(list.id) }
                        }
                    }
                    BlockingNewListChip { id in wholeMac = false; draft.listIDs.insert(id) }
                    BlockingWholeMacChip(selected: freezing) { wholeMac.toggle() }
                        .disabled(wholeMacUnavailable != nil)
                        .help(wholeMacUnavailable ?? "")
                        .accessibilityIdentifier("block-rule-whole-mac")
                }
                .frame(minHeight: 32, alignment: .leading)
                .disabled(blockUnavailable != nil)
                if let reason = blockUnavailable {
                    greyed(reason, id: "block")
                } else if freezing {
                    freezeRows
                } else {
                    if trigger == .session, sessionDraft.kind == .pomodoro, !chosenIDs.isEmpty {
                        Toggle("Aussi pendant les repos", isOn: $sessionDraft.blockDuringBreaks).toggleStyle(.goalongCheckbox)
                    }
                    if trigger != .session { greyed(wholeMacUnavailable, id: "whole-mac") }
                    if draft.listIDs.isEmpty, !draft.hasRedPart, draft.surveillance == nil, trigger != .session {
                        help("Choisissez au moins une liste, la surveillance, l’écran rouge ou la luminosité.")
                    }
                }
            }
        } else if let reason = blockUnavailable {
            greyed(reason, id: "block").frame(minHeight: 32, alignment: .leading)
        } else {
            moduleOff
        }
    }

    private var wholeMacUnavailable: String? {
        if trigger == .session, !usesFocus { return nil }
        return Self.wholeMacReason
    }

    private var freezeRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            GoalongSegmentedControl("Écran", selection: $freezeMode, options: BlockFreeze.Mode.allCases) {
                $0 == .shield ? "Écran Goalong" : "Session verrouillée"
            }
            if freezeMode == .shield {
                BlockingFlow(spacing: 6) {
                    ForEach(kept) { app in
                        BlockingItemChip(item: .app(app), removable: true) { kept.removeAll { $0 == app } }
                    }
                    Button { picking = true } label: { Label("Garder une app", systemImage: "plus") }
                        .buttonStyle(LHQuietButtonStyle())
                        .accessibilityIdentifier("blocking-freeze-keep")
                        .popover(isPresented: $picking) {
                            BlockingAppPicker(excluded: Set(kept.map(\.bundleIdentifier))) { kept.append($0) }
                        }
                }
            }
        }
    }

    private var redRange: ClosedRange<Double> {
        trigger == .session ? BraiseController.minimumHoldIntensity...1 : 0.05...1
    }

    @ViewBuilder private var redPart: some View {
        let reason = screenUnavailable
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Teinte rouge", isOn: Binding(get: { reason == nil && draft.red }, set: { draft.red = $0 }))
                .toggleStyle(.goalongSwitchInline).frame(minHeight: 32)
                .disabled(reason != nil)
                .accessibilityLabel("Écran rouge")
                .accessibilityIdentifier("block-rule-red")
            if reason == nil, draft.red {
                level("Rouge à", value: $draft.intensity, in: redRange, spoken: "Intensité du rouge") { value, holding in
                    braise?.showPreview(red: value, holding: holding)
                }
            }
            if let reason {
                // Jev: « Bloquer » already says it, once for the three blocks.
                if reason != blockUnavailable { greyed(reason, id: "red") }
                if braise == nil, trigger != .session || !usesFocus {
                    Button("Préparer l’écran rouge", action: onPrepareRed).buttonStyle(LHSecondaryButtonStyle())
                        .accessibilityIdentifier("block-rule-prepare-red")
                }
            }
        }
    }

    @ViewBuilder private var brightnessPart: some View {
        let reason = screenUnavailable ?? (braise?.canControlBrightness == false && draft.brightness == nil
            ? "Aucun écran de ce Mac ne peut être réglé par Goalong." : nil)
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Niveau fixé", isOn: Binding(get: { reason == nil && draft.brightness != nil },
                                                       set: { draft.brightness = $0 ? 0.4 : nil }))
                .toggleStyle(.goalongSwitchInline).frame(minHeight: 32)
                .disabled(reason != nil)
                .accessibilityLabel("Luminosité bloquée")
                .accessibilityIdentifier("block-rule-brightness")
            if reason == nil, let value = draft.brightness {
                level("Luminosité à", value: Binding(get: { value }, set: { draft.brightness = $0 }),
                      in: BrightnessLockRules.levelRange, spoken: "Luminosité bloquée") { value, holding in
                    braise?.showPreview(brightness: value, holding: holding)
                }
            }
            // The same sentence stands just above, under « Écran rouge »: it covers both blocks.
            if let reason, reason != screenUnavailable { greyed(reason, id: "brightness") }
        }
    }

    /// A slider with its live preview: the screen shows the value while it moves, and `previewHold` after it is let go.
    private func level(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, spoken: String,
                       preview: @escaping (Double, Bool) -> Void) -> some View {
        BlockRuleLevel(title: title, value: value, range: range, spoken: spoken, preview: preview)
    }

    // MARK: Arrêt

    private var stopBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            GoalongSegmentedControl("Arrêt", selection: Binding(get: { stopLevel }, set: { draft.lock = $0 }),
                                    options: stopChoices, unavailable: lockUnavailable) { $0.title }
                .accessibilityIdentifier("block-rule-stop")
            if freezing {
                BlockingLockExplainer(lock: .locked,
                                      text: freezeMode == .shield
                                          ? "Un écran Goalong couvre tout, sauf les apps gardées. Toujours verrouillé."
                                          : "macOS verrouille la session, et la reverrouille à chaque ouverture. Toujours verrouillé.")
            } else {
                BlockingLockExplainer(lock: stopLevel, text: stopLevel == .locked && draft.pause != nil ? PausePolicy.lockedText : nil)
            }
            if showsPauses { pauseRows }
            let reasons = BlockLock.ordered.compactMap { lock in lockUnavailable(lock).map { (lock, $0) } }
            ForEach(Array(Set(reasons.map(\.1))).sorted(), id: \.self) { reason in
                greyed(reason, id: "stop")
            }
            if stopLevel == .password, let blocking, !blocking.hasPassword {
                HStack(spacing: 10) {
                    Text("Pas encore de mot de passe.").font(.system(size: 12)).foregroundStyle(LHTheme.warning).fixedSize()
                    Button("Le choisir…") { settingPassword = true }
                        .buttonStyle(LHQuietButtonStyle()).fixedSize()
                        .accessibilityIdentifier("blocking-password-set")
                }
            }
            if let note = Self.surveillanceStopNote(draft, stop: stopLevel) {
                help(note).accessibilityIdentifier("block-rule-surveillance-stop")
            }
            if showsConsent {
                help(GuardConsent.text).accessibilityIdentifier("block-rule-guard-consent")
            }
        }
    }

    // MARK: Pauses (T-050 D1)

    /// A pause needs something the rule blocks or watches; a whole-Mac freeze has none (P4: hidden).
    private var showsPauses: Bool {
        !freezing && !usesFocus && (!draft.listIDs.isEmpty || draft.surveillance != nil)
    }

    /// The rule runs under a protected stop: its pauses can only go down (« Durcir seulement »).
    private var pausesHardenOnly: Bool {
        guard let rule else { return false }
        if rule.lock != .free, case .running = rule.state { return true }
        return rule.lists.contains { blocking?.isStricterOnly($0.id) == true }
    }

    /// Whether `next` may replace the opening pause now.
    private func pauseAllows(_ next: PausePolicy?) -> Bool {
        guard pausesHardenOnly else { return true }
        var simulated = draft
        simulated.setPause(next)
        return !simulated.pauseChanged || PauseEngine.weakening(simulated.originalPause, simulated.pause) == nil
    }

    private func pauseChange(_ change: (inout PausePolicy) -> Void) -> PausePolicy? {
        guard var next = draft.pause else { return nil }
        change(&next)
        return next
    }

    private func pauseBinding<T>(_ key: WritableKeyPath<PausePolicy, T>, fallback: T) -> Binding<T> {
        Binding(get: { draft.pause?[keyPath: key] ?? fallback },
                set: { value in
                    let next = pauseChange { $0[keyPath: key] = value }
                    if pauseAllows(next) { draft.setPause(next) }
                })
    }

    /// The highest value a stepper may reach: the opening one under « Durcir seulement ».
    private func pauseCap(_ key: KeyPath<PausePolicy, Int?>, _ range: ClosedRange<Int>) -> ClosedRange<Int> {
        guard pausesHardenOnly, let value = draft.originalPause?[keyPath: key] else { return range }
        return range.lowerBound...max(range.lowerBound, min(range.upperBound, value))
    }

    @ViewBuilder private var pauseRows: some View {
        let on = Binding(get: { draft.pause != nil },
                         set: { value in
                             let next = value ? (draft.originalPause ?? PausePolicy()) : nil
                             if pauseAllows(next) { draft.setPause(next) }
                         })
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Autoriser des pauses", isOn: on).toggleStyle(.goalongSwitchInline)
                .frame(minHeight: 28)
                .disabled(draft.pause == nil && !pauseAllows(PausePolicy()))
                .accessibilityIdentifier("block-rule-pause")
            if let pause = draft.pause {
                pauseSettings(pause)
            }
            if pausesHardenOnly {
                greyed(PausePolicy.hardenOnlyReason, id: "pause")
            }
        }
    }

    @ViewBuilder private func pauseSettings(_ pause: PausePolicy) -> some View {
        let budgetRange = pauseCap(\.optionalBudget, PausePolicy.budgetRange)
        HStack(spacing: 14) {
            Stepper(value: pauseBinding(\.budgetMinutes, fallback: 10), in: budgetRange, step: pause.budgetMinutes < 10 ? 1 : 5) {
                Text("\(pause.budgetMinutes) min").monospacedDigit()
            }
            .fixedSize()
            .accessibilityIdentifier("block-rule-pause-budget")
            GoalongMenuPicker("Période", selection: pauseBinding(\.period, fallback: .day),
                              options: PausePolicy.Period.allCases.filter { period in
                                  pauseAllows(pauseChange { $0.period = period })
                              }.map { ($0, "par \($0.title)") })
                .fixedSize()
                .accessibilityIdentifier("block-rule-pause-period")
        }
        HStack(spacing: 14) {
            GoalongMenuPicker("Durée d’une pause", selection: pauseBinding(\.maxPauseMinutes, fallback: nil),
                              options: PausePolicy.longestChoices(budget: pause.budgetMinutes, current: pause.maxPauseMinutes)
                                  .filter { value in pauseAllows(pauseChange { $0.maxPauseMinutes = value }) }
                                  .map { ($0, $0.map { "Une pause ≤ \($0) min" } ?? "Pauses sans durée max") })
                .fixedSize()
                .accessibilityIdentifier("block-rule-pause-longest")
            GoalongMenuPicker("Nombre de pauses", selection: pauseBinding(\.maxPauses, fallback: nil),
                              options: ([nil] + (1...10).map { Optional($0) })
                                  .filter { value in pauseAllows(pauseChange { $0.maxPauses = value }) }
                                  .map { ($0, $0.map { FrenchCount.count($0, "pause", "pauses") + " au plus" } ?? "Sans nombre max") })
                .fixedSize()
                .accessibilityIdentifier("block-rule-pause-count")
        }
        HStack(spacing: 14) {
            GoalongMenuPicker("Avant une pause", selection: pauseBinding(\.gate, fallback: .none),
                              options: gateChoices(pause).map { ($0, "Avant : \($0.title.lowercased())") })
                .fixedSize()
                .accessibilityIdentifier("block-rule-pause-gate")
            if case .wait(let minutes) = pause.gate {
                Stepper(value: Binding(get: { minutes }, set: { value in
                            let next = pauseChange { $0.gate = .wait(minutes: value) }
                            if pauseAllows(next) { draft.setPause(next) }
                        }), in: PausePolicy.waitRange, step: minutes < 10 ? 1 : minutes < 60 ? 5 : 30) {
                    Text(BlockingFormat.duration(minutes: minutes)).monospacedDigit()
                }
                .fixedSize()
                .accessibilityIdentifier("block-rule-pause-wait")
            }
        }
        if stopLevel == .locked {
            Stepper(value: .constant(0), in: 0...0) { Text("Pauses en plus : 0").monospacedDigit() }
                .fixedSize().disabled(true)
                .accessibilityIdentifier("block-rule-pause-extra")
            greyed(PausePolicy.lockedExtraReason, id: "pause-extra")
        } else {
            let extra = pause.extraPerPeriod ?? PausePolicy.extraRange.upperBound
            Stepper(value: Binding(get: { extra }, set: { value in
                        let next = pauseChange { $0.extraPerPeriod = value }
                        if pauseAllows(next) { draft.setPause(next) }
                    }), in: pauseCap(\.extraPerPeriod, PausePolicy.extraRange)) {
                Text("Pauses en plus : \(extra) par \(pause.period.title)").monospacedDigit()
            }
            .fixedSize()
            .accessibilityIdentifier("block-rule-pause-extra")
            help(PausePolicy.extraHelp)
        }
    }

    /// « Mot de passe » is offered once a password exists (P4: hidden otherwise, the stop row says how to set it).
    private func gateChoices(_ pause: PausePolicy) -> [PausePolicy.Gate] {
        let wait: PausePolicy.Gate
        if case .wait = pause.gate { wait = pause.gate } else { wait = .wait(minutes: 5) }
        var choices: [PausePolicy.Gate] = [.none, wait, .typing]
        if blocking?.hasPassword == true || pause.gate == .password { choices.append(.password) }
        return choices.filter { gate in pauseAllows(pauseChange { $0.gate = gate }) }
    }

    // MARK: Notes and footer

    /// The rule in one sentence, with what its stop will ask (S3). « Verrouillé » is said as a warning.
    @ViewBuilder private func sentence(now: Date) -> some View {
        if let text = BlockRuleSentence.text(trigger: trigger, draft: draft, lists: lists, lock: stopLevel,
                                             session: trigger == .session ? sessionWords(now: now) : nil, now: now) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if stopLevel == .locked { Image(systemName: BlockLock.locked.symbol).accessibilityHidden(true) }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12, weight: stopLevel == .locked ? .medium : .regular))
            .foregroundStyle(stopLevel == .locked ? LHTheme.text : LHTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("block-rule-sentence")
        }
    }

    private func sessionWords(now: Date) -> BlockRuleSentence.Session {
        guard usesFocus else { return .init(end: blockPlan(at: now).end, wholeMac: freezing) }
        return .init(end: focusEnd(now: now), rhythm: sessionDraft.kind == .pomodoro ? "en Pomodoro" : nil)
    }

    private func focusEnd(now: Date) -> Date? {
        var mode = sessionDraft
        if mode.kind == .free { mode.free = .minutes(continuousMinutes(now: now)) }
        var session = FocusSession(intent: "·", mode: mode.mode, startedAt: now, events: [.init(kind: .start, at: now)])
        session.plannedEndAt = nil
        return FocusPhases.plannedEnd(session)
    }

    @ViewBuilder private var notes: some View {
        if let refusal {
            GoalongNote(refusal, tone: .warning).accessibilityIdentifier("block-rule-refusal")
        }
        if trigger == .session {
            if usesFocus, let error = focus?.error {
                GoalongNote(FocusUIError.message(raw: error), tone: .warning).accessibilityIdentifier("block-rule-session-error")
            } else if !usesFocus, let error = blocking?.error {
                GoalongNote(error, tone: .warning).accessibilityIdentifier("block-rule-error")
            }
        }
    }

    private func footer(now: Date) -> some View {
        GoalongSheetFooter(inset: 28) {
            if rule != nil || savedPrepared != nil {
                Button("Supprimer", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("block-rule-delete")
            }
            Spacer()
            if let hint = footerHint(now: now) {
                Text(hint).font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText).lineLimit(2)
                    .accessibilityIdentifier("block-rule-hint")
            }
            Button("Annuler", action: close).buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("block-rule-cancel")
            if let saved = savedPrepared {
                Button("Enregistrer") { savePrepared(id: saved.id, name: name) }
                    .buttonStyle(LHSecondaryButtonStyle())
                    .accessibilityIdentifier("block-rule-session-save")
            } else if trigger == .session, !scheduling {
                // A prepared session starts when it is launched: « Plus tard » has nothing to keep, the button is hidden.
                Button("Enregistrer pour plus tard…") { name = ""; naming = true }
                    .buttonStyle(LHSecondaryButtonStyle())
                    .disabled(primaryDisabled)
                    .accessibilityIdentifier("block-rule-session-keep")
            }
            Button(primaryTitle(now: now)) { primary(now: now) }
                .buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
                .accessibilityIdentifier(trigger == .session ? "block-rule-start-session" : "block-rule-save")
        }
    }

    func primaryTitle(now: Date) -> String {
        guard trigger == .session else { return "Enregistrer" }
        return scheduling && blockPlan(at: now).startsLater ? "Programmer" : "Démarrer"
    }

    /// What the main button will do, in words: the end of the session, or why it cannot start.
    private func footerHint(now: Date) -> String? {
        guard trigger == .session else { return nil }
        if usesFocus {
            if focus?.currentSession != nil { return nil }
            return focusEnd(now: now).map { "Jusqu’à \(BlockingFormat.time($0))" }
        }
        if watchOnly {
            let plan = blockPlan(at: now)
            return plan.startsLater ? BlockingFormat.period(from: plan.start, to: plan.end, now: now).capitalizedFirst
                                    : BlockingFormat.until(plan.end, now: now).capitalizedFirst
        }
        guard let blocking else { return "Activez Garde-fous, ou donnez une intention." }
        let hint = BlockingProtectionDetails.startHint(wholeMac: freezing, frozen: blocking.freeze != nil,
                                                       hasLists: !blocking.lists.isEmpty || sessionHoldsScreen,
                                                       anySelected: !chosenIDs.isEmpty || sessionHoldsScreen,
                                                       needsPassword: stopLevel == .password && !blocking.hasPassword)
        if let hint { return hint }
        if freezing { return BlockingFreezePromise(end: blockPlan(at: now).end, now: now).phrase(now: now).capitalizedFirst }
        let plan = blockPlan(at: now)
        return plan.startsLater ? BlockingFormat.period(from: plan.start, to: plan.end, now: now).capitalizedFirst
                                : BlockingFormat.until(plan.end, now: now).capitalizedFirst
    }

    private var sessionHoldsScreen: Bool { braise != nil && screenUnavailable == nil && draft.hasRedPart }
    /// A Continu session with « Surveillance » only: no list, no screen, no whole Mac. Jev watches it alone.
    private var watchOnly: Bool {
        trigger == .session && !usesFocus && !freezing && chosenIDs.isEmpty && !sessionHoldsScreen && draft.surveillance != nil
    }

    private var primaryDisabled: Bool {
        switch trigger {
        case .always, .schedule: return ruleProblem != nil || !unreadableFields.isEmpty
        case .session:
            if usesFocus { return focus?.currentSession != nil }
            if watchOnly { return false }
            guard let blocking else { return true }
            if freezing { return blocking.freeze != nil }
            return (chosenIDs.isEmpty && !sessionHoldsScreen) || (stopLevel == .password && !blocking.hasPassword)
        }
    }

    private func close() {
        braise?.endPreview()
        onClose()
    }

    private func savePrepared(id: UUID, name typed: String) {
        let clean = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        preparedStore.save(preparedSession(id: id, name: clean.isEmpty ? (savedPrepared?.name ?? Self.defaultIntent) : clean))
        close()
    }

    /// Every session started from this window becomes « la dernière séance ».
    private func recordLast() {
        preparedStore.recordLast(preparedSession(id: prepared?.id ?? UUID(), name: prepared?.name ?? ""))
    }

    private func primary(now: Date) {
        switch trigger {
        case .always, .schedule: save()
        case .session: startSession(now: now)
        }
    }

    // MARK: Writes

    /// « Toujours » is a range of every day, 24 hours a day, in the current engines.
    var ruleDraft: BlockRuleDraft {
        var value = draft
        if trigger == .always { value.weekdays = Set(1...7); value.startMinute = 0; value.endMinute = 1_440 }
        value.lock = stopLevel
        return value
    }

    /// Both engines check before either writes (`BlockRulePlan.apply`); a refusal leaves the sheet open.
    private func save() {
        let consent = showsConsent
        let writes = BlockRulePlan.writes(ruleDraft, replacing: rule, lists: lists, red: braise?.ranges)
        if let refusal = BlockRulePlan.apply(writes, blocking: blocking, braise: braise, surveillance: .shared) {
            self.refusal = refusal
            return
        }
        // The consent is recorded only where its text was shown (T-048 B6).
        if consent { BlockingRuntime.shared.recordGuardConsent() }
        close()
    }

    private func delete() {
        if let saved = savedPrepared { preparedStore.delete(saved.id); close(); return }
        guard let rule else { return }
        let writes = BlockRulePlan.writes(nil, replacing: rule, lists: lists, red: braise?.ranges)
        if let refusal = BlockRulePlan.apply(writes, blocking: blocking, braise: braise, surveillance: .shared) {
            self.refusal = refusal
            return
        }
        close()
    }

    // MARK: Séance start

    /// The page's `now` moves every 30 s only: it draws the labels; a click reads the clock again.
    private func blockPlan(at date: Date) -> BlockingNowPlan {
        if case .minutes(let value) = span { return BlockingNowPlan(later: scheduling, startAt: startAt, minutes: value, now: date) }
        return BlockingNowPlan(later: scheduling, startAt: startAt, until: until, now: date)
    }

    private func continuousMinutes(now: Date) -> Int {
        if case .minutes(let value) = span { return value }
        let plan = BlockingNowPlan(later: false, startAt: now, until: until, now: now)
        return max(1, Int((plan.end.timeIntervalSince(plan.start) / 60).rounded()))
    }

    private var pendingFreeze: BlockingFreezePromise {
        pendingFreezePromise ?? BlockingFreezePromise(end: blockPlan(at: pendingFreezeAt).end, now: pendingFreezeAt)
    }

    private func startSession(now: Date) {
        refusal = nil
        if usesFocus {
            if stopLevel == .locked { confirmingFocusLock = true } else { beginFocus() }
            return
        }
        let date = Date() // wall: page input; the controller moves it to its trusted frame
        if watchOnly {
            let plan: BlockingNowPlan?
            if case .minutes = span { plan = blockPlan(at: date) } else { plan = blockPlan(at: now).confirmed(at: date) }
            guard let plan else { refusal = BlockingNowComposer.refusal(span, freeze: false); return }
            // « Surveillance » alone with a protected stop asks the same confirmation as the lists (F2).
            pending = plan
            if stopLevel.protectsLists { confirmingLock = true } else { startWatch(plan) }
            return
        }
        guard let blocking else { return }
        if freezing {
            let shown: BlockingNowPlan
            if case .minutes = span { shown = blockPlan(at: date) } else { shown = blockPlan(at: now) }
            pending = shown
            pendingFreezePromise = BlockingFreezePromise.alert(end: shown.end, click: date)
            pendingFreezeAt = date
            confirmingFreeze = true
            return
        }
        let promised: BlockingNowPlan?
        if case .minutes = span { promised = blockPlan(at: date) } else { promised = blockPlan(at: now).confirmed(at: date) }
        guard let shown = promised else {
            blocking.error = BlockingNowComposer.refusal(span, freeze: false); return
        }
        pending = shown
        if stopLevel.protectsLists { confirmingLock = true } else { startBlock(shown, blocking) }
    }

    private func startWatch(_ plan: BlockingNowPlan) {
        markSession(.own, id: UUID(), start: plan.start, end: plan.end)
        recordLast()
        close()
    }

    private func startBlock(_ promised: BlockingNowPlan, _ blocking: BlockingController) {
        let holds = sessionHoldsScreen ? braise : nil
        var session: UUID?
        if BlockingNowStart.run(promised, listIDs: chosenIDs, lock: stopLevel, pause: draft.pause, controller: blocking, braise: holds,
                                red: draft.red, intensity: draft.intensity, brightness: draft.brightness,
                                refusal: BlockingNowComposer.refusal(span, freeze: false), started: { session = $0 }) {
            // A block session carries the mark; the red screen alone has no session: the mark keeps its own end.
            if let session { markSession(.block, id: session) }
            else { markSession(.own, id: UUID(), start: promised.start, end: promised.end) }
            recordLast()
            close()
        }
    }

    private func freeze() {
        guard let blocking else { return }
        blocking.recordGuardConsent()
        // Never later than the alert said: an end the engine would push back is refused (B01-R1-02).
        guard let end = pendingFreeze.end(at: Date()) else { // wall: page input; the controller moves it to its trusted frame
            blocking.error = BlockingNowComposer.refusal(span, freeze: true); return
        }
        blocking.startFreeze(until: end, mode: freezeMode, allowedApps: freezeMode == .shield ? kept : [])
        if blocking.freeze != nil { markSession(.own, id: UUID(), start: Date(), end: end); recordLast(); close() } // wall: same frame as `end`
    }

    /// Concentration: Pomodoro, or Continu with an intention. Without one, the session is named « Séance ».
    private func beginFocus() {
        guard let focus else { return }
        var mode = sessionDraft
        if mode.kind == .free { mode.free = .minutes(continuousMinutes(now: GoalongToday.now)) }
        let ids = chosenIDs
        do {
            focus.refresh()  // a new day replaces the plan before the link is checked
            try focus.startSession(intent: intent.isEmpty ? Self.defaultIntent : intent, mode: mode.mode,
                                   planItemId: focus.openPlanItemID(mode.planItemId), blockListIds: ids,
                                   blockDuringBreaks: mode.kind == .pomodoro && mode.blockDuringBreaks,
                                   lock: stopLevel == .locked && mode.canLock && !ids.isEmpty)
            sessionDraft.remember()
            if let id = focus.currentSession?.id { markSession(.focus, id: id) }
            recordLast()
            close()
        } catch {
            focus.error = FocusUIError.message(error)
        }
    }
}

extension BlockRuleEditor {
    /// The session's « Surveillance » choice, checked or not: Jev follows it, and the next session starts with it.
    func markSession(_ kind: JevSessionMark.Kind, id: UUID, start: Date? = nil, end: Date? = nil) {
        PreparedSessionLauncher.mark(kind, id: id, surveillance: draft.surveillance, lock: stopLevel, start: start, end: end)
    }
}

/// One slider of « Quoi » with its live preview (T-050 A2-7): each move shows the value and holds it; the release
/// keeps it `BraiseController.previewHold` seconds, then the real state comes back.
@MainActor private struct BlockRuleLevel: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let spoken: String
    let preview: (Double, Bool) -> Void
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(GoalongUIFormat.percent(value * 100)).monospacedDigit().foregroundStyle(LHTheme.secondaryText)
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                dragging = editing
                preview(value, editing)
            })
            .accessibilityLabel(spoken)
            .accessibilityValue("\(Int((value * 100).rounded())) pour cent")
            .onChange(of: value) { next in preview(next, dragging) }
        }
    }
}
#endif
