#if os(macOS)
import LocalHistoryCore
import AppKit
import BraiseCore
import ServiceManagement
import SwiftUI

@MainActor struct BraisePage: View {
    @ObservedObject private var runtime = BraiseRuntime.shared
    var onOpenModules: () -> Void = {}
    /// Turns the module on right here; the module switch in Réglages › Modules does the same.
    var onEnable: () -> Void = { GoalongModuleStore.shared.setEnabled(.braise, true) }
    var body: some View {
        if let controller = runtime.controller { BraisePageContent(controller: controller) }
        else { BraiseUnavailableView(error: runtime.error, onRetry: { runtime.retry() }, onOpenModules: onOpenModules,
                                          onEnable: onEnable) }
    }
}

/// Module off, or a start that failed: the failure always offers a new attempt and the way to Modules.
@MainActor struct BraiseUnavailableView: View {
    let error: String?
    let onRetry: () -> Void
    let onOpenModules: () -> Void
    let onEnable: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Braise").goalongPageTitle()
            if let error {
                GoalongEmptyState(title: "Braise ne répond pas", message: error) {
                    Button("Réessayer", action: onRetry).buttonStyle(LHPrimaryButtonStyle())
                    Button("Ouvrir Réglages › Modules", action: onOpenModules).buttonStyle(LHSecondaryButtonStyle())
                }
            } else {
                GoalongEmptyState(title: "Braise est désactivée",
                                  message: "Le filtre rouge du soir s’active ici, ou dans Réglages › Modules.") {
                    Button("Activer Braise", action: onEnable).buttonStyle(LHPrimaryButtonStyle())
                        .accessibilityIdentifier("braise-enable")
                    Button("Ouvrir Réglages › Modules", action: onOpenModules).buttonStyle(LHSecondaryButtonStyle())
                }
            }
        }
        .padding(LHTheme.pageInset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LHTheme.pageBackground)
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
                    Text(controller.stateLabel).font(LHTheme.sectionTitleFont)
                    Text(controller.nextEvent).foregroundStyle(LHTheme.secondaryText)
                    HStack(spacing: 8) {
                        Button("Rétablir les couleurs") { controller.emergencyOff() }.buttonStyle(LHSecondaryButtonStyle())
                            .accessibilityIdentifier("braise-emergency-off")
                        if controller.isPaused {
                            Button("Reprendre") { controller.resume() }.buttonStyle(LHSecondaryButtonStyle())
                        } else {
                            Button("Pause 15 min") { controller.pause() }.buttonStyle(LHSecondaryButtonStyle()).disabled(!controller.active)
                        }
                    }
                }
                if let notice = controller.recoveryNotice { GoalongNote(notice, tone: .warning).accessibilityIdentifier("braise-recovery") }
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
                        if controller.preferences.rules.isEmpty { GoalongEmptyState(title: "Aucun horaire", message: "Ajoutez une plage pour le mode Auto.") }
                        ForEach(controller.preferences.rules) { rule in
                            HStack(spacing: 12) {
                                Button { editingRule = rule } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(rule.hours + (rule.crossesMidnight ? ", le lendemain" : "")).monospacedDigit()
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
                        Toggle("Lancer Goalong à l’ouverture de session", isOn: Binding(get: { controller.loginEnabled || controller.loginApprovalRequired }, set: { try? controller.setLogin($0) }))
                            .toggleStyle(.goalongSwitchInline)
                        Text("Ce réglage concerne toute l’app Goalong. Braise suit ses horaires tant que Goalong est ouverte.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        if controller.loginApprovalRequired {
                            Button("Ouvrir Réglages Système…") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(LHQuietButtonStyle())
                        }
                        Text("\(FrenchCount.count(controller.displayCount, "écran", "écrans")). Le filtre est recalculé au réveil. Il ne réveille pas le Mac.").foregroundStyle(LHTheme.secondaryText)
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
            HStack { Text(title); Spacer(); Text(GoalongUIFormat.percent(value.wrappedValue * 100)).monospacedDigit().foregroundStyle(LHTheme.secondaryText) }
            Slider(value: value, in: range).accessibilityLabel(title).accessibilityValue("\(Int(value.wrappedValue * 100)) pour cent")
        }
    }
}

@MainActor struct BraiseRuleEditor: View {
    @ObservedObject var controller: BraiseController
    @State private var draft: ScheduleRule
    @State private var error: String?
    @State private var unreadableFields: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    private let existed: Bool
    init(controller: BraiseController, initial: ScheduleRule) {
        self.controller = controller; _draft = State(initialValue: initial)
        existed = controller.preferences.rules.contains { $0.id == initial.id }
    }
    private let days = [(2, "Lun"), (3, "Mar"), (4, "Mer"), (5, "Jeu"), (6, "Ven"), (7, "Sam"), (1, "Dim")]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existed ? "Modifier l’horaire" : "Ajouter un horaire").font(LHTheme.sheetTitleFont).tracking(-0.4)
            Text("Jours de début de la plage").foregroundStyle(LHTheme.secondaryText)
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
                Button("Annuler") { dismiss() }.buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    do { try controller.saveRule(draft); dismiss() } catch { self.error = "Impossible d’ajouter cet horaire (32 plages au maximum)." }
                }.buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!draft.isValid || !unreadableFields.isEmpty)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 590)
            .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
    }
    private func time(_ title: String, minute: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            Text(title)
            ScheduleTimeField(title: title, minute: minute, onValidity: { valid in
                if valid { unreadableFields.remove(title) } else { unreadableFields.insert(title) }
            })
        }
    }
}

/// Editable "HH:mm" field with a 5-minute stepper. Typing "7", "0730" or "7:30" works.
/// The binding follows the text as soon as it parses, without reformatting it while typing.
/// Text that does not parse reports `onValidity(false)` (the sheet disables Save) and reverts on commit.
struct ScheduleTimeField: View {
    let title: String
    @Binding var minute: Int
    var onValidity: (Bool) -> Void = { _ in }
    @State private var text = ""
    @FocusState private var focused: Bool

    static func format(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    /// Minutes since midnight for "H", "HH", "HHmm", "H:mm", "H h mm"; nil when not a valid time of day.
    static func parse(_ raw: String) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        let parts = t.split(whereSeparator: { ":hH. ".contains($0) }).map(String.init).filter { !$0.isEmpty }
        var hour: Int?, min = 0
        if parts.count == 1, let n = Int(parts[0]), parts[0].allSatisfy(\.isNumber) {
            if parts[0].count <= 2 { hour = n }
            else if parts[0].count <= 4 { hour = n / 100; min = n % 100 }
        } else if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), parts[1].count <= 2 { hour = h; min = m }
        guard let hour, (0...23).contains(hour), (0...59).contains(min) else { return nil }
        return hour * 60 + min
    }

    /// Typed text -> the minute to hold. `nil` keeps the current minute (text does not parse).
    static func minute(typing text: String, current: Int) -> Int? {
        guard let parsed = parse(text) else { return nil }
        return parsed == current ? nil : parsed
    }

    private func typed(_ newText: String) {
        onValidity(Self.parse(newText) != nil)
        if let parsed = Self.minute(typing: newText, current: minute) { minute = parsed }
    }

    private func commit() {
        if let parsed = Self.parse(text) { minute = parsed }
        text = Self.format(minute)
        onValidity(true)
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("HH:mm", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 13).monospacedDigit())
                .frame(width: 52)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(LHTheme.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : LHTheme.secondaryText.opacity(0.3)))
                .accessibilityLabel(title)
                .onSubmit(commit)
                .onChange(of: focused) { if !$0 { commit() } }
            Stepper(title, value: Binding(get: { minute }, set: { minute = (($0 % 1440) + 1440) % 1440 }), in: -5...1445, step: 5)
                .labelsHidden()
        }
        .onAppear { text = Self.format(minute) }
        .onChange(of: text) { typed($0) }
        .onChange(of: minute) { if Self.parse(text) != $0 { text = Self.format($0); onValidity(true) } }
    }
}
#endif
