#if os(macOS)
import AppKit
import BraiseCore
import ServiceManagement
import SwiftUI

@MainActor struct BraisePage: View {
    @ObservedObject private var runtime = BraiseRuntime.shared
    var body: some View {
        if let controller = runtime.controller { BraisePageContent(controller: controller) }
        else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Braise").goalongPageTitle()
                Text(runtime.error ?? "Le module est désactivé. Activez-le dans Réglages › Modules.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            }
            .padding(LHTheme.pageInset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LHTheme.pageBackground)
        }
    }
}

/// The dashboard and menu-bar panel use the same controls and controller.
@MainActor struct BraisePageContent: View {
    @ObservedObject var controller: BraiseController
    var compact = false
    @State private var editingRule: ScheduleRule?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Braise").goalongPageTitle()
                    Text("Le filtre rouge, à vos horaires.").foregroundStyle(LHTheme.secondaryText)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.stateLabel).font(.system(size: compact ? 22 : 28, weight: .medium))
                    Text(controller.nextEvent).foregroundStyle(LHTheme.secondaryText)
                    HStack(spacing: 8) {
                        Button("Rétablir les couleurs") { controller.emergencyOff() }.buttonStyle(LHSecondaryButtonStyle())
                            .accessibilityIdentifier("braise-emergency-off")
                        if controller.isPaused {
                            Button("Reprendre") { controller.resume() }.buttonStyle(LHQuietButtonStyle())
                        } else {
                            Button("Pause 15 min") { controller.pause() }.buttonStyle(LHQuietButtonStyle()).disabled(!controller.active)
                        }
                    }
                }
                if let error = controller.errorMessage { GoalongNote(error, tone: .warning).accessibilityIdentifier("braise-error") }
                LHCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("Mode", selection: Binding(get: { controller.preferences.mode }, set: { controller.setMode($0) })) {
                            ForEach(FilterMode.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.menu).accessibilityIdentifier("braise-mode")
                        slider("Intensité du rouge", value: Binding(get: { controller.preferences.intensity }, set: { n in controller.update { $0.intensity = n } }), range: 0...1)
                        slider("Luminosité du filtre", value: Binding(get: { controller.preferences.brightness }, set: { n in controller.update { $0.brightness = n } }), range: 0.2...1)
                        Text("À 100 %, les canaux vert et bleu passent à zéro. La luminosité est logicielle ; celle de l’écran ne change pas.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
                GoalongSection(title: "Horaires", subtitle: "Les jours choisis sont ceux du début de la plage.") {
                    VStack(alignment: .leading, spacing: 12) {
                        if controller.preferences.rules.isEmpty { Text("Aucun horaire. Ajoutez une plage pour le mode Auto.").foregroundStyle(LHTheme.secondaryText) }
                        ForEach(controller.preferences.rules) { rule in
                            HStack(spacing: 12) {
                                Button { editingRule = rule } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(rule.hours + (rule.crossesMidnight ? " · lendemain" : "")).monospacedDigit()
                                        Text(rule.dayLabel).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(LHQuietButtonStyle()).accessibilityLabel("Modifier l’horaire \(rule.hours), \(rule.dayLabel)")
                                Toggle("Activer l’horaire", isOn: Binding(get: { rule.enabled }, set: { enabled in
                                    controller.update { p in if let i = p.rules.firstIndex(where: { $0.id == rule.id }) { p.rules[i].enabled = enabled } }
                                })).toggleStyle(.goalongSwitchOnly).fixedSize().accessibilityLabel("Activer l’horaire \(rule.hours)")
                            }
                            GoalongRowDivider()
                        }
                        Button("Ajouter un horaire") { editingRule = ScheduleRule(weekdays: Set(2...6)) }
                            .buttonStyle(LHSecondaryButtonStyle()).disabled(controller.preferences.rules.count >= 32)
                            .accessibilityIdentifier("braise-add-rule")
                    }
                }
                GoalongDisclosureGroup("Réglages et sécurité") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Retour aux couleurs naturelles : ⌃ ⌥ ⌘ R")
                        Text(controller.shortcutAvailable ? "Raccourci de secours global. Échap ferme le panneau sans changer le filtre." : "Raccourci indisponible ou déjà utilisé. Utilisez Rétablir les couleurs, ou le clic droit sur l’icône Braise.")
                            .foregroundStyle(LHTheme.secondaryText)
                        Toggle("Ouvrir Goalong à la connexion", isOn: Binding(get: { controller.loginEnabled || controller.loginApprovalRequired }, set: { try? controller.setLogin($0) }))
                            .toggleStyle(.goalongSwitchInline)
                        Text("Ce réglage concerne toute l’app Goalong. Braise suit ses horaires tant que Goalong est ouverte.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        if controller.loginApprovalRequired {
                            Button("Ouvrir les éléments de connexion…") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(LHQuietButtonStyle())
                        }
                        Text("\(controller.displayCount) écran(s). Le filtre est recalculé au réveil. Il ne réveille pas le Mac.").foregroundStyle(LHTheme.secondaryText)
                        Text("Aucun réseau ni nouvel accès. Les couleurs sont restaurées à l’arrêt du module, à la fermeture de Goalong ou par un gardien après un crash. Le HDR et les autres filtres peuvent modifier le résultat ; zéro lumière bleue physiquement émise n’est pas garanti.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }.fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                }
            }
            .font(.system(size: 13)).frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, compact ? 24 : LHTheme.pageInset).padding(.top, 28).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .accessibilityIdentifier("braise-page")
        .sheet(item: $editingRule) { BraiseRuleEditor(controller: controller, initial: $0).goalongControls() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshLoginStatus() }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text("\(Int((value.wrappedValue * 100).rounded())) %").monospacedDigit().foregroundStyle(LHTheme.secondaryText) }
            Slider(value: value, in: range, step: 0.01).accessibilityLabel(title).accessibilityValue("\(Int(value.wrappedValue * 100)) pour cent")
        }
    }
}

@MainActor struct BraiseRuleEditor: View {
    @ObservedObject var controller: BraiseController
    @State private var draft: ScheduleRule
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let existed: Bool
    init(controller: BraiseController, initial: ScheduleRule) {
        self.controller = controller; _draft = State(initialValue: initial)
        existed = controller.preferences.rules.contains { $0.id == initial.id }
    }
    private let days = [(2, "Lun"), (3, "Mar"), (4, "Mer"), (5, "Jeu"), (6, "Ven"), (7, "Sam"), (1, "Dim")]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existed ? "Modifier l’horaire" : "Ajouter un horaire").font(.system(size: 22, weight: .semibold))
            Text("Jours de début").foregroundStyle(LHTheme.secondaryText)
            HStack(spacing: 10) {
                ForEach(days, id: \.0) { day in
                    Toggle(day.1, isOn: Binding(get: { draft.weekdays.contains(day.0) }, set: { on in
                        if on { draft.weekdays.insert(day.0) } else { draft.weekdays.remove(day.0) }
                    })).toggleStyle(.goalongCheckbox)
                }
            }
            HStack {
                Button("Tous les jours") { draft.weekdays = Set(1...7) }
                Button("Semaine") { draft.weekdays = Set(2...6) }
                Button("Week-end") { draft.weekdays = Set([1, 7]) }
            }.buttonStyle(LHQuietButtonStyle())
            HStack(spacing: 24) { time("Activation", minute: $draft.startMinute); time("Désactivation", minute: $draft.endMinute) }
            Text(!draft.isValid ? "Choisissez au moins un jour et deux heures différentes." : draft.crossesMidnight ? "La désactivation a lieu le lendemain." : "La plage commence et se termine le même jour.")
                .foregroundStyle(LHTheme.secondaryText)
            if let error { Text(error).foregroundStyle(LHTheme.secondaryText) }
            HStack {
                if existed { Button("Supprimer", role: .destructive) { controller.deleteRule(draft.id); dismiss() }.buttonStyle(LHQuietButtonStyle()) }
                Spacer()
                Button("Annuler") { dismiss() }.buttonStyle(LHQuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    do { try controller.saveRule(draft); dismiss() } catch { self.error = "Impossible d’ajouter cet horaire (32 plages au maximum)." }
                }.buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!draft.isValid)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 590)
            .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
    }
    private func time(_ title: String, minute: Binding<Int>) -> some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in minute.wrappedValue = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date) }), displayedComponents: .hourAndMinute)
            .environment(\.locale, Locale(identifier: "fr_FR"))
    }
}
#endif
