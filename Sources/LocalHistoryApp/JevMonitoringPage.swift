#if os(macOS)
import SwiftUI

/// These are setup requirements, not a claim that monitoring is currently running.
struct JevActivationAvailability: Equatable {
    let hasKey: Bool
    let localHistoryEnabled: Bool
    var isReady: Bool { hasKey && localHistoryEnabled }
    func canToggle(isEnabled: Bool) -> Bool { isEnabled || isReady }
}

@MainActor struct JevMonitoringPage: View {
    var onOpenRecording: () -> Void
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Surveillance temps réel")
                        .font(LHTheme.pageTitleFont).accessibilityAddTraits(.isHeader)
                    Text("Un rappel discret pour revenir à ce que vous voulez faire.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                monitoringCard
                JevBreakControls()
                if !monitor.recentChecks.isEmpty {
                    DisclosureGroup("Dernières vérifications · cette session") {
                        JevRecentChecksView(checks: Array(monitor.recentChecks.prefix(6)))
                            .padding(.top, 12)
                    }
                    .accessibilityIdentifier("jev-recent-checks")
                }
                DisclosureGroup("Fonctionnement et confidentialité") {
                    JevPrivacyControls().padding(.top, 12)
                }
                .accessibilityIdentifier("jev-privacy-details")
            }
            .font(.system(size: 13))
            .frame(maxWidth: 840, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("jev-monitoring-page")
        .sheet(isPresented: $showingConnection) { JevConnectionSheet() }
        .alert("Activer la surveillance Jev ?", isPresented: $confirming) {
            Button("Annuler", role: .cancel) {}
            Button("Autoriser les envois à TypeSafe") { monitor.setEnabled(true) }
        } message: {
            Text("Toutes les 15 secondes avec activité observable, Goalong transmet un extrait compact (applications, domaines, titres et interactions) à api.typesafe.ai. Ces données peuvent être personnelles. L’API est payante. Deux détections consécutives affichent une bannière. Les autres sources restent inchangées.")
        }
    }

    private var monitoringCard: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "eye.circle")
                        .font(.system(size: 25)).foregroundStyle(LHTheme.accent)
                        .frame(width: 46, height: 46)
                        .background(LHTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Jev").font(.system(size: 19, weight: .semibold))
                        Text("Facultatif · désactivé par défaut")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("Activer Jev", isOn: Binding(
                        get: { enabled },
                        set: { if $0 { confirming = true } else { monitor.setEnabled(false) } }))
                        .toggleStyle(.switch).fixedSize()
                        .disabled(!availability.canToggle(isEnabled: enabled))
                        .accessibilityIdentifier("jev-enabled")
                }
                // Always show the runtime's real status, including protected/idle/error states.
                Label(monitor.status, systemImage: monitor.timedBreak != nil ? "pause.circle" : "circle.dotted")
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("jev-status")
                Text("Avec activité : une analyse toutes les 15 s. Deux détections consécutives de procrastination déclenchent un avertissement, sans bloquer votre Mac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                connectionRow
                if !availability.localHistoryEnabled {
                    HStack(alignment: .top, spacing: 12) {
                        Text("L’historique de ce Mac doit aussi être activé. Jev ne modifie aucun accès à votre place.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Configurer l’historique", action: onOpenRecording)
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

    private var connectionRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.hasKey ? "Clé TypeSafe enregistrée" : "Connectez Jev pour commencer")
                    .font(.system(size: 13, weight: .medium))
                Text(monitor.hasKey ? "Usage facturé par TypeSafe." : "Votre clé API reste sur ce Mac. L’API TypeSafe est payante.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(monitor.hasKey ? "Gérer la connexion" : "Connecter Jev") { showingConnection = true }
                .accessibilityIdentifier("jev-open-connection")
        }
    }
}
#endif
