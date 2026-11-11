#if os(macOS)
import AppKit
import SwiftUI
import LocalHistoryCore

@MainActor struct JevPrivacyControls: View {
    @ObservedObject private var monitor = JevMonitor.shared
    @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey) private var richText = false
    @AppStorage(JevMonitor.excerptKey) private var excerpts = false
    @State private var confirmingText = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vidéos et fils sociaux sont considérés comme des distractions, sauf les usages explicitement autorisés. Vos exemples hors travail ajoutent des repères prioritaires, pas une liste exhaustive. Recherches, lecture et création doivent servir les critères de travail indiqués. Le simple fait de taper ou d’ouvrir une application de travail ne suffit pas. Sans indices suffisants, aucune alerte.")
                .font(.callout).foregroundStyle(LHTheme.secondaryText)
            Text("Les fenêtres privées, les données supprimées et les apps ou sites exclus ne sont pas envoyés au service.")
                .font(.callout).foregroundStyle(LHTheme.secondaryText)
            Text("Vos critères de travail et exemples hors travail enregistrés, plus seulement les 15 dernières secondes : applications/domaines, titres disponibles et indices d’interaction. Les clics et défilements identiques sont regroupés. Aucun historique de journée n’est transmis.")
                .font(.callout).foregroundStyle(LHTheme.secondaryText)
            Toggle("Joindre un bref extrait du texte affiché", isOn: Binding(
                get: { excerpts }, set: { if $0 { confirmingText = true } else { monitor.setIncludeText(false) } }))
                .toggleStyle(.goalongSwitch).disabled(!richText)
            Text(richText ? "Les extraits visibles sont rafraîchis quand Jev est activé, séparés du titre et filtrés. Les champs de saisie et le texte hors de la zone visible sont exclus." : "Cette option nécessite d’abord le choix local « Texte affiché ». Celui-ci n’est jamais activé par Jev.")
                .font(.caption).foregroundStyle(LHTheme.secondaryText)
            Text("Le service ne voit ni captures d’écran ni vidéos. Sur X et YouTube, la précision dépend des titres et contrôles exposés par le navigateur. La lecture au premier plan reste suivie pendant le délai d’inactivité choisi. Une lecture vidéo explicitement détectée peut continuer sans clavier ; un onglet d’arrière-plan ne suffit pas.")
                .font(.caption).foregroundStyle(LHTheme.secondaryText)
            Text("Chaque envoi est limité à 1 600 octets. Jev se suspend si le service signale un usage trop élevé.")
                .font(.caption).foregroundStyle(LHTheme.secondaryText)
            if let tokens = monitor.lastInputTokens {
                Text("Dernier appel : \(monitor.lastRequestBytes) octets envoyés.")
                    .font(.caption.monospacedDigit())
            }
            GoalongDisclosureGroup("Voir le dernier contenu envoyé (sans la clé)") {
                Text(monitor.lastPayload.isEmpty ? "Aucun contenu conservé en mémoire." : monitor.lastPayload)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            Text("Désactiver Jev efface les échantillons d’activité et la dernière requête en mémoire et annule la requête en cours. Un envoi déjà commencé peut avoir atteint TypeSafe. Les exclusions et l’arrêt de confidentialité restent prioritaires.")
                .font(.caption).foregroundStyle(LHTheme.secondaryText)
        }
        .alert("Transmettre un extrait du texte affiché ?", isPresented: $confirmingText) {
            Button("Annuler", role: .cancel) {}
            Button("Autoriser ces extraits") { monitor.setIncludeText(true) }
        } message: {
            Text("De courts passages déjà autorisés à la collecte locale pourront aussi être envoyés à TypeSafe. Ils peuvent contenir des messages ou documents personnels. Aucun nouvel accès système n’est demandé. Les champs éditables ne sont pas lus pour ces extraits.")
        }
    }
}

struct JevRecentChecksView: View {
    let checks: [JevRecentCheck]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(checks) { check in
                HStack {
                    Text(GoalongUIFormat.time(check.start)).monospacedDigit()
                    Text("–"); Text(GoalongUIFormat.time(check.end)).monospacedDigit()
                    Spacer()
                    Label(check.verdict == .procrastination ? "Distraction repérée" : check.verdict == .productive ? "Travail" : "Indéterminé",
                          systemImage: check.verdict == .procrastination ? "exclamationmark.circle" : check.verdict == .productive ? "checkmark.circle" : "questionmark.circle")
                }.font(.caption)
            }
            Text("Ces résultats ne réécrivent pas l’historique. Une fenêtre signalée contient une distraction, sans être entièrement hors travail.")
                .font(.caption).foregroundStyle(LHTheme.secondaryText)
        }
    }
}

/// A pause of Jev can no longer be started (T-050 B1 point 6): a rule or a session says when Jev watches. This group
/// only shows a pause started before the update (it ends by itself) and the repair of an unreadable timer.
@MainActor struct JevBreakControls: View {
    @ObservedObject private var monitor = JevMonitor.shared
    var body: some View {
        if monitor.breakStorageInvalid || monitor.timedBreak != nil {
            group
        }
    }

    private var group: some View {
        GoalongSettingsGroup(title: "Suspension en cours") {
            if monitor.breakStorageInvalid {
                Text(JevMonitor.unreadableBreakNotice).foregroundStyle(LHTheme.secondaryText)
                Button("Reprendre") { monitor.endBreak() }
            } else if monitor.timedBreak != nil {
                HStack {
                    Label("Jev suspendu · " + GoalongUIFormat.remaining(TimeInterval(monitor.remainingSeconds)), systemImage: "pause.circle.fill")
                        .monospacedDigit().accessibilityIdentifier("jev-break-countdown")
                    Spacer()
                    Button("Reprendre Jev") { monitor.endBreak() }
                        .accessibilityIdentifier("jev-end-break")
                }
            }
            if monitor.timedBreak != nil {
                Text("Jev et ses rappels sont suspendus. Reprise automatique à la fin.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
        }
    }
}

@MainActor final class JevMenuController: NSObject, NSMenuDelegate {
    static let shared = JevMenuController()
    private var onOpenMonitoring: () -> Void = {}
    func install(in parent: NSMenu, onOpenMonitoring: @escaping () -> Void) {
        self.onOpenMonitoring = onOpenMonitoring
        let item = NSMenuItem(title: "Jev", action: nil, keyEquivalent: "")
        let menu = NSMenu(); menu.delegate = self; item.submenu = menu
        parent.addItem(item)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let monitor = JevMonitor.shared
        let status = NSMenuItem(title: monitor.status, action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status); menu.addItem(.separator())
        if monitor.timedBreak != nil {
            let seconds = monitor.timedBreak?.remaining(at: Date()) ?? 0
            menu.addItem(NSMenuItem(title: "Jev suspendu · " + GoalongUIFormat.remaining(TimeInterval(seconds)), action: nil, keyEquivalent: ""))
            let item = NSMenuItem(title: "Reprendre Jev", action: #selector(endBreak), keyEquivalent: "")
            item.target = self; menu.addItem(item)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: "Ouvrir Jev…", action: #selector(openMonitoring), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        if monitor.enabled {
            let item = NSMenuItem(title: "Désactiver Jev", action: #selector(disable), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
    }
    @objc private func openMonitoring() { onOpenMonitoring() }
    @objc private func endBreak() { JevMonitor.shared.endBreak() }
    @objc private func disable() { if JevStopGate.confirm(action: "Désactiver Jev") { JevMonitor.shared.setEnabled(false) } }
}
#endif
