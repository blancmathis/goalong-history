#if os(macOS)
import AppKit
import Combine
import Foundation
import LocalHistoryCore
import SwiftUI

/// « Définition du travail »: the user's own definition of work, the agent that applies it, and the
/// review where every verdict can be corrected. Goalong never rates an app or a site.
/// It is no page of its own (spec-blocages-20261110 § 6): it is a pane of Réglages, and Activité opens it in a sheet.
@MainActor struct GoalongWorkPage: View {
    /// Where the content is drawn. Its host brings the title, the scrolling and the insets.
    enum Placement { case settings, sheet }
    /// R14b: counts this body's evaluations in DashboardRestTests (off in the app).
    /// The copy in Activité's sheet counts under its own name: it is not the pane.
    var bodyProbe: DashboardBodyProbe
    /// R-45 (R4d-25): two sentences, the cause then what it changes.
    static let withheldTitlesNotice = "Vos choix « Données pour ChatGPT » excluent les titres de fenêtre. Le classement ne distingue alors deux usages d’une même app que par le site."
    static let subtitle = "Vous décidez de ce qui compte comme travail. Goalong ne juge jamais une app ou un site : le classement automatique (ChatGPT) applique votre définition, et vous répondez quand il ne sait pas."
    /// The sheet of Activité that shows this page now, if any. Weak: a sheet that goes away without
    /// `onDisappear` still frees it.
    static weak var openSheet: GoalongWorkSheetToken?
    let model: DashboardViewModel
    private let placement: Placement
    private var inSheet: Bool { placement == .sheet }
    @ObservedObject var snapshotStore: DashboardSnapshotStore

    init(model: DashboardViewModel, placement: Placement) {
        self.model = model
        self.placement = placement
        bodyProbe = DashboardBodyProbe(placement == .sheet ? "travail-feuille" : "travail")
        _snapshotStore = ObservedObject(wrappedValue: model.snapshotStore)
    }
    @ObservedObject private var work = GoalongWorkStore.shared
    @ObservedObject private var agent = GoalongWorkAgent.shared
    @ObservedObject private var definition = JevWorkContextStore.shared
    @ObservedObject private var runtime = ChatGPTRecapRuntime.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @StateObject private var review = GoalongWorkReviewModel()
    @State private var confirmingConsent = false
    @State private var confirmingForget = false
    @State private var classifyWhenConnected = false
    #if DEBUG
    /// Test gallery only: the review opens already loaded, this task unfolded (the page shows it closed).
    static var galleryReviewFocusTask: String?
    private static var reviewFocusTask: String? { galleryReviewFocusTask }
    #else
    private static var reviewFocusTask: String? { nil }
    #endif

    /// The definition, the agent, the review, then how the classification works.
    private var parts: some View {
        VStack(alignment: .leading, spacing: 24) {
            JevWorkContextControls(purpose: .workDefinition)
            if !work.definition.isEmpty {
                agentCard
                GoalongWorkAnswersCard()
                GoalongWorkUsageCard()
                GoalongWorkReviewCard(review: review, focusTask: Self.reviewFocusTask,
                                      loadsOnAppear: Self.reviewFocusTask != nil,
                                      earliestDay: snapshotStore.snapshot.availableDays.min())
            }
            GoalongDisclosureGroup("Comment fonctionne le classement ?") { explanation.padding(.top, 10) }
                .font(.system(size: 13))
        }
        .font(.system(size: 13))
    }

    var body: some View {
        Group {
            switch placement {
            // Réglages draws the title, scrolls and sets the insets, as for every pane.
            case .settings: parts
            case .sheet:
                ScrollView {
                    parts.frame(maxWidth: LHTheme.readableWidth, alignment: .leading).padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(LHTheme.pageBackground)
                .accessibilityIdentifier("work-sheet-content")
            }
        }
        .onAppearWhenShown { runtime.refreshAccount() }
        .onReceive(NotificationCenter.default.publisher(for: .jevWorkContextDidChange)) { _ in
            // A new definition is a reason to check the background schedule now, within its daily
            // limits. The pane of Réglages and Activité's sheet can both hear the change: while the sheet
            // is open only the sheet answers, so the check runs once, not twice.
            if work.backgroundConsent, inSheet || Self.openSheet == nil { agent.backgroundTick() }
        }
        .onChange(of: runtime.connectionState) { state in
            guard classifyWhenConnected, case .connected = state else { return }
            classifyWhenConnected = false
            agent.classify(day: GoalongToday.now)
        }
        .onChange(of: agent.isRunning) { running in
            if !running, let day = review.loadedDay { review.load(day: day) }
        }
        .alert("Autoriser ChatGPT à classer votre temps ?", isPresented: $confirmingConsent) {
            Button("Annuler", role: .cancel) {}
            Button("Autoriser") {
                // The background pass has its own consent, off by default: this one allows the manual pass.
                if consents.set(.chatGPTAnalysis, enabled: true, surface: .settings) {
                    // The account state was not checked while analysis was off.
                    classifyWhenConnected = true
                    runtime.refreshAccount(userInitiated: true)
                }
            }
        } message: {
            Text("Pour chaque contexte nouveau, Goalong envoie à votre compte ChatGPT le nom de l’app, le site et le titre de la fenêtre, avec sa durée, ainsi que votre définition du travail. Jamais ce que vous tapez, ni de capture d’écran. Vos exclusions et vos choix « Données pour ChatGPT » s’appliquent. Cela active aussi l’autorisation générale Analyse ChatGPT, réglable dans Réglages.")
        }
        .confirmationDialog("Tout reclasser avec votre définition actuelle ?", isPresented: $confirmingForget) {
            Button("Tout reclasser") { work.forgetAgentVerdicts(); agent.classify(day: GoalongToday.now) }
        } message: {
            Text(["Les verdicts du classement automatique sont effacés et les contextes seront renvoyés au fil de vos consultations d’Activité. Vos corrections sont conservées, ainsi que les contextes d’une tâche suivie par un engagement Concentration en cours.",
                  FocusCommitmentRules.reclassifyWarning(GoalongWorkStore.openCommitments(controller: ConcentrationRuntime.shared.controller, store: .standard),
                                                         at: GoalongToday.now)].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private var agentCard: some View {
        GoalongSettingsGroup(title: "Classement automatique") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol).font(.system(size: 14, weight: .medium)).foregroundStyle(statusTint)
                    .frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.system(size: 13, weight: .semibold))
                    if let detail = statusDetail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                statusAction
            }
            // Without consent, or with the history off, the switch reads off whatever the stored preference says (UI-69, UI-9 C).
            // Consent is read directly (DEF-02/DEF-05): readiness may report history off before a missing consent,
            // and an empty definition before a history turned off (P-3).
            let canClassify = Self.canClassify(analysisConsent: consents.isEnabled(.chatGPTAnalysis),
                historyConsent: consents.isEnabled(.localComputerHistory), historyOff: agent.readiness == .historyOff)
            Toggle("Classer en arrière-plan",
                   isOn: Binding(get: { Self.automaticSwitchShowsOn(automatic: work.backgroundConsent, consented: canClassify) },
                                 set: { work.backgroundConsent = $0 }))
                .toggleStyle(.goalongSwitch).disabled(!canClassify)
                .accessibilityIdentifier("work-automatic")
            Text(GoalongWorkPage.backgroundConsentText)
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory),
                                        selection: GoalongAnalysisSelection.load()).withholdsTitles {
                Label(GoalongWorkPage.withheldTitlesNotice, systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if work.hasAgentVerdicts {
                Button("Tout reclasser…") { confirmingForget = true }.buttonStyle(LHQuietButtonStyle())
                    .font(.system(size: 12)).disabled(agent.isRunning)
            }
        }
    }

    /// The background consent: rhythm, cap and data sent. The old « automatic » switch never counts.
    static let backgroundConsentText = "Au plus \(GoalongWorkSchedule.backgroundCallsPerDay) envois par jour, vers 12 h 30 et 18 h 30 ou dès \(GoalongWorkSchedule.backlogTrigger) groupes de contextes en attente, dans la limite de \(GoalongWorkSchedule.dailyTokenCap.formatted(.number.locale(Locale(identifier: "fr_FR")))) jetons par jour, passage manuel compris. Pour chaque groupe nouveau : nom de l’app, site, titre de la fenêtre et durée, avec votre définition du travail et quelques-unes de vos réponses. Jamais ce que vous tapez, ni de capture d’écran. Vos exclusions s’appliquent ; rien ne part en pause, ni près de la limite du compte."

    /// Without consent nothing is classified: the switch reads off, whatever choice it will restore.
    /// Consent is read directly: `readiness` reports an empty definition or history off first.
    nonisolated static func canClassify(analysisConsent: Bool, historyConsent: Bool, historyOff: Bool) -> Bool {
        analysisConsent && historyConsent && !historyOff
    }

    nonisolated static func automaticSwitchShowsOn(automatic: Bool, consented: Bool) -> Bool {
        automatic && consented
    }

    private var statusSymbol: String {
        var checking = false
        if case .checking = runtime.connectionState { checking = true }
        return Self.statusSymbol(running: agent.isRunning, failed: agent.lastError != nil, readiness: agent.readiness, checking: checking)
    }
    /// R-83 (R4d-12): one symbol per status title, so two states never share an icon.
    nonisolated static func statusSymbol(running: Bool, failed: Bool, readiness: GoalongWorkAgent.Readiness, checking: Bool) -> String {
        if running { return "sparkles" }
        if failed { return "exclamationmark.triangle" }
        switch readiness {
        case .ready: return "checkmark.circle"
        case .noConsent: return "hand.raised"
        case .notConnected: return checking ? "arrow.triangle.2.circlepath" : "person.crop.circle.badge.xmark"
        case .historyOff: return "clock.badge.xmark"
        case .paused: return "pause.circle"
        case .noDefinition: return "square.and.pencil"
        }
    }
    private var statusTint: Color {
        if agent.lastError != nil && !agent.isRunning { return LHTheme.warning }
        return agent.readiness == .ready || agent.isRunning ? LHTheme.accent : LHTheme.secondaryText
    }
    private var statusTitle: String {
        if agent.isRunning { return "Classement en cours" }
        switch agent.readiness {
        case .ready: return "Prêt, votre compte ChatGPT"
        case .noConsent: return "Classement non autorisé"
        case .notConnected:
            if case .checking = runtime.connectionState { return "Vérification de ChatGPT…" }
            return "ChatGPT non connecté"
        case .historyOff: return "Historique désactivé"
        case .paused: return "En pause"
        case .noDefinition: return "Définition manquante"
        }
    }
    private var statusDetail: String? {
        if agent.isRunning { return agent.progress }
        if let error = agent.lastError { return error }
        if agent.readiness != .ready { return agent.readiness.message }
        return agent.lastOutcome ?? "Les contextes nouveaux sont classés automatiquement, deux fois par jour au plus, si vous l’avez autorisé ci-dessus."
    }
    @ViewBuilder private var statusAction: some View {
        if agent.isRunning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Button("Arrêter") { agent.cancel() }.buttonStyle(LHSecondaryButtonStyle())
            }
        } else {
            switch agent.readiness {
            case .noConsent:
                Button("Autoriser…") { confirmingConsent = true }.buttonStyle(LHPrimaryButtonStyle())
                    .accessibilityIdentifier("work-allow")
            case .notConnected:
                if case .codexUnavailable = runtime.connectionState {
                    Button("Mettre Goalong à jour") { SoftwareUpdateManager.shared.showAvailableUpdate() }.buttonStyle(LHSecondaryButtonStyle())
                } else if case .checking = runtime.connectionState {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        if runtime.isConnecting {
                            Button("Annuler") { classifyWhenConnected = false; runtime.cancelChatGPTConnection() }.buttonStyle(LHSecondaryButtonStyle())
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        if runtime.isConnecting {
                            Button("Annuler") { classifyWhenConnected = false; runtime.cancelChatGPTConnection() }.buttonStyle(LHSecondaryButtonStyle())
                        }
                        Button(runtime.isConnecting ? "Connexion…" : "Connecter ChatGPT") {
                            classifyWhenConnected = true
                            runtime.connectChatGPT()
                        }
                            .buttonStyle(LHPrimaryButtonStyle()).disabled(runtime.isConnecting)
                    }
                }
            case .historyOff:
                Button("Ouvrir les réglages") { model.openRecordingSettings() }.buttonStyle(LHSecondaryButtonStyle())
            case .ready:
                Button("Lancer un passage maintenant") { agent.classify(day: GoalongToday.now) }.buttonStyle(LHSecondaryButtonStyle())
                    .accessibilityIdentifier("work-classify-today")
            case .paused, .noDefinition:
                EmptyView()
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("1. Goalong découpe votre journée en contextes : une app, un site et un titre de fenêtre. La même app donne donc plusieurs contextes — un document de travail et une vidéo ne se confondent pas.")
            Text("2. Le classement automatique (ChatGPT, avec votre compte, sans aucun outil ni accès à vos fichiers) lit votre définition et chaque contexte nouveau, avec l’ordre de la journée pour les cas ambigus. Il répond Travail avec le nom de la tâche, Pas du travail, ou « à préciser » s’il ne peut pas trancher : c’est alors à vous de répondre dans Activité.")
            Text("3. Les verdicts sont gardés sur ce Mac et appliqués à tout l’historique, sans modifier les journaux. Un contexte déjà classé n’est jamais renvoyé ; changer la définition relance le classement. Vos réponses priment toujours et servent d’exemples au classement automatique ; la plus précise gagne (contexte, puis site, puis app).")
            Text("4. Une tâche reste la même d’une app à l’autre : passer de l’éditeur au navigateur pour le même projet garde votre session de travail. Un détour de moins d’une minute entre deux moments de la même tâche lui est rattaché.")
            Text("Rien n’est envoyé pour les apps et sites exclus, ni pour les apps retirées de « Données pour ChatGPT ». Les contextes très courts (moins de 15 s) ne sont pas envoyés.")
                .foregroundStyle(LHTheme.secondaryText)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}

/// Loads one day's contexts on this Mac for review. Titles stay in memory only.
@MainActor final class GoalongWorkReviewModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: GoalongWorkContext.Label
        let seconds: TimeInterval
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedDay: Date?
    private var operation = UUID()
    /// Loads not finished yet, in every review (the test gallery waits for zero before a capture).
    private(set) static var loadsInFlight = 0
    #if DEBUG
    /// Test gallery only: rows of the last load that finished, in any review.
    static var lastLoadedRowCount: Int?
    #endif

    func load(day: Date, root: URL = AppPaths.applicationSupportDirectory) {
        let id = UUID(); operation = id
        let start = Calendar.current.startOfDay(for: day)
        loading = true; error = nil
        Self.loadsInFlight += 1
        Task {
            defer { Self.loadsInFlight -= 1 }
            let observation = await Task.detached(priority: .userInitiated) {
                GoalongWorkClassification.observe(root: root, day: start, shouldContinue: { !Task.isCancelled })
            }.value
            guard operation == id else { return }
            loading = false; loadedDay = start
            guard let observation else {
                rows = []; error = "Cette journée n’a pas pu être lue entièrement. Réessayez."
                return
            }
            var seconds: [String: TimeInterval] = [:]
            for segment in observation.day.segments where segment.kind.isActive {
                if let key = segment.contextKey { seconds[key, default: 0] += segment.seconds }
            }
            rows = seconds.compactMap { key, value in
                guard value >= 5, let label = observation.labels[key] else { return nil }
                return Row(id: key, label: label, seconds: value)
            }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
            #if DEBUG
            Self.lastLoadedRowCount = rows.count
            #endif
        }
    }
}

/// The day's contexts grouped by task, with a one-click correction for each.
@MainActor struct GoalongWorkReviewCard: View {
    @ObservedObject var review: GoalongWorkReviewModel
    @ObservedObject private var work = GoalongWorkStore.shared
    @ObservedObject private var agent = GoalongWorkAgent.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @State private var day: Date
    @State private var expanded: Set<String>
    private let focusTask: String?
    private let loadsOnAppear: Bool
    /// First day with history: the day selector stops there (M3, UI-17A).
    private let earliestDay: Date?
    @State private var naming: GoalongWorkReviewModel.Row?
    @State private var renaming: String?
    @State private var renameRefusal: String?
    @State private var name = ""

    private struct ReviewGroup: Identifiable {
        let id: String
        let title: String
        let task: String?
        let rows: [GoalongWorkReviewModel.Row]
        var seconds: TimeInterval { rows.reduce(0) { $0 + $1.seconds } }
    }

    /// Opened from Activité, the review starts on the day shown there, already loaded,
    /// with the task the user clicked first and unfolded.
    init(review: GoalongWorkReviewModel, day: Date = GoalongToday.now, focusTask: String? = nil, loadsOnAppear: Bool = false,
         earliestDay: Date? = nil) {
        _review = ObservedObject(wrappedValue: review)
        _day = State(initialValue: day)
        _expanded = State(initialValue: focusTask.map { ["task|" + $0] } ?? [])
        self.focusTask = focusTask
        self.loadsOnAppear = loadsOnAppear
        self.earliestDay = earliestDay
    }

    private var groups: [ReviewGroup] {
        var tasks: [String: [GoalongWorkReviewModel.Row]] = [:], other: [GoalongWorkReviewModel.Row] = [],
            pending: [GoalongWorkReviewModel.Row] = []
        for row in review.rows {
            switch work.verdicts.assignment(for: row.id) {
            case let assignment? where assignment.verdict == .work: tasks[assignment.task ?? "Travail", default: []].append(row)
            case let assignment? where assignment.verdict == .other: other.append(row)
            default: pending.append(row)
            }
        }
        var result: [ReviewGroup] = tasks.map { (name: String, rows: [GoalongWorkReviewModel.Row]) -> ReviewGroup in
            ReviewGroup(id: "task|" + name, title: name, task: name, rows: rows)
        }
        result.sort { (a: ReviewGroup, b: ReviewGroup) -> Bool in a.seconds == b.seconds ? a.title < b.title : a.seconds > b.seconds }
        if let focusTask, let index = result.firstIndex(where: { $0.task == focusTask }) {
            result.insert(result.remove(at: index), at: 0)
        }
        if !other.isEmpty { result.append(ReviewGroup(id: "other", title: "Hors travail", task: nil, rows: other)) }
        if !pending.isEmpty { result.append(ReviewGroup(id: "pending", title: "À classer ou indéterminé", task: nil, rows: pending)) }
        return result
    }

    var body: some View {
        GoalongSettingsGroup(title: "Vérifier et corriger") {
            HStack(spacing: 12) {
                DateSelectionControl(date: day, onChange: { day = $0 }, showsToday: false, earliest: earliestDay)
                Button(review.loadedDay == nil ? "Afficher le classement" : "Actualiser") { review.load(day: day) }
                    .buttonStyle(LHSecondaryButtonStyle()).disabled(!canLoad).accessibilityIdentifier("work-review-load")
                    .help(canLoad || review.loading ? "" : Self.historyOffReason)
                if review.loading { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            Text("Lecture locale : les titres affichés ici ne quittent pas ce Mac. Une correction vaut pour ce contexte (même app, site et titre) dans tout l’historique, pas seulement ce jour-là. Elle sert aussi d’exemple au classement automatique.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let error = review.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            } else if review.loadedDay != nil && review.rows.isEmpty && !review.loading {
                GoalongEmptyState(title: "Rien à classer ce jour-là", kind: .empty,
                                  message: "Aucune activité attribuable n’a été observée. Choisissez un autre jour avec le sélecteur ci-dessus.")
            }
            ForEach(groups) { group in groupView(group) }
            if let notice = work.storageNotice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = work.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            }
        }
        .onChange(of: day) { value in if review.loadedDay != nil { review.load(day: value) } }
        .onAppearWhenShown { if loadsOnAppear && review.loadedDay == nil && !review.loading { review.load(day: day) } }
        .alert("Nouvelle tâche", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Nom de la tâche", text: $name)
            Button("Annuler", role: .cancel) { naming = nil }
            Button("Classer") {
                if let row = naming { correct(row, .work, task: name) }
                naming = nil
            }
        } message: { Text("Par exemple « Goalong – app macOS » ou « Préparer le cours ».") }
        .alert("Renommer la tâche", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom de la tâche", text: $name)
            Button("Annuler", role: .cancel) { renaming = nil }
            Button("Renommer") {
                if let old = renaming { renameRefusal = work.renameTask(old, to: name) }
                renaming = nil
            }
        } message: { Text("Les mêmes noms écrits avec d’autres majuscules (« Goalong », « goalong ») sont renommés aussi. Donnez le nom d’une tâche existante pour fusionner les deux.") }
        .alert("Renommage impossible", isPresented: Binding(get: { renameRefusal != nil }, set: { if !$0 { renameRefusal = nil } })) {
            Button("OK", role: .cancel) { renameRefusal = nil }
        } message: { Text(renameRefusal ?? "") }
        .alert("Tâche renommée, avec une réserve", isPresented: Binding(get: { work.renameNotice != nil }, set: { if !$0 { work.renameNotice = nil } })) {
            Button("OK", role: .cancel) { work.renameNotice = nil }
        } message: { Text(work.renameNotice ?? "") }
    }

    private func groupView(_ group: ReviewGroup) -> some View {
        let open = expanded.contains(group.id)
        let rows = open ? group.rows : Array(group.rows.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(group.task != nil ? LHTheme.workData : group.id == "other" ? LHTheme.otherData : LHTheme.unclassifiedData)
                    .frame(width: 8, height: 8).accessibilityHidden(true)
                Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(GoalongAnalyticsFormatting.duration(group.seconds)).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(LHTheme.secondaryText)
                Spacer(minLength: 8)
                if let task = group.task {
                    Button("Renommer…") { name = task; renaming = task }.buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                }
            }
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                    if row.id != rows.last?.id { Divider().padding(.leading, 32) }
                }
            }
            if group.rows.count > 6 {
                Button(open ? "Réduire" : "Voir les \(group.rows.count) contextes") {
                    if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }.buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
            }
        }.padding(.top, 4)
    }

    /// R-83 (déc. 11): without the Mac's history there is nothing to classify, so the button is greyed with its reason.
    nonisolated static func canLoadReview(historyConsent: Bool, historyOff: Bool, loading: Bool) -> Bool {
        historyConsent && !historyOff && !loading
    }
    static let historyOffReason = "Enregistrement désactivé : rien à classer."

    private var canLoad: Bool {
        Self.canLoadReview(historyConsent: consents.isEnabled(.localComputerHistory),
                           historyOff: agent.readiness == .historyOff, loading: review.loading)
    }

    /// R-83: a row the owner already corrected says so once, in a pill, and its menu reads « Modifier ».
    nonisolated static func correctionMenuTitle(byOwner: Bool) -> String { byOwner ? "Modifier" : "Corriger" }

    private func rowView(_ row: GoalongWorkReviewModel.Row) -> some View {
        let assignment = work.verdicts.assignment(for: row.id)
        return HStack(spacing: 10) {
            AppIconView(bundleIdentifier: row.label.bundleIdentifier, appName: row.label.application, size: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label.title ?? row.label.application).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .help(row.label.title ?? row.label.application)
                Text(([row.label.application, row.label.host].compactMap { $0 }).joined(separator: ", ")
                     + (assignment?.byOwner != true && assignment?.verdict == .unclear ? ", indéterminé" : ""))
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            if assignment?.byOwner == true {
                StatusPill(title: "Corrigé", kind: .ready, symbol: "checkmark", tint: LHTheme.success)
                    .accessibilityLabel("Corrigé par vous")
            }
            Text(GoalongAnalyticsFormatting.duration(row.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(LHTheme.secondaryText)
            Menu {
                Section("Travail") {
                    ForEach(work.knownTasks.prefix(12), id: \.self) { task in
                        Button { correct(row, .work, task: task) } label: {
                            Label(task, systemImage: assignment?.verdict == .work && assignment?.task == task ? "checkmark" : "briefcase")
                        }
                    }
                    Button("Nouvelle tâche…") { name = ""; naming = row }
                }
                Button { correct(row, .other, task: nil) } label: {
                    Label("Hors travail", systemImage: assignment?.verdict == .other ? "checkmark" : "cup.and.saucer")
                }
                if assignment?.byOwner == true {
                    Divider()
                    Button("Laisser le classement automatique décider") { correct(row, nil, task: nil) }
                }
            } label: { Text(Self.correctionMenuTitle(byOwner: assignment?.byOwner == true)).font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.text) }
                // DESIGN §9 rank 3: ink text, no chrome, like LHQuietButtonStyle.
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(LHTheme.text).fixedSize()
                .accessibilityLabel("Corriger le classement de \(row.label.title ?? row.label.application)")
        }.padding(.vertical, 6)
    }

    private func correct(_ row: GoalongWorkReviewModel.Row, _ verdict: GoalongWorkVerdict?, task: String?) {
        if verdict == .work, GoalongWorkClassification.cleanTask(task) == nil { return }
        work.correct(key: row.id, label: row.label, verdict: verdict, task: task,
                     day: GoalongWorkAgent.dayString(review.loadedDay ?? day))
    }
}

/// What Activité asks to correct: the day on screen and, when a task was clicked, that task.
struct GoalongWorkReviewRequest: Identifiable {
    let id = UUID()
    let day: Date
    let task: String?
}

/// Marks the open `GoalongWorkSheet` for `GoalongWorkPage.openSheet`, and knows its window.
final class GoalongWorkSheetToken {
    weak var window: NSWindow?
    /// Ends the sheet from AppKit, with no update of the page that presents it.
    @MainActor func end() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
    }
}

/// Tells the token which window the sheet is.
private struct GoalongWorkSheetWindow: NSViewRepresentable {
    let token: GoalongWorkSheetToken

    final class Probe: NSView {
        weak var token: GoalongWorkSheetToken?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            token?.window = window
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.token = token
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.token = token }
}

/// Activité's « Définition du travail… »: the whole content in a sheet (definition, agent, review, how it works),
/// so the definition changes where its effect shows, and closing returns to the same day, period and scroll position.
@MainActor struct GoalongWorkSheet: View {
    let model: DashboardViewModel
    @ObservedObject private var navigation: DashboardNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var token = GoalongWorkSheetToken()

    init(model: DashboardViewModel) {
        self.model = model
        _navigation = ObservedObject(wrappedValue: model.navigationStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Définition du travail").font(LHTheme.sheetTitleFont).accessibilityAddTraits(.isHeader)
                    Text(GoalongWorkPage.subtitle).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // Escape closes, as in every sheet. Return stays with the text fields of the definition.
                Button("Terminé") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("work-sheet-done")
            }.padding(24)
            Divider()
            GoalongWorkPage(model: model, placement: .sheet)
        }
        .frame(width: 720, height: 640).background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .background(GoalongWorkSheetWindow(token: token).frame(width: 0, height: 0).accessibilityHidden(true))
        .onAppearWhenShown { GoalongWorkPage.openSheet = token }
        .onChange(of: navigation.selectedSection) { _ in
            // Any other section leaves the page under this sheet (menu, link). Activité is a kept page: once left
            // it is out of the window and frozen, and the change of state of its `onDisappear` is applied only at
            // its return. So the sheet ends itself, in AppKit too: the definition never stays over another page.
            dismiss(); token.end()
        }
        .onDisappear { if GoalongWorkPage.openSheet === token { GoalongWorkPage.openSheet = nil } }
        .accessibilityIdentifier("work-sheet")
    }
}

/// Activité's « Corriger »: the review in a sheet, so closing it returns to the same day,
/// period and scroll position in Activité instead of switching to another page.
@MainActor struct GoalongWorkReviewSheet: View {
    let request: GoalongWorkReviewRequest
    @StateObject private var review = GoalongWorkReviewModel()
    @ObservedObject private var agent = GoalongWorkAgent.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Corriger le classement").font(LHTheme.sheetTitleFont)
                    Text("Chaque contexte de la journée, rangé par tâche. Vos corrections priment sur le classement automatique.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                }
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("work-review-sheet-done")
            }.padding(24)
            Divider()
            ScrollView {
                GoalongWorkReviewCard(review: review, day: request.day, focusTask: request.task, loadsOnAppear: true)
                    .padding(24)
            }
        }
        .frame(width: 720, height: 640).background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .onChange(of: agent.isRunning) { running in
            if !running, let day = review.loadedDay { review.load(day: day) }
        }
        .background(Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
        .accessibilityIdentifier("work-review-sheet")
    }
}

/// The definition lives in Réglages › Définition du travail; other pages only summarise it.
@MainActor struct GoalongWorkDefinitionSummary: View {
    var onOpen: () -> Void
    @ObservedObject private var store = JevWorkContextStore.shared

    var body: some View {
        GoalongSettingsGroup(title: "Ce qui compte comme travail") {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    if store.context.isEmpty {
                        Text("Pas encore défini. Décrivez votre travail pour que Jev sache quoi surveiller.")
                            .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    } else {
                        ForEach([store.context.summary, store.context.applications, store.context.content].filter { !$0.isEmpty }, id: \.self) {
                            Text($0).font(.system(size: 13)).lineLimit(2)
                        }
                        if !store.context.procrastination.isEmpty {
                            Text("Pas du travail : " + store.context.procrastination).font(.system(size: 12))
                                .foregroundStyle(LHTheme.secondaryText).lineLimit(2)
                        }
                    }
                    Text("La même définition sert à Activité et à Jev.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Button(store.context.isEmpty ? "Définir mon travail" : "Modifier", action: onOpen)
                    .buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("monitoring-open-work")
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(LHTheme.warning)
            }
        }
    }
}
#endif
