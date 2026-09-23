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
            Text("Consommer des vidéos ou des fils sociaux, même instructifs, compte comme procrastination. Recherches, lecture et création doivent servir les projets indiqués. Le simple fait de taper ou d’ouvrir une application de travail ne suffit pas. Sans indices suffisants, aucune alerte.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Les fenêtres privées, les données supprimées et les apps ou sites exclus ne sont pas envoyés au service.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Votre référence de travail enregistrée, plus seulement les 15 dernières secondes : applications/domaines, titres disponibles et indices d’interaction. Les clics et défilements identiques sont regroupés. Aucun historique de journée n’est transmis.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Joindre un bref extrait du texte affiché", isOn: Binding(
                get: { excerpts }, set: { if $0 { confirmingText = true } else { monitor.setIncludeText(false) } }))
                .toggleStyle(.switch).disabled(!richText)
            Text(richText ? "L’extrait est limité, filtré et transmis uniquement après ce choix supplémentaire." : "Cette option nécessite d’abord le choix local « Texte affiché ». Celui-ci n’est jamais activé par la surveillance.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Le service ne voit ni captures d’écran ni vidéos. Sur X et YouTube, la précision dépend des titres et contrôles exposés par le navigateur. Sans interaction ni lecture vidéo explicitement détectée, aucun appel n’est effectué.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Budget conservateur : requête JSON complète ≤ 800 octets UTF-8. Le compteur TypeSafe est aussi contrôlé : toute réponse annonçant 1 000 tokens ou plus suspend la surveillance. Le tokenizer et son surcoût interne ne sont pas publiés.")
                .font(.caption).foregroundStyle(.secondary)
            if let tokens = monitor.lastInputTokens {
                Text("Dernier appel : \(tokens) tokens d’entrée · \(monitor.lastRequestBytes) octets envoyés")
                    .font(.caption.monospacedDigit())
            }
            DisclosureGroup("Voir le dernier contenu envoyé (sans la clé)") {
                Text(monitor.lastPayload.isEmpty ? "Aucun contenu conservé en mémoire." : monitor.lastPayload)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            Text("Désactiver la surveillance efface son contexte en mémoire et annule la requête en cours. Un envoi déjà commencé peut avoir atteint TypeSafe. Les exclusions et l’arrêt de confidentialité restent prioritaires.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Transmettre un extrait du texte affiché ?", isPresented: $confirmingText) {
            Button("Annuler", role: .cancel) {}
            Button("Autoriser ces extraits") { monitor.setIncludeText(true) }
        } message: {
            Text("De courts passages déjà autorisés à la collecte locale pourront aussi être envoyés à TypeSafe. Ils peuvent contenir des messages ou documents personnels. Aucune nouvelle capture n’est activée.")
        }
    }
}

struct JevRecentChecksView: View {
    let checks: [JevRecentCheck]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(checks) { check in
                HStack {
                    Text(check.start, style: .time).monospacedDigit()
                    Text("–"); Text(check.end, style: .time).monospacedDigit()
                    Spacer()
                    Label(check.verdict == .procrastination ? "Procrastination présente" : check.verdict == .productive ? "Productif" : "Indéterminé",
                          systemImage: check.verdict == .procrastination ? "exclamationmark.circle" : check.verdict == .productive ? "checkmark.circle" : "questionmark.circle")
                }.font(.caption)
            }
            Text("Ces résultats ne réécrivent pas l’historique. Une fenêtre positive contient de la procrastination, sans être entièrement improductive.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor struct JevBreakControls: View {
    @ObservedObject private var monitor = JevMonitor.shared
    @State private var minutes = 10
    var body: some View {
        GoalongSettingsGroup(title: "Faire une pause") {
            if monitor.breakStorageInvalid {
                Text("Minuterie illisible : surveillance suspendue, historique inchangé.").foregroundStyle(.secondary)
                Button("Réinitialiser la pause") { monitor.endBreak() }
            } else if monitor.timedBreak != nil {
                HStack {
                    Label(String(format: "Surveillance en pause · %02d:%02d restantes", monitor.remainingSeconds / 60, monitor.remainingSeconds % 60), systemImage: "pause.circle.fill")
                        .monospacedDigit().accessibilityIdentifier("jev-break-countdown")
                    Spacer()
                    Button("Reprendre la surveillance") { monitor.endBreak() }
                        .accessibilityIdentifier("jev-end-break")
                }
            } else {
                HStack {
                    ForEach([5, 10, 15, 30], id: \.self) { duration in
                        Button("\(duration) min") { monitor.startBreak(minutes: duration) }
                            .accessibilityIdentifier("jev-break-\(duration)")
                    }
                }
                DisclosureGroup("Autre durée") {
                    HStack {
                        Stepper("Durée : \(minutes) min", value: $minutes, in: 1...120)
                        Button("Mettre en pause") { monitor.startBreak(minutes: minutes) }
                    }.padding(.top, 8)
                }
            }
            Text("La surveillance et ses rappels sont en pause. L’historique continue s’il est activé. Reprise automatique à la fin.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor final class JevMenuController: NSObject, NSMenuDelegate {
    static let shared = JevMenuController()
    private var onOpenMonitoring: () -> Void = {}
    func install(in parent: NSMenu, onOpenMonitoring: @escaping () -> Void) {
        self.onOpenMonitoring = onOpenMonitoring
        let item = NSMenuItem(title: "Surveillance temps réel", action: nil, keyEquivalent: "")
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
            menu.addItem(NSMenuItem(title: String(format: "Surveillance en pause : %02d:%02d restantes", seconds / 60, seconds % 60), action: nil, keyEquivalent: ""))
            let item = NSMenuItem(title: "Reprendre la surveillance", action: #selector(endBreak), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        } else {
            for minutes in [5, 10, 15, 30] {
                let item = NSMenuItem(title: "Pause de \(minutes) min (historique inchangé)", action: #selector(startBreak(_:)), keyEquivalent: "")
                item.tag = minutes; item.target = self; menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Ouvrir la surveillance…", action: #selector(openMonitoring), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        if monitor.enabled {
            let item = NSMenuItem(title: "Désactiver la surveillance", action: #selector(disable), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
    }
    @objc private func openMonitoring() { onOpenMonitoring() }
    @objc private func startBreak(_ sender: NSMenuItem) { JevMonitor.shared.startBreak(minutes: sender.tag) }
    @objc private func endBreak() { JevMonitor.shared.endBreak() }
    @objc private func disable() { JevMonitor.shared.setEnabled(false) }
}
#endif
