#if os(macOS)
import SwiftUI
import LocalHistoryCore

/// These are setup requirements, not a claim that monitoring is currently running.
struct JevActivationAvailability: Equatable {
    let hasKey: Bool
    let localHistoryEnabled: Bool
    var isReady: Bool { hasKey && localHistoryEnabled }
    func canToggle(isEnabled: Bool) -> Bool { isEnabled || isReady }
}

@MainActor struct JevMonitoringPage: View {
    var onOpenRecording: () -> Void
    var onOpenWork: () -> Void = {}
    /// Inside the « Jev » sheet of « Blocages »: the editor brings the title, the box and the scrolling. Only global
    /// things live here (T-050 B1 point 8): consent, connection, work context. Each rule carries its own reminders.
    enum Part { case page, when }
    var part: Part = .page
    @ObservedObject private var monitor = JevMonitor.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @State private var showingConnection = false
    @State private var confirming = false

    private var enabled: Bool { consents.isEnabled(.jevMonitoring) }
    private var availability: JevActivationAvailability {
        JevActivationAvailability(hasKey: monitor.hasKey,
            localHistoryEnabled: consents.isEnabled(.localComputerHistory))
    }

    var body: some View {
        Group {
            switch part {
            case .when: whenRows
            case .page:
                ScrollView {
                    content
                        .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
                        .padding(.horizontal, LHTheme.pageInset).padding(.top, 20).padding(.bottom, LHTheme.pageBottomInset)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(LHTheme.pageBackground)
            }
        }
        // A container: without it the page's identifier would replace its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("jev-monitoring-page")
        .sheet(isPresented: $showingConnection) { JevConnectionSheet().goalongControls() }
        .alert(Self.consentTitle, isPresented: $confirming) {
            Button("Annuler", role: .cancel) {}
            Button(Self.consentButton) { monitor.setEnabled(true) }
        } message: {
            Text(Self.consentMessage)
        }
    }

    /// The one consent request of Jev, also asked by the « Surveillance » switch of a rule (T-050 B1 point 5).
    static let consentTitle = "Activer Jev ?"
    static let consentButton = "Autoriser les envois à Jev"
    static let consentMessage = "Toutes les 15 secondes avec activité observable, Goalong transmet les critères de travail et exemples hors travail enregistrés, ainsi qu’un extrait compact (applications, domaines, titres et interactions) à api.typesafe.ai. Ces données peuvent être personnelles. L’API est payante. Une détection suffisamment fiable affiche un rappel, sans attendre une deuxième fenêtre. Les autres sources restent inchangées."

    private var content: some View {
            VStack(alignment: .leading, spacing: 24) {
                Text("Des rappels pour rester sur vos projets de travail. Choisissez quand dans une règle ou une séance, avec « Surveillance ».")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                monitoringCard
                GoalongWorkDefinitionSummary(onOpen: onOpenWork)
                JevBreakControls()
                if !monitor.recentChecks.isEmpty {
                    GoalongDisclosureGroup("Dernières vérifications, cette session") {
                        JevRecentChecksView(checks: Array(monitor.recentChecks.prefix(6)))
                            .padding(.top, 12)
                    }
                    .accessibilityIdentifier("jev-recent-checks")
                }
                GoalongDisclosureGroup("Fonctionnement et confidentialité") {
                    JevPrivacyControls().padding(.top, 12)
                }
                .accessibilityIdentifier("jev-privacy-details")
            }
            .font(.system(size: 13))
    }

    /// The settings of the page, without its card: the editor's « Quand » box draws the frame.
    private var whenRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Activer Jev", isOn: enabledBinding).toggleStyle(.goalongSwitchInline).fixedSize()
                        .frame(minHeight: 32)
                        .disabled(!availability.canToggle(isEnabled: enabled))
                        .accessibilityIdentifier("jev-enabled")
                    if let reason = toggleBlockedReason {
                        Text(reason).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .accessibilityIdentifier("jev-enabled-reason")
                    }
                }
                Spacer(minLength: 8)
                if enabled || monitor.timedBreak != nil {
                    Label(monitor.status, systemImage: monitor.timedBreak != nil ? "pause.circle" : "circle.dotted")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                        .frame(minHeight: 32)
                        .accessibilityIdentifier("jev-status")
                }
            }
            connectionRow
            if !availability.localHistoryEnabled {
                HStack(alignment: .top, spacing: 12) {
                    Text("L’enregistrement doit aussi être activé. Aucun accès n’est modifié à votre place.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Configurer l’historique", action: onOpenRecording)
                        .modifier(GoalongMainActionStyle(primary: monitor.hasKey))
                        .accessibilityIdentifier("jev-open-recording")
                }
            }
            if let error = monitor.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12))
                    .foregroundStyle(LHTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            GoalongWorkDefinitionSummary(onOpen: onOpenWork)
            JevBreakControls()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { if $0 { confirming = true } else if JevStopGate.confirm(action: "Désactiver Jev") { monitor.setEnabled(false) } })
    }

    private var monitoringCard: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Jev").font(LHTheme.cardTitleFont).accessibilityAddTraits(.isHeader)
                        Text("Facultatif. Jev, service payant de la société TypeSafe, vous rappelle votre projet quand il repère une distraction.")
                            .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Toggle("Activer", isOn: Binding(
                            get: { enabled },
                            set: { if $0 { confirming = true } else if JevStopGate.confirm(action: "Désactiver Jev") { monitor.setEnabled(false) } }))
                            .toggleStyle(.goalongSwitchOnly).fixedSize()
                            .disabled(!availability.canToggle(isEnabled: enabled))
                            .accessibilityHint(availability.canToggle(isEnabled: enabled) || availability.hasKey ? "" : "Connectez d’abord Jev, plus bas.")
                            .accessibilityIdentifier("jev-enabled")
                        // UI-56: a switch that cannot be turned on says so, instead of looking merely off.
                        if let reason = toggleBlockedReason {
                            Text(reason).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .fixedSize()
                                .accessibilityIdentifier("jev-enabled-reason")
                        }
                    }
                }
                // Always show the runtime's real status, including protected/idle/error states;
                // a switch already off says « désactivée » by itself.
                if enabled || monitor.timedBreak != nil {
                    Label(monitor.status, systemImage: monitor.timedBreak != nil ? "pause.circle" : "circle.dotted")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("jev-status")
                }
                Rectangle().fill(LHTheme.separator).frame(height: 1)
                connectionRow
                if !availability.localHistoryEnabled {
                    HStack(alignment: .top, spacing: 12) {
                        Text("L’enregistrement doit aussi être activé. Aucun accès n’est modifié à votre place.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        // UI-9 (5): with a key saved, the history is the one step left, so it is the lime action.
                        Button("Configurer l’historique", action: onOpenRecording)
                            .modifier(GoalongMainActionStyle(primary: monitor.hasKey))
                            .accessibilityIdentifier("jev-open-recording")
                    }
                }
                if let error = monitor.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(LHTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Réessayer") { monitor.retry() }
                            .accessibilityIdentifier("jev-retry")
                    }.font(.system(size: 12))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toggleBlockedReason: String? {
        guard !availability.canToggle(isEnabled: enabled) else { return nil }
        // Without a key, the « Jev n’est pas connecté » row below says it once, with its action (UI-15B, 5).
        return availability.hasKey ? "Activez d’abord l’historique" : nil
    }

    private var connectionRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // UI-9 (5): plain words, no « API ». UI-11A (5): Jev is explained once, in the card's header.
                Text(monitor.hasKey ? "Jev est connecté" : "Jev n’est pas connecté")
                    .font(.system(size: 13, weight: .medium))
                Text(monitor.hasKey ? "L’usage est facturé par TypeSafe." : "Votre clé d’accès reste sur ce Mac.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            Spacer(minLength: 8)
            // UI-56: until a key is saved, connecting is the step that unlocks Jev, so it is the lime action.
            Button(monitor.hasKey ? "Gérer la connexion" : "Connecter Jev") { showingConnection = true }
                .modifier(GoalongMainActionStyle(primary: !monitor.hasKey))
                .accessibilityIdentifier("jev-open-connection")
        }
    }
}
#endif
