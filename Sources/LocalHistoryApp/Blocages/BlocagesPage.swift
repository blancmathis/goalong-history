#if os(macOS)
import Combine
import SwiftUI

/// Where a link lands in the page « Blocages ». The old pages (Concentration, Distractions, Garde-fous,
/// Écran rouge) are aliases of this one page. `redScreen` lands on the rules: the red ranges are rules (T-050 point 13).
enum BlocagesTarget: Hashable {
    case top, lists, sessions, redScreen, jev

    init(_ section: DashboardSection) {
        switch section {
        case .monitoring: self = .jev
        case .distractions: self = .lists
        case .concentration: self = .sessions
        case .braise: self = .redScreen
        default: self = .top
        }
    }
}

/// A request to show a part of the page: equal targets with another count are another request.
struct BlocagesRequest: Equatable {
    var target: BlocagesTarget
    var count: Int
}

/// The dépliants of the page. A dépliant builds its content only while it is open.
enum BlocagesFold: Hashable { case words, plan, commitments, pastSessions, protection, redSafety }

/// The one page of what Goalong blocks (docs/spec-blocages-20261110.md): what runs now, the rules, the lists,
/// the work sessions, then the protection. The engines stay the ones of Blocage, Concentration and Écran rouge.
@MainActor struct BlocagesPage: View {
    /// R14b: counts this body's evaluations in DashboardRestTests (off in the app).
    var bodyProbe = DashboardBodyProbe("blocages")
    let model: DashboardViewModel
    @ObservedObject var navigationStore: DashboardNavigation
    @ObservedObject private var blocking = BlockingRuntime.shared
    @ObservedObject private var braise = BraiseRuntime.shared
    @ObservedObject private var focus = ConcentrationRuntime.shared
    @ObservedObject private var modules = GoalongModuleStore.shared
    /// Counts the requests that lead to a part of the page: the same link opened twice scrolls twice.
    @State private var requests = 0

    init(model: DashboardViewModel) {
        self.model = model
        _navigationStore = ObservedObject(wrappedValue: model.navigationStore)
    }

    var body: some View {
        BlocagesPageContent(blocking: blocking.controller, braise: braise.controller,
                            focus: modules.isEnabled(.concentration) ? focus.controller : nil,
                            target: BlocagesTarget(navigationStore.selectedSection), request: requests,
                            onOpenRecording: { model.openRecordingSettings() },
                            onOpenWork: { model.selectSection(.work) },
                            onRuleClosed: { model.blockRuleEditorClosed() })
            .onReceive(navigationStore.sectionRequests) { section in
                if BlocagesTarget(section) != .top { requests += 1 }
            }
    }
}

@MainActor struct BlocagesPageContent: View {
    /// Nil = the module is off or did not start. The page still draws, with the way to turn it on.
    let blocking: BlockingController?
    let braise: BraiseController?
    let focus: ConcentrationController?
    /// Renders and tests pin the clock and the measures; the app follows the real ones.
    var now: Date?
    var measures: [FocusItemMeasure]?
    var target: BlocagesTarget
    /// Changes on each request for `target`, also the same one again.
    var request = 0
    /// Renders and tests fix the session draft; the app starts from the remembered one.
    var sessionDraft: FocusComposerDraft?
    var onOpenRecording: () -> Void
    var onOpenWork: () -> Void
    /// The editor of a rule closed, by any way (button, Échap, a link that leaves the page).
    var onRuleClosed: () -> Void
    @State private var open: Set<BlocagesFold>
    @State private var editing: BlockRuleEditor.Subject?
    @State private var editingList: UUID?
    @ObservedObject private var surveillance = JevSurveillanceStore.shared
    /// The prepared sessions (T-050 B2). Renders give their own store.
    let preparedStore: PreparedSessionStore

    init(blocking: BlockingController?, braise: BraiseController?, focus: ConcentrationController?,
         now: Date? = nil, measures: [FocusItemMeasure]? = nil, target: BlocagesTarget = .top, request: Int = 0,
         sessionDraft: FocusComposerDraft? = nil, open: Set<BlocagesFold> = [], editing: BlockRuleEditor.Subject? = nil,
         preparedStore: PreparedSessionStore = .shared,
         onOpenRecording: @escaping () -> Void = {}, onOpenWork: @escaping () -> Void = {},
         onRuleClosed: @escaping () -> Void = {}) {
        self.preparedStore = preparedStore
        self.blocking = blocking
        self.braise = braise
        self.focus = focus
        self.now = now
        self.measures = measures
        self.target = target
        self.request = request
        self.sessionDraft = sessionDraft
        self.onOpenRecording = onOpenRecording
        self.onOpenWork = onOpenWork
        self.onRuleClosed = onRuleClosed
        _open = State(initialValue: open)
        _editing = State(initialValue: editing)
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in // wall: display tick
            let now = self.now ?? GoalongToday.timeline(context.date)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
                        header
                        live(now: now)
                        rules(now: now).id(BlocagesTarget.top)
                        lists(now: now).id(BlocagesTarget.lists)
                        sessions(now: now, proxy: proxy).id(BlocagesTarget.sessions)
                        protection
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
                    .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, LHTheme.pageBottomInset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onAppearWhenShown { go(target, proxy: proxy) }
                .onChange(of: BlocagesRequest(target: target, count: request)) { value in go(value.target, proxy: proxy) }
            }
        }
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("blocages-page")
        // « Relancer » from the menu bar or the shortcut, when the session needs the window (a protected stop).
        .onReceive(preparedStore.$request) { session in
            guard let session else { return }
            editing = .prepared(session)
            DispatchQueue.main.async { preparedStore.request = nil }
        }
        // « Connecter Jev » inside the page opens the Jev rule, not another page.
        .environment(\.openJevSettings) { editing = .jev }
        // A link that opened a rule (Jev) is used up when the rule closes: the page does not open it again by itself.
        // Told at the close itself, not from `onChange`: a hidden kept page reads its changes late.
        .sheet(item: Binding(get: { editing }, set: { editing = $0; if $0 == nil { onRuleClosed() } })) { subject in
            BlockRuleEditor(subject: subject, blocking: blocking, braise: braise, focus: focus, now: now,
                            sessionDraft: sessionDraft, preparedStore: preparedStore, onOpenRecording: onOpenRecording, onOpenWork: onOpenWork,
                            onPrepareRed: { _ = BraiseRuntime.shared.ensureController() },
                            onClose: { editing = nil; onRuleClosed() })
                .goalongControls()
        }
        .sheet(isPresented: Binding(get: { editingList != nil }, set: { if !$0 { editingList = nil } })) {
            if let id = editingList, let blocking {
                BlockListSheet(controller: blocking, listID: id, now: now ?? GoalongToday.now) { editingList = nil }
                    .goalongControls()
            }
        }
    }

    /// A link to an old page lands on its part of this page. The plain entry keeps the scroll where it was.
    private func go(_ target: BlocagesTarget, proxy: ScrollViewProxy) {
        guard target != .top else { return }
        // Jev is a rule: its link (menu bar, notification, Réglages) opens the rule, where its settings are.
        if target == .jev { editing = .jev; return }
        let anchor = Self.anchor(target)
        DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
    }

    /// The part a target scrolls to. The red screen's ranges are rules: its links land on the list of rules.
    static func anchor(_ target: BlocagesTarget) -> BlocagesTarget {
        target == .redScreen ? .top : target
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Garde-fous").goalongPageTitle()
                Text("Ce que Goalong bloque, quand, et ce qu’il faut pour l’arrêter.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Lot 4 (13): the one lime action of the page sits in the header, like the other pages' actions.
            // ⌘N only opens the rule editor: nothing is written until the rule is saved there.
            Button { editing = .new } label: { Label("Nouvelle règle", systemImage: "plus") }
                .buttonStyle(LHPrimaryButtonStyle())
                .keyboardShortcut("n", modifiers: .command)
                .help("Nouvelle règle (⌘N)")
                .accessibilityIdentifier("blocages-new-rule")
        }
    }

    // MARK: En cours

    private func live(now: Date) -> some View {
        let liveClock = self.now == nil
        let sheetOpen = editing != nil || editingList != nil
        return ObservedOptional(object: focus) { focus in
            ObservedOptional(object: braise) { braise in
                ObservedOptional(object: blocking) { blocking in
                    BlocagesLive(blocking: blocking, braise: braise, focus: focus, now: now,
                                 liveClock: liveClock, showsError: !sheetOpen)
                }
            }
        }
    }

    // MARK: Règles

    private func rules(now: Date) -> some View {
        GoalongSection(title: "Règles", subtitle: "Une règle dit quand bloquer, quoi, et ce qu’il faut pour l’arrêter.", content: {
            ObservedOptional(object: blocking) { blocking in
                ObservedOptional(object: braise) { braise in
                    BlocagesRuleList(rules: BlockRules.current(blocking: blocking, braise: braise,
                                                               jev: surveillance.error == nil ? surveillance.document.ranges : [],
                                                               now: now), now: now,
                                     blocking: blocking, braise: braise, onEdit: { editing = $0 })
                }
            }
        })
    }

    // MARK: Listes

    private func lists(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let blocking {
                BlockingListsSection(controller: blocking, now: now, editing: $editingList)
            } else {
                GoalongSection(title: "Listes") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Les listes de sites et d’apps à bloquer viennent du module Garde-fous.")
                            .foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Activer Garde-fous") { GoalongModuleStore.shared.setEnabled(.blocking, true) }
                            .buttonStyle(LHSecondaryButtonStyle())
                            .accessibilityIdentifier("module-enable-blocking")
                    }
                }
            }
            if let focus { FocusDistractionSuggestionsCard(controller: focus) }
            BlocagesFoldView(open: $open, fold: .words, title: "Mots de distraction") {
                DistractionWordsSection().environment(\.goalongSectionTitleHidden, true)
                JevConnectHint(text: "Jev repère aussi les distractions qu’aucune liste ne contient, avec ces exemples.")
            }
        }
    }

    // MARK: Séances

    @ViewBuilder private func sessions(now: Date, proxy: ScrollViewProxy) -> some View {
        if let focus {
            BlocagesSessions(controller: focus, now: now, measures: measures, open: $open, proxy: proxy,
                             draft: sessionDraft, prepared: prepared, onStart: { editing = .session($0) })
        } else {
            BlocagesSessionsOff(prepared: prepared)
        }
    }

    private var prepared: PreparedSessionsList {
        PreparedSessionsList(store: preparedStore, lists: blocking?.lists ?? [],
                             launch: { [blocking, braise, focus, preparedStore] in
                                 PreparedSessionLauncher.launch($0, blocking: blocking, braise: braise, focus: focus,
                                                                store: preparedStore)
                             },
                             onOpen: { editing = .prepared($0) })
    }

    // MARK: Protection

    static let protectionSubtitle = "Ce qui empêche de contourner un blocage."
    static let redSafetyTitle = "Secours de l’écran rouge"
    /// The empty list of rules: the rule of Jev stays under it, so it says « autre » (T-050 point 15).
    static let noRuleText = "Aucune autre règle. Partez d’un modèle, ou de « Nouvelle règle » : toujours, à des horaires, ou le temps d’une séance."

    private var protection: some View {
        GoalongSection(title: "Protection", subtitle: Self.protectionSubtitle, trailing: {
            if let blocking { BlockingProtectionPill(controller: blocking) }
        }, content: {
            VStack(alignment: .leading, spacing: 4) {
                if let blocking {
                    BlocagesFoldView(open: $open, fold: .protection, title: "Mot de passe, navigateurs, garde") {
                        BlockingProtectionDetails(controller: blocking).environment(\.goalongSectionTitleHidden, true)
                    }
                }
                // T-050 point 10: the manual red and its brightness live in the menu bar; a held brightness is a rule.
                if let braise {
                    BlocagesFoldView(open: $open, fold: .redSafety, title: Self.redSafetyTitle, summary: "⌃ ⌥ ⌘ R") {
                        BraisePageContent(controller: braise, showsTitle: false, part: .safety)
                    }
                } else {
                    BlocagesRedOff().padding(.top, 6)
                }
            }
        })
    }
}

// MARK: - Dépliant

/// One folded row of the page. The content exists only while the row is open (first click under 100 ms).
struct BlocagesFoldView<Content: View>: View {
    @Binding var open: Set<BlocagesFold>
    let fold: BlocagesFold
    let title: String
    var summary: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        GoalongDisclosureGroup(title, isExpanded: Binding(
            get: { open.contains(fold) },
            set: { on in if on { open.insert(fold) } else { open.remove(fold) } })) {
            if open.contains(fold) {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.top, 12).padding(.bottom, 8)
            }
        }
        .collapsedSummary(summary)
    }
}

// MARK: - En cours

/// What runs now: the work session, the blocks and what is planned, the red screen and a held brightness.
/// Each keeps its own stop path, the one of its engine.
@MainActor private struct BlocagesLive: View {
    let blocking: BlockingController?
    let braise: BraiseController?
    let focus: ConcentrationController?
    let now: Date
    let liveClock: Bool
    let showsError: Bool

    var body: some View {
        let session = focus?.currentSession
        let redLive = braise.map(BraisePageContent.hasLive) ?? false
        let blocksLive = blocking.map { controller in
            controller.activeBlocks.contains { $0.end > now } || (controller.freeze.map { $0.end > now } ?? false)
        } ?? false
        VStack(alignment: .leading, spacing: 22) {
            if let focus, let session {
                FocusActiveSession(controller: focus, session: session, now: now, live: liveClock)
            }
            if let blocking {
                // « Rien n’est bloqué » only when nothing else runs: a session or the red screen says it better.
                BlocagesLiveBlocks(controller: blocking, now: now,
                                   showsHero: blocksLive || (session == nil && !redLive), showsError: showsError)
            } else if session == nil, !redLive {
                Text("Rien n’est bloqué.").font(LHTheme.sectionTitleFont).tracking(-0.2)
                    .accessibilityIdentifier("blocages-idle")
            }
            if let braise, redLive {
                BraisePageContent(controller: braise, showsTitle: false, part: .live)
            }
            BlocagesWatchLive(now: now)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One listener per window: it opens the stop sheet that the menu or the shortcut asks for.
        .background { if let braise { BraisePageContent(controller: braise, showsTitle: false, part: .listener) } }
    }
}

/// The blocks of Blocage, as on its old page: the hero, what is planned, the error, and the stop sheets.
@MainActor private struct BlocagesLiveBlocks: View {
    @ObservedObject var controller: BlockingController
    let now: Date
    let showsHero: Bool
    let showsError: Bool
    @State private var stopping: BlockingStopRequest?
    @State private var unlocking: BlockingStopRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showsHero {
                BlockingStateHero(controller: controller, now: now,
                                  onStop: { stopping = BlockingStopRequest(id: $0.id, what: "") },
                                  onUnlock: { block in
                                      unlocking = BlockingStopRequest(id: block.id, what: unlockText(block.origin, end: block.end))
                                  },
                                  onExtraBreak: { controller.extraBreakRequest = $0.id })
            }
            BlockingScheduledList(controller: controller, now: now,
                                  onTyping: { stopping = BlockingStopRequest(id: $0.id, what: "") },
                                  onPassword: { session in
                                      unlocking = BlockingStopRequest(id: session.id,
                                          what: "Le blocage prévu \(BlockingFormat.moment(session.start, now: now)) sera annulé.")
                                  })
            if let error = controller.error, showsError {
                BlockingNoteButton(note: GoalongNote(error, tone: .warning), hint: "Fermer l’erreur") { controller.error = nil }
                    // The whole notice is the close button: VoiceOver says the error and what a press does.
                    .accessibilityLabel("\(error). Fermer l’erreur")
                    .accessibilityIdentifier("blocking-error")
            }
        }
        .sheet(item: $unlocking) { request in
            BlockingPasswordSheet(controller: controller, purpose: .unlock(request.id, what: request.what)) { unlocking = nil }
                .goalongControls()
        }
        .sheet(item: Binding(get: { controller.extraBreakRequest.flatMap(controller.list).map(extraBreakRequest) },
                             set: { if $0 == nil { controller.extraBreakRequest = nil } })) { request in
            BlockingPasswordSheet(controller: controller, purpose: .extraBreak(request.id, what: request.what)) { controller.extraBreakRequest = nil }
                .goalongControls()
        }
        .sheet(item: Binding(get: { controller.pauseTypingRequest.flatMap(controller.list) },
                             set: { if $0 == nil { controller.pauseTypingRequest = nil } })) { list in
            BlockingTypingChallengeSheet(text: controller.pauseTypingChallenge(listID: list.id), purpose: .pause) { typed in
                controller.takeBreak(listID: list.id, typed: typed)
                controller.pauseTypingRequest = nil
            } onCancel: { controller.pauseTypingRequest = nil }
            .goalongControls()
        }
        .sheet(item: $stopping) { block in
            BlockingTypingChallengeSheet(text: controller.typingChallenge(for: block.id)) { typed in
                controller.stop(block.id, typed: typed)
                stopping = nil
            } onCancel: { stopping = nil }
            .goalongControls()
        }
    }

    private func extraBreakRequest(_ list: BlockList) -> BlockingStopRequest {
        BlockingStopRequest(id: list.id, what: controller.pausePasswordText(listID: list.id))
    }

    private func unlockText(_ origin: BlockSession.Origin, end: Date) -> String {
        if case .program = origin { return "Cette plage du programme s’arrête pour aujourd’hui. Elle revient la prochaine fois." }
        return "Débloquer arrête ce blocage prévu jusqu’à \(BlockingFormat.endTime(end))."
    }
}

// MARK: - Règles

/// The rules, one row each, then the rule of Jev. A row opens the one editor; its switch turns it on at once and off
/// through its stop (S2, P3); right click and double click give its actions (A8). No rule: the four templates (A1).
@MainActor private struct BlocagesRuleList: View {
    let rules: [BlockRule]
    let now: Date
    let blocking: BlockingController?
    let braise: BraiseController?
    let onEdit: (BlockRuleEditor.Subject) -> Void
    @State private var typing: (rule: BlockRule, text: String)?
    @State private var asking: BlockRule?
    @State private var password = ""
    @State private var deleting: BlockRule?
    @State private var refusal: String?

    var body: some View {
        LHCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if rules.isEmpty {
                    Text(BlocagesPageContent.noRuleText)
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, LHTheme.cardInset).padding(.top, 14)
                        .accessibilityIdentifier("blocages-no-rule")
                    BlockRuleTemplatesRow(lists: blocking?.lists ?? []) { onEdit(.preset($0)) }
                        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 10)
                    GoalongRowDivider(inset: LHTheme.cardInset)
                }
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    row(rule, index: index)
                    GoalongRowDivider(inset: LHTheme.cardInset)
                }
                BlocagesJevRow { onEdit(.jev) }
            }
        }
        .sheet(isPresented: Binding(get: { typing != nil }, set: { if !$0 { typing = nil } })) {
            if let typing {
                BlockingTypingChallengeSheet(text: typing.text, onSubmit: { typed in
                    self.typing = nil
                    finish(typing.rule, .typed(typed, challenge: typing.text))
                }, onCancel: { self.typing = nil })
            }
        }
        .alert("Éteindre cette règle ?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            SecureField("Mot de passe de blocage", text: $password)
            Button("Éteindre", role: .destructive) { if let rule = asking { finish(rule, .password(password)) }; password = "" }
            Button("Annuler", role: .cancel) { password = "" }
        } message: { Text("Son arrêt demande le mot de passe de blocage.") }
        .alert("Supprimer cette règle ?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Supprimer", role: .destructive) { if let rule = deleting { delete(rule) } }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Les listes restent. Seules leurs plages à ces heures sont retirées.") }
        .alert(refusal ?? "", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func row(_ rule: BlockRule, index: Int) -> some View {
        let state = BlockRuleSwitch.of(rule, canVerifyPassword: blocking != nil)
        return HStack(spacing: 0) {
            Button { onEdit(.rule(rule)) } label: {
                BlocagesRuleRow(title: rule.summary, summary: rule.title, lock: rule.lock.title, lockSymbol: rule.lock.symbol,
                                state: rule.stateText(now: now), running: rule.isRunning)
            }
            .buttonStyle(LHNavigationButtonStyle(cornerRadius: 0))
            .accessibilityLabel(rule.spokenLabel(now: now))
            .accessibilityHint("Ouvre la règle")
            .accessibilityIdentifier("blocages-rule-\(index)")
            if state != .hidden {
                Toggle("Règle active", isOn: Binding(get: { state != .off }, set: { toggle(rule, on: $0) }))
                    .labelsHidden().toggleStyle(.goalongSwitch)
                    .padding(.trailing, LHTheme.cardInset)
                    .accessibilityIdentifier("blocages-rule-switch-\(index)")
            }
        }
        .contextMenu {
            Button("Modifier…") { onEdit(.rule(rule)) }
            Button("Dupliquer…") { onEdit(.preset(BlockRulePreset(copying: rule))) }
            if state != .hidden { Button(state == .off ? "Allumer" : "Éteindre") { toggle(rule, on: state == .off) } }
            Divider()
            Button("Supprimer…", role: .destructive) { deleting = rule }
        }
    }

    /// On: at once. Off: through the rule's stop.
    private func toggle(_ rule: BlockRule, on: Bool) {
        if on { refusal = BlockRuleSwitchAction.turnOn(rule, braise: braise); return }
        guard case .on(let stop) = BlockRuleSwitch.of(rule, canVerifyPassword: blocking != nil) else { return }
        switch stop {
        case .typing: typing = (rule, BlockRuleSwitchAction.challenge(rule, blocking: blocking))
        case .password: asking = rule
        case .free, .locked: finish(rule, .none)
        }
    }

    private func finish(_ rule: BlockRule, _ proof: BlockRuleStopProof) {
        refusal = BlockRuleSwitchAction.turnOff(rule, proof: proof, blocking: blocking, braise: braise)
    }

    private func delete(_ rule: BlockRule) {
        let writes = BlockRulePlan.writes(nil, replacing: rule, lists: blocking?.lists ?? [], red: braise?.ranges)
        refusal = BlockRulePlan.apply(writes, blocking: blocking, braise: braise, surveillance: .shared)
    }
}

/// The four starts of a rule (A1): each opens the editor already filled; nothing is saved before « Enregistrer ».
@MainActor struct BlockRuleTemplatesRow: View {
    let lists: [BlockList]
    let onPick: (BlockRulePreset) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 6) { buttons }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blocages-templates")
    }

    private var buttons: some View {
        ForEach(BlockRulePreset.templates(lists: lists), id: \.id) { preset in
            Button(preset.title) { onPick(preset) }
                .buttonStyle(LHSecondaryButtonStyle())
                .accessibilityIdentifier("blocages-template-\(preset.id)")
        }
    }
}

private extension BlockRule {
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
}

/// A session with « Surveillance » and no block session of its own (T-050 B1): it says until when. « Arrêter » asks its
/// stop (« Taper », « Mot de passe »); « Verrouillé » stays until its end.
@MainActor struct BlocagesWatchLive: View {
    @ObservedObject private var store = JevSurveillanceStore.shared
    let now: Date

    var body: some View {
        if let mark = store.runningOwn(now: now), let end = mark.end {
            HStack(spacing: 12) {
                Text("Surveillance \(BlockingFormat.until(end, now: now))").font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if Self.canStop(mark.lock) {
                    Button("Arrêter") {
                        Self.stop(mark, store: store, now: GoalongToday.now) {
                            JevStopGate.confirm(action: "Arrêter la surveillance", step: $0)
                        }
                    }
                        .buttonStyle(LHSecondaryButtonStyle())
                        .accessibilityIdentifier("blocages-watch-stop")
                } else {
                    Text(mark.lock.title).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("blocages-watch-live")
        }
    }

    static func canStop(_ lock: BlockLock) -> Bool { lock != .locked }

    /// Ends the session once its stop is passed. `confirm` asks it (an alert in the app); Jev off asks nothing.
    static func stop(_ mark: JevSessionMark, store: JevSurveillanceStore, now: Date,
                     jevEnabled: Bool? = nil, confirm: (JevStopGate.Step) -> Bool) {
        guard canStop(mark.lock) else { return }
        let step = JevStopGate.step(lock: mark.lock, jevEnabled: jevEnabled ?? JevMonitor.shared.enabled)
        guard !JevStopGate.needsAsking(step) || confirm(step) else { return }
        store.endOwn(mark.id, now: now)
    }
}

/// The settings that every rule with « Surveillance » shares: consent, connection, work context (T-050 B1 point 8).
@MainActor struct BlocagesJevRow: View {
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    let action: () -> Void
    static let summary = "Accord d’envoi et contexte de travail, communs à chaque règle avec « Surveillance »"
    static let kind = "Réglages communs"

    var body: some View {
        let on = consents.isEnabled(.jevMonitoring)
        let state = on ? "Autorisée" : "Non autorisée"
        Button(action: action) {
            BlocagesRuleRow(title: BlockRuleEditor.jevTitle, summary: Self.summary, lock: Self.kind,
                            state: state, running: on)
        }
        .buttonStyle(LHNavigationButtonStyle(cornerRadius: 0))
        .accessibilityLabel("\(BlockRuleEditor.jevTitle). \(Self.summary). \(Self.kind). \(state).")
        .accessibilityHint("Ouvre les réglages")
        .accessibilityIdentifier("blocages-rule-jev")
    }
}

/// What first, then when, on the left; the stop level (an icon, its name on hover) and the state on the right.
private struct BlocagesRuleRow: View {
    let title: String
    let summary: String
    let lock: String
    var lockSymbol: String? = nil
    let state: String
    let running: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if let lockSymbol {
                    Image(systemName: lockSymbol).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LHTheme.secondaryText).help("Arrêt : \(lock)")
                        .accessibilityLabel("Arrêt : \(lock)")
                }
                VStack(alignment: .trailing, spacing: 3) {
                    if lockSymbol == nil { Text(lock).font(.system(size: 12, weight: .medium)) }
                    Text(state).font(.system(size: 12, weight: running ? .medium : .regular))
                        .foregroundStyle(running ? LHTheme.text : LHTheme.secondaryText)
                }
                .multilineTextAlignment(.trailing)
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LHTheme.tertiaryText).accessibilityHidden(true)
        }
        .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Séances

/// Concentration in the page: start a session, then the plan, the commitments and the past sessions, folded.
@MainActor private struct BlocagesSessions: View {
    @ObservedObject var controller: ConcentrationController
    @ObservedObject private var runtime = ConcentrationRuntime.shared
    let now: Date
    var measures: [FocusItemMeasure]?
    @Binding var open: Set<BlocagesFold>
    let proxy: ScrollViewProxy
    let prepared: PreparedSessionsList
    let onStart: (FocusComposerDraft) -> Void
    @State private var draft: FocusComposerDraft
    @State private var reviewing = false
    @State private var editingCommitment: FocusCommitmentEditRequest?
    @State private var settingsOpen = false
    @FocusState private var addFocused: Bool

    /// `draft` nil = the remembered one (the app). A render gives a fixed one: it reads no preference.
    init(controller: ConcentrationController, now: Date, measures: [FocusItemMeasure]?, open: Binding<Set<BlocagesFold>>,
         proxy: ScrollViewProxy, draft: FocusComposerDraft?, prepared: PreparedSessionsList,
         onStart: @escaping (FocusComposerDraft) -> Void) {
        _controller = ObservedObject(wrappedValue: controller)
        self.prepared = prepared
        self.now = now
        self.measures = measures
        _open = open
        self.proxy = proxy
        self.onStart = onStart
        _draft = State(initialValue: draft ?? .remembered())
    }

    var body: some View {
        GoalongSection(title: "Séances", subtitle: "Une séance de travail ou un Pomodoro, avec ou sans blocage.", trailing: {
            FocusStatusLabel(status: controller.status)
        }, content: {
            VStack(alignment: .leading, spacing: 12) {
                if controller.currentSession == nil {
                    Button { onStart(draft) } label: { Label("Lancer une séance…", systemImage: "play") }
                        .buttonStyle(LHSecondaryButtonStyle())
                        .accessibilityIdentifier("blocages-start-session")
                }
                prepared
                if let error = controller.error {
                    GoalongNote(FocusUIError.message(raw: error), tone: .warning)
                        .onTapGesture { controller.error = nil }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Masquer ce message")
                        .accessibilityAction(named: "Masquer") { controller.error = nil }
                        .accessibilityIdentifier("concentration-error")
                }
                if let note = ConcentrationPageContent.measurementNote(runtime.measurementError) {
                    GoalongNote(note, tone: .warning).accessibilityIdentifier("concentration-measurement-error")
                }
                VStack(alignment: .leading, spacing: 4) {
                    BlocagesFoldView(open: $open, fold: .plan, title: "Plan du jour", summary: planSummary) {
                        FocusPlanSection(controller: controller, now: now, measures: measures ?? controller.itemMeasures,
                                         draft: $draft, addFocused: $addFocused, onReview: { reviewing = true })
                            .environment(\.goalongSectionTitleHidden, true)
                    }
                    .id("plan")
                    BlocagesFoldView(open: $open, fold: .commitments, title: "Engagements et limites") {
                        FocusCommitmentsSection(controller: controller, now: now, onEdit: { editingCommitment = $0 })
                            .environment(\.goalongSectionTitleHidden, true)
                        FocusSettingsSection(controller: controller, open: $settingsOpen)
                    }
                    BlocagesFoldView(open: $open, fold: .pastSessions, title: "Séances passées et bilan du soir") {
                        FocusSessionsSection(controller: controller, now: now)
                            .environment(\.goalongSectionTitleHidden, true)
                        if !controller.sessions.contains(where: { $0.endedAt != nil }) {
                            Text("Aucune séance terminée aujourd’hui.").foregroundStyle(LHTheme.secondaryText)
                        }
                        Button(controller.review == nil ? "Faire le bilan du soir" : "Modifier le bilan du soir") { reviewing = true }
                            .buttonStyle(LHQuietButtonStyle())
                            .accessibilityIdentifier("blocages-open-review")
                    }
                }
            }
        })
        // A plan item's « Démarrer » opens the editor on a session for it.
        .onChange(of: draft.planItemId) { id in
            guard id != nil else { return }
            onStart(draft)
            draft.planItemId = nil
        }
        .onAppearWhenShown { openRequested(controller.requestedEditor) }
        .onChange(of: controller.requestedEditor) { kind in openRequested(kind) }
        .sheet(isPresented: $reviewing) {
            ConcentrationReviewSheet(controller: controller, plan: controller.plan, review: controller.review,
                                     onClose: { reviewing = false })
                .goalongControls()
        }
        .sheet(item: $editingCommitment) { request in
            FocusCommitmentEditor(controller: controller, request: request, now: GoalongToday.now, onClose: { editingCommitment = nil })
                .goalongControls()
        }
    }

    private var planSummary: String {
        let items = controller.plan.items
        let left = items.filter { $0.status == .open }.count
        if items.isEmpty { return "Vide" }
        return left == 0 ? "Tout est fait" : "\(left) à faire"
    }

    /// « Faire maintenant » from a prompt: the morning goes to the plan, the evening opens the review.
    private func openRequested(_ kind: FocusPanel.Kind?) {
        guard let kind else { return }
        if kind == .evening {
            reviewing = true
        } else {
            open.insert(.plan)
            DispatchQueue.main.async {
                proxy.scrollTo("plan", anchor: .top)
                addFocused = true
            }
        }
        controller.dismissEditor()
    }
}

/// Concentration is off, or it did not start: one sentence and the way out, never a lime button.
@MainActor private struct BlocagesSessionsOff: View {
    @ObservedObject private var runtime = ConcentrationRuntime.shared
    @ObservedObject private var modules = GoalongModuleStore.shared
    let prepared: PreparedSessionsList

    var body: some View {
        GoalongSection(title: "Séances") {
            if modules.isEnabled(.concentration), runtime.error != nil {
                GoalongNote("Concentration n’a pas pu démarrer. Vos données restent intactes.", tone: .warning)
                    .accessibilityIdentifier("blocages-sessions-failed")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    prepared
                    Text("Les séances de travail, le plan du jour et le bilan du soir viennent du module Concentration.")
                        .foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Activer Concentration") { GoalongModuleStore.shared.setEnabled(.concentration, true) }
                        .buttonStyle(LHSecondaryButtonStyle())
                        .accessibilityIdentifier("module-enable-concentration")
                }
            }
        }
    }
}

// MARK: - Protection

/// The red screen was never used on this Mac: nothing runs for it until it is turned on or put in a rule.
@MainActor struct BlocagesRedOff: View {
    @ObservedObject private var runtime = BraiseRuntime.shared
    /// T-050 point 13: the manual red is in the menu Goalong, the ranges are rules; nothing turns it on « ici ».
    static let text = "Écran rouge éteint. Il s’allume dans une règle (« Nouvelle règle », bloc « Écran rouge ») ou depuis le menu Goalong."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = runtime.error {
                GoalongNote("L’écran rouge n’a pas pu démarrer. \(error)", tone: .warning)
                    .accessibilityIdentifier("blocages-red-failed")
                Button("Réessayer") { runtime.retry() }.buttonStyle(LHSecondaryButtonStyle())
            } else {
                Text(Self.text)
                    .foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allumer l’écran rouge") { runtime.setRedScreen(true) }
                    .buttonStyle(LHSecondaryButtonStyle())
                    .accessibilityIdentifier("braise-enable")
            }
        }
    }
}
#endif
