#if os(macOS)
import SwiftUI

/// An optional guide, separate from the security-sensitive Garde-fous module switch.
@MainActor struct FocusDayGuideModuleSettings: View {
    @ObservedObject var runtime: ConcentrationRuntime
    let onEnableModule: () -> Bool
    let onOpen: () -> Void
    @State private var showingIntroduction = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let controller = runtime.controller {
                FocusDayGuideControls(controller: controller, onRequestActivation: { showingIntroduction = true },
                                      onExplain: { showingIntroduction = true }, onOpen: onOpen)
                FocusDayCoachSettingsView(controller: controller)
            } else {
                GoalongSettingsGroup(title: "Journée guidée") {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Savoir quoi faire maintenant").font(.system(size: 14, weight: .medium))
                            Text("Votre programme, ses consignes et les processus en parallèle. Aucun horaire ni rappel n’est ajouté sans votre choix.")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("Activer la journée guidée", isOn: Binding(get: { false }, set: { if $0 { showingIntroduction = true } }))
                            .toggleStyle(.goalongSwitchOnly).fixedSize()
                            .accessibilityIdentifier("settings-day-guide-enabled")
                    }
                    Button("Découvrir la journée guidée") { showingIntroduction = true }
                        .buttonStyle(LHSecondaryButtonStyle())
                    Text("L’activation démarre le suivi du programme dans Concentration. Les blocages conservent leurs propres réglages.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error { GoalongNote(error, tone: .warning) }
        }
        .accessibilityIdentifier("settings-day-guide")
        .sheet(isPresented: $showingIntroduction) {
            FocusDayGuideIntro(enabled: runtime.controller?.settings.dayGuideSettings.enabled == true,
                              error: error, onContinue: activateOrAcknowledge,
                              onClose: { showingIntroduction = false; error = nil })
                .goalongControls()
        }
    }

    private func activateOrAcknowledge() {
        if runtime.controller == nil, !onEnableModule() {
            error = "Concentration n’a pas pu démarrer. Réessayez depuis les réglages du module."
            return
        }
        guard let controller = runtime.controller else {
            error = runtime.error.map { FocusUIError.message(raw: $0) } ?? "Concentration n’est pas encore disponible."
            return
        }
        var settings = controller.settings.dayGuideSettings
        settings.enabled = true
        settings.introVersion = FocusDayGuideIntro.version
        do {
            try controller.updateDayGuideSettings(settings)
            error = nil
            showingIntroduction = false
        } catch { self.error = FocusUIError.message(error) }
    }
}

@MainActor struct FocusDayGuideControls: View {
    @ObservedObject var controller: ConcentrationController
    let onRequestActivation: () -> Void
    let onExplain: () -> Void
    let onOpen: () -> Void
    @State private var error: String?
    @State private var quietOpen = false
    @State private var quietStart = ""
    @State private var quietEnd = ""
    @State private var quietDirty = false
    @State private var quietError: String?

    var body: some View {
        GoalongSettingsGroup(title: "Journée guidée") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Savoir quoi faire maintenant").font(.system(size: 14, weight: .medium))
                    Text("Le programme est enregistré sur ce Mac. Vous ou un agent choisissez les actions, les horaires et les rappels.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Activer la journée guidée", isOn: Binding(
                    get: { controller.settings.dayGuideSettings.enabled },
                    set: { enabled in
                        if enabled { onRequestActivation() }
                        else { update { $0.enabled = false } }
                    }))
                    .toggleStyle(.goalongSwitchOnly).fixedSize()
                    .accessibilityIdentifier("settings-day-guide-enabled")
            }
            if controller.settings.dayGuideSettings.enabled {
                Divider()
                Toggle("Afficher les rappels de mon programme", isOn: Binding(
                    get: { controller.settings.dayGuideSettings.remindersEnabled },
                    set: { enabled in update { $0.remindersEnabled = enabled } }))
                    .toggleStyle(.goalongSwitch)
                    .accessibilityIdentifier("settings-day-guide-reminders")
                Text("Chaque créneau peut rester silencieux. Le plafond quotidien se règle dans l’agenda. Fermer un rappel ne termine pas l’action.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GoalongDisclosureGroup("Plage silencieuse", isExpanded: $quietOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Aucun rappel de journée pendant cette plage, y compris ceux demandés par un créneau. Le programme reste consultable ; la plage peut traverser minuit.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 14) {
                        GoalongFormField(title: "Début") {
                            TextField("hh:mm", text: quietBinding($quietStart))
                                .textFieldStyle(GoalongFieldStyle(textFont: .monospaced14))
                                .accessibilityLabel("Début de la plage silencieuse")
                        }.frame(width: 120)
                        GoalongFormField(title: "Fin") {
                            TextField("hh:mm", text: quietBinding($quietEnd))
                                .textFieldStyle(GoalongFieldStyle(textFont: .monospaced14))
                                .accessibilityLabel("Fin de la plage silencieuse")
                        }.frame(width: 120)
                        Spacer(minLength: 8)
                    }
                    HStack(spacing: 12) {
                        Button("Enregistrer la plage") { saveQuietHours() }
                            .buttonStyle(LHSecondaryButtonStyle())
                            .disabled(!quietDirty)
                        if controller.settings.dayGuideSettings.quietStartMinute != nil {
                            Button("Retirer la plage") {
                                update { $0.quietStartMinute = nil; $0.quietEndMinute = nil }
                                if error == nil { loadQuietHours() }
                            }.buttonStyle(LHQuietButtonStyle())
                        }
                    }
                    if let quietError { GoalongNote(quietError, tone: .warning) }
                }.padding(.top, 12)
            }
            .collapsedSummary(quietSummary)
            .font(.system(size: 13))
            .accessibilityIdentifier("settings-day-guide-quiet-hours")
            HStack(spacing: 12) {
                Button("Ouvrir mon programme", action: onOpen).buttonStyle(LHSecondaryButtonStyle())
                Button("Revoir l’explication", action: onExplain).buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("settings-day-guide-explanation")
            }
            if !controller.settings.dayGuideSettings.enabled {
                Text("Le programme reste consultable. Réactivez la journée guidée pour retrouver ses rappels et ses ajustements automatiques.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { GoalongNote(error, tone: .warning) }
        }
        .onAppearWhenShown { loadQuietHours() }
        .onChange(of: controller.settings.dayGuideSettings) { _ in
            if !quietDirty { loadQuietHours() }
        }
    }

    private var quietSummary: String {
        let settings = controller.settings.dayGuideSettings
        guard let start = settings.quietStartMinute, let end = settings.quietEndMinute else { return "Aucune" }
        return "\(FocusDayUI.time(start))–\(FocusDayUI.time(end))"
    }

    private func quietBinding(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { value in
            binding.wrappedValue = value
            quietDirty = true
            quietError = nil
        })
    }

    private func loadQuietHours() {
        let settings = controller.settings.dayGuideSettings
        quietStart = settings.quietStartMinute.map(FocusDayUI.time) ?? ""
        quietEnd = settings.quietEndMinute.map(FocusDayUI.time) ?? ""
        quietDirty = false
        quietError = nil
    }

    private func saveQuietHours() {
        guard let start = FocusDayUI.minute(quietStart), let end = FocusDayUI.minute(quietEnd),
              start < 1440, end < 1440, start != end else {
            quietError = "Indiquez deux heures différentes, de 00:00 à 23:59, au format hh:mm."
            return
        }
        update { $0.quietStartMinute = start; $0.quietEndMinute = end }
        if error == nil { loadQuietHours() }
    }

    private func update(_ edit: (inout FocusDayGuideSettings) -> Void) {
        var settings = controller.settings.dayGuideSettings
        edit(&settings)
        do { try controller.updateDayGuideSettings(settings); error = nil }
        catch { self.error = FocusUIError.message(error) }
    }
}

/// A short, reusable explanation. Opening it never enables the guide or starts an AI call.
struct FocusDayGuideIntro: View {
    static let version = 1
    let enabled: Bool
    var error: String? = nil
    let onContinue: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Label("Journée guidée", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                Text("Votre programme, au fil de la journée").font(LHTheme.sheetTitleFont)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Goalong affiche l’action à suivre et garde vos horaires en vue. Préparez votre programme vous-même ou avec un agent.")
                    .font(.system(size: 14)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 16) {
                explanation("Une consigne claire", symbol: "text.alignleft",
                            text: "Chaque créneau peut préciser quoi faire et comment commencer. Fermer un rappel ne termine pas l’action : elle reste dans le programme.")
                explanation("Une journée qui s’ajuste", symbol: "calendar",
                            text: "Les actions souples peuvent se replacer après un changement. Les repères fixes et la fin de travail restent en place ; ce qui ne tient plus est indiqué à replacer.")
                explanation("Seul ou avec plusieurs agents", symbol: "arrow.triangle.branch",
                            text: "Vos actions occupent votre attention. Les processus avancent en parallèle, avec leurs questions et les résultats à relire.")
                explanation("Votre programme, vos choix", symbol: "slider.horizontal.3",
                            text: "Aucun programme personnel n’est ajouté. Tout se configure dans l’agenda, y compris les consignes hors du Mac et les créneaux silencieux. L’aide IA est facultative et se règle séparément.")
            }
            .padding(18)
            .background(GoalongSurface(corner: LHTheme.cardRadius, fill: LHTheme.controlBackground))
            if let error { GoalongNote(error, tone: .warning) }
            HStack(spacing: 12) {
                Text("Vous retrouverez cette explication dans Réglages › Modules.")
                    .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if !enabled {
                    Button("Plus tard", action: onClose).buttonStyle(LHSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                Button(enabled ? "C’est compris" : "Activer la journée guidée", action: onContinue)
                    .buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("day-guide-intro-continue")
            }
        }
        .padding(28).frame(width: 650)
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("day-guide-introduction")
    }

    private func explanation(_ title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(LHTheme.secondaryText).frame(width: 21, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(text).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
