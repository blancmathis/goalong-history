#if os(macOS)
import AppKit
import LocalHistoryCore
import SwiftUI

/// One entry for everything that keeps attention: the session now, what distracts, the week's
/// program and real-time monitoring. Each tab answers one question; the modules stay separate.
@MainActor struct ConcentrationHubPage: View {
    @ObservedObject var model: DashboardViewModel

    nonisolated static let tabs: [DashboardSection] = [.concentration, .distractions, .blocking]

    nonisolated static func tabTitle(_ section: DashboardSection) -> String {
        switch section {
        case .distractions: return "Distractions"
        case .blocking: return "Programme"
        default: return "Maintenant"
        }
    }

    private var tab: DashboardSection { Self.tabs.contains(model.selectedSection) ? model.selectedSection : .concentration }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConcentrationHubHeader(tab: Binding(get: { tab }, set: { model.selectSection($0) }))
            Group {
                switch tab {
                case .distractions: DistractionsPage()
                case .blocking: BlockingPage(onOpenLists: { model.selectSection(.distractions) })
                default: ConcentrationPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(LHTheme.pageBackground)
        // Jev's key and settings live in Réglages; the tabs only point there.
        .environment(\.openJevSettings) { model.selectSection(.monitoring) }
    }
}

/// The title and the four tabs, pinned above the tab's own scroll.
struct ConcentrationHubHeader: View {
    @Binding var tab: DashboardSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Concentration").goalongPageTitle()
            GoalongSegmentedControl("Onglet", selection: $tab, options: ConcentrationHubPage.tabs, title: ConcentrationHubPage.tabTitle)
                .accessibilityIdentifier("concentration-tabs")
        }
        .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
        .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tab whose module is off: one sentence and the switch, nothing else.
@MainActor struct GoalongModuleOffNote: View {
    let module: GoalongModule
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Activer \(module.title)") { GoalongModuleStore.shared.setEnabled(module, true) }
                .buttonStyle(LHPrimaryButtonStyle())
                .accessibilityIdentifier("module-enable-\(module.rawValue)")
        }
        .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
        .padding(.horizontal, LHTheme.pageInset).padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Distractions

/// The only place where lists are made: sites and apps to cut, then the same thing in words for
/// monitoring. Sessions, engagements and the program only pick from these lists.
@MainActor struct DistractionsPage: View {
    @ObservedObject var runtime = BlockingRuntime.shared
    var now: Date?
    @State private var editingList: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
                Text("Ce qui vous distrait. Une séance, un engagement ou le programme bloque ces listes.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                if let controller = runtime.controller {
                    BlockingListsSection(controller: controller, now: now ?? Date(), editing: $editingList)
                    if let error = controller.error, editingList == nil {
                        GoalongNote(error, tone: .warning).onTapGesture { controller.error = nil }
                    }
                } else {
                    GoalongSection(title: "Listes") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Les listes de sites et d’apps à couper viennent du module Blocage.")
                                .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                            Button("Activer Blocage") { GoalongModuleStore.shared.setEnabled(.blocking, true) }
                                .buttonStyle(LHPrimaryButtonStyle())
                                .accessibilityIdentifier("module-enable-blocking")
                        }
                    }
                }
                DistractionWordsSection()
                JevConnectHint(text: "Jev repère aussi les distractions qu’aucune liste ne contient, avec ces exemples.")
            }
            .font(.system(size: 13))
            .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.top, 20).padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("distractions-page")
        .sheet(isPresented: Binding(get: { editingList != nil }, set: { if !$0 { editingList = nil } })) {
            if let id = editingList, let controller = runtime.controller {
                BlockListSheet(controller: controller, listID: id, now: now ?? Date()) { editingList = nil }
                    .goalongControls()
            }
        }
    }
}

/// « Ce qui n'est pas du travail », in words: what the monitoring weighs each moment against.
/// Edits only this field of the shared work definition.
@MainActor struct DistractionWordsSection: View {
    @ObservedObject private var store = JevWorkContextStore.shared
    @State private var editing = false
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        GoalongSection(title: "En mots, pour la surveillance",
                       subtitle: "Des exemples certains. La surveillance s’en sert pour reconnaître une distraction qu’aucune liste ne contient.") {
            VStack(alignment: .leading, spacing: 12) {
                if editing {
                    TextEditor(text: $text)
                        .font(.system(size: 13)).frame(minHeight: 72)
                        .padding(6)
                        .background(LHTheme.controlBackground, in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous).strokeBorder(LHTheme.controlBorder))
                        .accessibilityLabel("Ce qui n’est pas du travail")
                        .accessibilityIdentifier("distractions-words-editor")
                    GoalongNote("Ces exemples restent sur ce Mac. Ils partent avec chaque analyse quand la surveillance ou le classement est activé.",
                                tone: .privacy)
                    HStack {
                        Spacer()
                        Button("Annuler") { editing = false; error = nil }
                        Button("Enregistrer") { save() }.buttonStyle(LHPrimaryButtonStyle())
                            .accessibilityIdentifier("distractions-words-save")
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        Text(store.context.procrastination.isEmpty
                             ? "Aucun exemple. Ex. « Scroller le fil de X, regarder des vidéos de divertissement. »"
                             : store.context.procrastination)
                            .foregroundStyle(store.context.procrastination.isEmpty ? LHTheme.secondaryText : LHTheme.text)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .accessibilityIdentifier("distractions-words")
                        Spacer(minLength: 8)
                        Button(store.context.procrastination.isEmpty ? "Ajouter" : "Modifier") {
                            text = store.context.procrastination; editing = true
                        }
                        .accessibilityIdentifier("distractions-words-edit")
                    }
                }
                if let message = error ?? store.error { GoalongNote(message, tone: .warning) }
            }
        }
    }

    private func save() {
        let context = store.context
        do {
            try store.save(context.summary, applications: context.applications, content: context.content, procrastination: text)
            editing = false; error = nil
            GoalongToastCenter.shared.show("Exemples enregistrés")
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - New list, wherever a list is picked

/// « Nouvelle liste… » next to the list chips: makes the list on the spot, opens its editor, then
/// hands it back selected. A list left empty is removed when the editor closes.
@MainActor struct BlockingNewListChip: View {
    var onCreated: (UUID) -> Void
    @ObservedObject private var runtime = BlockingRuntime.shared
    @State private var editing: UUID?

    var body: some View {
        if let controller = runtime.controller {
            Button { create(controller) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("Nouvelle liste…").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(LHTheme.secondaryText)
                .padding(.horizontal, 10).frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                    .strokeBorder(LHTheme.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("blocking-new-list-inline")
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { finish(controller) } })) {
                if let id = editing {
                    BlockListSheet(controller: controller, listID: id, now: Date()) { finish(controller) }
                        .goalongControls()
                }
            }
        }
    }

    private func create(_ controller: BlockingController) {
        let list = BlockList(name: "Nouvelle liste")
        controller.save(list)
        if controller.list(list.id) != nil { editing = list.id }
    }

    private func finish(_ controller: BlockingController) {
        guard let id = editing else { return }
        editing = nil
        guard let list = controller.list(id) else { return }
        if list.mode == .block && list.sites.isEmpty && list.apps.isEmpty { controller.delete(id) } else { onCreated(id) }
    }
}

// MARK: - Suggestions after a session

/// After a session, up to three things monitoring saw distracting you, each with its own choice.
/// Nothing joins a list without a click.
@MainActor struct FocusDistractionSuggestionsCard: View {
    @ObservedObject var controller: ConcentrationController
    @ObservedObject private var blocking = BlockingRuntime.shared
    @State private var error: String?
    @State private var editingList: UUID?

    var body: some View {
        Group {
            if let current = latest() {
                GoalongSection(title: "Après « \(current.session.intent) »",
                               subtitle: "La surveillance a vu ces distractions pendant la séance. Rien n’est ajouté sans votre clic.") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(current.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rectangle().fill(LHTheme.separator).frame(height: 1) }
                            row(item, session: current.session.id)
                        }
                        if blocking.controller == nil {
                            Text("Activez Blocage pour les ajouter à une liste.")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).padding(.top, 8)
                        }
                        if let error { GoalongNote(error, tone: .warning).padding(.top, 8) }
                    }
                }
                .accessibilityIdentifier("focus-distraction-suggestions")
            }
        }
        .sheet(isPresented: Binding(get: { editingList != nil }, set: { if !$0 { editingList = nil } })) {
            if let id = editingList, let lists = blocking.controller {
                BlockListSheet(controller: lists, listID: id, now: Date()) { editingList = nil }.goalongControls()
            }
        }
    }

    private func row(_ item: FocusDistractionSuggestion, session: UUID) -> some View {
        let lists = controller.blockLists.filter { $0.mode == .block }
        return HStack(spacing: 12) {
            Group {
                switch item.target.kind {
                case .site: BlockingSiteTile(host: item.target.value, size: 24)
                case .app: AppIconView(bundleIdentifier: item.target.value, appName: item.target.name, size: 24)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.target.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(FocusDistractionFormat.minutes(item.confirmedSeconds)) de distraction repérée")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if blocking.controller != nil {
                Menu {
                    ForEach(lists) { list in
                        Button(list.name) { act { try controller.acceptDistractionSuggestion(sessionID: session, targetID: item.id, listID: list.id) } }
                    }
                    if !lists.isEmpty { Divider() }
                    Button("Nouvelle liste…") { addToNewList(item, session: session) }
                } label: { Text("Ajouter à…") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("suggestion-add-\(item.target.value)")
            }
            Menu {
                Button("Cette fois") { act { try controller.ignoreDistractionSuggestion(sessionID: session, targetID: item.id) } }
                Button("Toujours pour \(item.target.name)") {
                    act { try controller.ignoreDistractionSuggestion(sessionID: session, targetID: item.id, always: true) }
                }
            } label: { Text("Ignorer") }
            .menuStyle(.borderlessButton).fixedSize()
            .foregroundStyle(LHTheme.secondaryText)
            .accessibilityIdentifier("suggestion-ignore-\(item.target.value)")
        }
        .padding(.vertical, 10)
    }

    private func addToNewList(_ item: FocusDistractionSuggestion, session: UUID) {
        guard let lists = blocking.controller else { return }
        let list = BlockList(name: "Distractions")
        lists.save(list)
        guard lists.list(list.id) != nil else { error = lists.error ?? FocusUIError.message(FocusFailure.storageFailed); return }
        act { try controller.acceptDistractionSuggestion(sessionID: session, targetID: item.id, listID: list.id) }
        editingList = list.id
    }

    private func act(_ action: () throws -> Void) {
        do { try action(); error = nil } catch let failure as BlockingListAdditionFailure {
            error = failure.localizedDescription
        } catch { self.error = FocusUIError.message(error) }
    }

    /// The latest ended session of the day that still has something to offer.
    private func latest() -> (session: FocusSession, items: [FocusDistractionSuggestion])? {
        let ended = controller.sessions.filter { $0.endedAt != nil && $0.distractions?.suggestedTargetIDs?.isEmpty == false }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        for session in ended.prefix(3) {
            if let items = try? controller.distractionSuggestions(sessionID: session.id), !items.isEmpty {
                return (session, items)
            }
        }
        return nil
    }
}

enum FocusDistractionFormat {
    static func minutes(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }
}

// MARK: - Jev

private struct OpenJevSettingsKey: EnvironmentKey { static let defaultValue: () -> Void = {} }

extension EnvironmentValues {
    /// Opens Réglages › Jev, where the key and the monitoring settings live.
    var openJevSettings: () -> Void {
        get { self[OpenJevSettingsKey.self] }
        set { self[OpenJevSettingsKey.self] = newValue }
    }
}

/// Shown while Jev is off: one sentence and a link to its settings.
@MainActor struct JevConnectHint: View {
    let text: String
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @Environment(\.openJevSettings) private var open

    var body: some View {
        if !consents.isEnabled(.jevMonitoring) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "eye.circle").foregroundStyle(LHTheme.secondaryText).accessibilityHidden(true)
                Text(text).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Configurer Jev", action: open)
                    .buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("jev-open-settings")
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - When monitoring runs

/// Always, or only while a Concentration session runs. Changing it never turns monitoring on.
@MainActor struct JevScopeControl: View {
    @ObservedObject private var monitor = JevMonitor.shared
    @ObservedObject private var modules = GoalongModuleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Quand").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                GoalongSegmentedControl("Quand surveiller", selection: Binding(get: { monitor.scope }, set: { monitor.setScope($0) }),
                                        options: JevMonitoringScope.allCases) {
                    $0 == .always ? "Toujours" : "Pendant mes séances"
                }
                .controlSize(.small)
                .accessibilityIdentifier("jev-scope")
            }
            Text(monitor.scope == .always
                 ? "Dès que la surveillance est activée, toute la journée."
                 : "Seulement pendant une séance Concentration, pauses comprises. Hors séance : aucun envoi, rappel ni effet.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if monitor.scope == .sessionsOnly && !modules.isEnabled(.concentration) {
                GoalongNote("Activez Concentration pour lancer une séance : sans séance, la surveillance attend.", tone: .warning)
            }
        }
    }
}
#endif
