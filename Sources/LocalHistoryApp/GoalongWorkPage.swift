#if os(macOS)
import Combine
import Foundation
import LocalHistoryCore
import SwiftUI

/// "Mon travail": the user's own definition of work, the agent that applies it, and the
/// review where every verdict can be corrected. Goalong never rates an app or a site.
@MainActor struct GoalongWorkPage: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var work = GoalongWorkStore.shared
    @ObservedObject private var agent = GoalongWorkAgent.shared
    @ObservedObject private var definition = JevWorkContextStore.shared
    @ObservedObject private var runtime = ChatGPTRecapRuntime.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @StateObject private var review = GoalongWorkReviewModel()
    @State private var confirmingConsent = false
    @State private var confirmingForget = false
    @State private var classifyWhenConnected = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Mon travail",
                           subtitle: "Vous décidez de ce qui compte comme travail. Goalong ne juge jamais une app ou un site : un agent applique votre définition, et vous corrigez chaque verdict.")
                JevWorkContextControls(purpose: .workDefinition)
                if !work.definition.isEmpty {
                    agentCard
                    GoalongWorkReviewCard(review: review)
                }
                GoalongDisclosureGroup("Comment fonctionne le classement ?") { explanation.padding(.top, 10) }
                    .font(.system(size: 13))
            }
            .font(.system(size: 13))
            .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("work-page")
        .onAppear { runtime.refreshAccount() }
        .onReceive(NotificationCenter.default.publisher(for: .jevWorkContextDidChange)) { _ in
            // A new definition re-classifies today straight away when the user allowed it.
            if work.automatic { agent.classify(day: Date(), userInitiated: false) }
        }
        .onChange(of: runtime.connectionState) { state in
            guard classifyWhenConnected, case .connected = state else { return }
            classifyWhenConnected = false
            agent.classify(day: Date())
        }
        .onChange(of: agent.isRunning) { running in
            if !running, let day = review.loadedDay { review.load(day: day) }
        }
        .alert("Autoriser ChatGPT à classer votre temps ?", isPresented: $confirmingConsent) {
            Button("Annuler", role: .cancel) {}
            Button("Autoriser") {
                if consents.set(.chatGPTAnalysis, enabled: true, surface: .settings) {
                    work.automatic = true
                    // The account state was not checked while analysis was off.
                    classifyWhenConnected = true
                    runtime.refreshAccount(userInitiated: true)
                }
            }
        } message: {
            Text("Pour chaque contexte nouveau, Goalong envoie à votre compte ChatGPT le nom de l’app, le site et le titre de la fenêtre, avec sa durée, ainsi que votre définition du travail. Jamais ce que vous tapez, ni de capture d’écran. Vos exclusions et vos choix « Données pour ChatGPT » s’appliquent. Cela active aussi l’autorisation générale Analyse ChatGPT, réglable dans Réglages.")
        }
        .confirmationDialog("Tout reclasser avec votre définition actuelle ?", isPresented: $confirmingForget) {
            Button("Tout reclasser") { work.forgetAgentVerdicts(); agent.classify(day: Date()) }
        } message: {
            Text("Les verdicts de l’agent sont effacés et les contextes seront renvoyés au fil de vos consultations d’Activité. Vos corrections sont conservées.")
        }
    }

    private var agentCard: some View {
        GoalongSettingsGroup(title: "Classement par l’agent") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol).font(.system(size: 14, weight: .medium)).foregroundStyle(statusTint)
                    .frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.system(size: 13, weight: .semibold))
                    if let detail = statusDetail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                statusAction
            }
            Toggle("Classer automatiquement les nouveaux contextes", isOn: $work.automatic)
                .toggleStyle(.goalongSwitch).disabled(agent.readiness == .noConsent)
                .accessibilityIdentifier("work-automatic")
            Text("Quand vous ouvrez Activité : la journée affichée, au plus toutes les 15 minutes pour aujourd’hui. Aucune minuterie en arrière-plan ; un contexte déjà classé n’est jamais renvoyé.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory),
                                        selection: GoalongAnalysisSelection.load()).withholdsTitles {
                Label("Vos choix « Données pour ChatGPT » excluent les titres de fenêtre : le classement ne peut distinguer deux usages d’une même app que par le site.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if work.hasAgentVerdicts {
                Button("Tout reclasser…") { confirmingForget = true }.buttonStyle(LHQuietButtonStyle())
                    .font(.system(size: 12)).disabled(agent.isRunning)
            }
        }
    }

    private var statusSymbol: String {
        if agent.isRunning { return "sparkles" }
        if agent.lastError != nil { return "exclamationmark.triangle" }
        return agent.readiness == .ready ? "checkmark.circle" : "circle.dashed"
    }
    private var statusTint: Color {
        if agent.lastError != nil && !agent.isRunning { return LHTheme.warning }
        return agent.readiness == .ready || agent.isRunning ? LHTheme.accent : LHTheme.secondaryText
    }
    private var statusTitle: String {
        if agent.isRunning { return "Classement en cours" }
        switch agent.readiness {
        case .ready: return "Prêt · votre compte ChatGPT"
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
        return agent.lastOutcome ?? "Les contextes nouveaux sont classés quand vous consultez Activité."
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
                    ProgressView().controlSize(.small)
                } else {
                    Button(runtime.isConnecting ? "Connexion…" : "Connecter ChatGPT") {
                        classifyWhenConnected = true
                        runtime.connectChatGPT()
                    }
                        .buttonStyle(LHPrimaryButtonStyle()).disabled(runtime.isConnecting)
                }
            case .historyOff:
                Button("Ouvrir les réglages") { model.openRecordingSettings() }.buttonStyle(LHSecondaryButtonStyle())
            case .ready:
                Button("Classer aujourd’hui") { agent.classify(day: Date()) }.buttonStyle(LHSecondaryButtonStyle())
                    .accessibilityIdentifier("work-classify-today")
            case .paused, .noDefinition:
                EmptyView()
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("1. Goalong découpe votre journée en contextes : une app, un site et un titre de fenêtre. La même app donne donc plusieurs contextes — un document de travail et une vidéo ne se confondent pas.")
            Text("2. L’agent (votre compte ChatGPT, sans aucun outil ni accès à vos fichiers) lit votre définition et chaque contexte nouveau, avec l’ordre de la journée pour les cas ambigus. Il répond Travail avec le nom de la tâche, Hors travail, ou Indéterminé s’il ne peut pas trancher.")
            Text("3. Les verdicts sont gardés sur ce Mac et appliqués à tout l’historique, sans modifier les journaux. Un contexte déjà classé n’est jamais renvoyé ; changer la définition relance le classement. Vos corrections priment toujours et servent d’exemples à l’agent.")
            Text("4. Une tâche reste la même d’une app à l’autre : passer de l’éditeur au navigateur pour le même projet garde votre session de travail. Un détour de moins d’une minute entre deux moments de la même tâche lui est rattaché.")
            Text("Rien n’est envoyé pour les apps et sites exclus, ni pour les apps retirées de « Données pour ChatGPT ». Les contextes très courts (moins de 15 s) ne sont pas envoyés.")
                .foregroundStyle(.secondary)
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

    func load(day: Date, root: URL = AppPaths.applicationSupportDirectory) {
        let id = UUID(); operation = id
        let start = Calendar.current.startOfDay(for: day)
        loading = true; error = nil
        Task {
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
        }
    }
}

/// The day's contexts grouped by task, with a one-click correction for each.
@MainActor struct GoalongWorkReviewCard: View {
    @ObservedObject var review: GoalongWorkReviewModel
    @ObservedObject private var work = GoalongWorkStore.shared
    @State private var day: Date
    @State private var expanded: Set<String>
    private let focusTask: String?
    private let loadsOnAppear: Bool
    @State private var naming: GoalongWorkReviewModel.Row?
    @State private var renaming: String?
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
    init(review: GoalongWorkReviewModel, day: Date = Date(), focusTask: String? = nil, loadsOnAppear: Bool = false) {
        _review = ObservedObject(wrappedValue: review)
        _day = State(initialValue: day)
        _expanded = State(initialValue: focusTask.map { ["task|" + $0] } ?? [])
        self.focusTask = focusTask
        self.loadsOnAppear = loadsOnAppear
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
                DateSelectionControl(date: day, onChange: { day = $0 }, showsToday: false)
                Button(review.loadedDay == nil ? "Afficher le classement" : "Actualiser") { review.load(day: day) }
                    .buttonStyle(LHSecondaryButtonStyle()).disabled(review.loading).accessibilityIdentifier("work-review-load")
                if review.loading { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            Text("Lecture locale : les titres affichés ici ne quittent pas ce Mac. Une correction vaut pour ce contexte (même app, site et titre) dans tout l’historique, pas seulement ce jour-là. Elle sert aussi d’exemple à l’agent.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = review.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            } else if review.loadedDay != nil && review.rows.isEmpty && !review.loading {
                GoalongEmptyState(title: "Rien à classer ce jour-là",
                                  message: "Aucune activité attribuable n’a été observée. Choisissez un autre jour avec le sélecteur ci-dessus.")
            }
            ForEach(groups) { group in groupView(group) }
            if let error = work.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            }
        }
        .onChange(of: day) { value in if review.loadedDay != nil { review.load(day: value) } }
        .onAppear { if loadsOnAppear && review.loadedDay == nil && !review.loading { review.load(day: day) } }
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
                if let old = renaming { work.renameTask(old, to: name) }
                renaming = nil
            }
        } message: { Text("Donnez le nom d’une tâche existante pour fusionner les deux.") }
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
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let task = group.task {
                    Button("Renommer…") { name = task; renaming = task }.buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                }
            }
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                    if row.id != rows.last?.id { Divider().padding(.leading, 34) }
                }
            }
            if group.rows.count > 6 {
                Button(open ? "Réduire" : "Voir les \(group.rows.count) contextes") {
                    if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }.buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
            }
        }.padding(.top, 4)
    }

    private func rowView(_ row: GoalongWorkReviewModel.Row) -> some View {
        let assignment = work.verdicts.assignment(for: row.id)
        return HStack(spacing: 10) {
            AppIconView(bundleIdentifier: row.label.bundleIdentifier, appName: row.label.application, size: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label.title ?? row.label.application).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .help(row.label.title ?? row.label.application)
                Text(([row.label.application, row.label.host].compactMap { $0 }).joined(separator: " · ")
                     + (assignment?.byOwner == true ? " · corrigé par vous" : assignment?.verdict == .unclear ? " · indéterminé" : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(GoalongAnalyticsFormatting.duration(row.seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
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
                    Button("Laisser l’agent décider") { correct(row, nil, task: nil) }
                }
            } label: { Text("Corriger").font(.system(size: 11)) }
                .menuIndicator(.hidden).controlSize(.small).fixedSize()
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

/// Activité's « Corriger »: the review in a sheet, so closing it returns to the same day,
/// period and scroll position in Activité instead of switching to Mon travail.
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
                    Text("Chaque contexte de la journée, rangé par tâche. Vos corrections priment sur l’agent.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
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
        .accessibilityIdentifier("work-review-sheet")
    }
}

/// The definition lives in Mon travail; other pages only summarise it.
@MainActor struct GoalongWorkDefinitionSummary: View {
    var onOpen: () -> Void
    @ObservedObject private var store = JevWorkContextStore.shared

    var body: some View {
        GoalongSettingsGroup(title: "Ce qui compte comme travail") {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    if store.context.isEmpty {
                        Text("Pas encore défini. Sans définition, la surveillance ne peut pas savoir ce qui sert votre travail.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        ForEach([store.context.summary, store.context.applications, store.context.content].filter { !$0.isEmpty }, id: \.self) {
                            Text($0).font(.system(size: 13)).lineLimit(2)
                        }
                        if !store.context.procrastination.isEmpty {
                            Text("Pas du travail : " + store.context.procrastination).font(.system(size: 12))
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Text("La même définition sert à Activité et à la surveillance temps réel.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
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
