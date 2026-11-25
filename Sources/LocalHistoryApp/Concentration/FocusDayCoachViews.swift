#if os(macOS)
import AppKit
import SwiftUI

@MainActor struct FocusDayCoachSettingsView: View {
    @ObservedObject var controller: ConcentrationController
    @ObservedObject private var runtime = FocusDayCoachRuntime.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @State private var error: String?
    private var settings: FocusDayCoachSettings { controller.settings.coachSettings }
    private var selectedModel: FocusDayCoachModel? { runtime.models.first { $0.id == settings.model } }

    var body: some View {
        GoalongSettingsGroup(title: "Conseil à la demande") {
            Text("Un bilan court pour choisir la suite. L’agenda, ses ajustements et les rappels fonctionnent sans appel d’IA.")
                .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            Picker("Avec", selection: binding(\.provider)) {
                ForEach(FocusDayCoachSettings.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("focus-coach-provider")
            if settings.provider == .chatGPT {
                chatGPTChoices
            } else {
                Text("Utilisez votre agent dans Claude Code ou T3 pour lire et mettre à jour Goalong par son CLI. Goalong ne récupère aucun identifiant Claude et ne lance aucun appel en arrière-plan.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Afficher le conseil à la demande", isOn: binding(\.enabled))
                .toggleStyle(.goalongSwitch)
                .disabled(!settings.enabled && settings.provider == .chatGPT && (settings.model == nil || settings.reasoningEffort == nil))
                .accessibilityIdentifier("focus-coach-enabled")
            if let error { GoalongNote(error, tone: .warning, onDismiss: { self.error = nil }) }
            if let error = runtime.error { GoalongNote(error, tone: .warning, onDismiss: runtime.clearError) }
        }
        .onChange(of: controller.settings.coach) { _ in runtime.invalidatePreview(); runtime.refreshUsage(settings: settings) }
        .onAppear { runtime.refreshUsage(settings: settings) }
    }
    private var chatGPTChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !consents.isEnabled(.chatGPTAnalysis) {
                Text("Pour l’utiliser, connectez votre compte et autorisez les analyses dans Réglages › Analyse ChatGPT.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            HStack(spacing: 12) {
                Button(runtime.isLoadingModels ? "Lecture du catalogue…" : "Lire les modèles disponibles") {
                    Task { try? await runtime.loadModels() }
                }.buttonStyle(LHSecondaryButtonStyle())
                    .disabled(runtime.isBusy || !consents.isEnabled(.chatGPTAnalysis))
                    .accessibilityIdentifier("focus-coach-load-models")
                Text("Aucune génération").font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
            }
            if !runtime.models.isEmpty {
                Picker("Modèle", selection: Binding(get: { settings.model ?? "" }, set: chooseModel)) {
                    Text("Choisir un modèle").tag("")
                    if let id = settings.model, !runtime.models.contains(where: { $0.id == id }) {
                        Text("\(id) · absent du catalogue").tag(id)
                    }
                    ForEach(runtime.models) { Text($0.displayName).tag($0.id) }
                }.pickerStyle(.menu).accessibilityIdentifier("focus-coach-model")
            } else if let model = settings.model {
                Text("Modèle choisi : \(model)").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            if let model = selectedModel {
                Picker("Effort de raisonnement", selection: Binding(get: { settings.reasoningEffort ?? "" }, set: { value in
                    update { $0.reasoningEffort = value }
                })) {
                    ForEach(model.reasoningEfforts, id: \.self) { Text(effortName($0)).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("focus-coach-effort")
            } else if let effort = settings.reasoningEffort {
                Text("Effort choisi : \(effortName(effort))").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            Text("Commencez par un effort faible pour un bilan simple. Un effort plus élevé peut consommer davantage ; aucun modèle de remplacement n’est choisi automatiquement.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            Stepper("Au maximum \(settings.dailyCallLimit) demande\(settings.dailyCallLimit > 1 ? "s" : "") par jour",
                    value: binding(\.dailyCallLimit), in: 1...6)
                .accessibilityIdentifier("focus-coach-daily-limit")
            Stepper("Réponse : jusqu’à \(settings.maximumOutputCharacters) caractères",
                    value: binding(\.maximumOutputCharacters), in: 600...4000, step: 200)
            Text("Données proposées dans l’aperçu").font(.system(size: 12, weight: .semibold))
            Toggle("Actions, prochaine étape et critère de fin", isOn: binding(\.includeTasks)).toggleStyle(.goalongSwitch)
            Toggle("Horaires et état des plages", isOn: binding(\.includeAgenda)).toggleStyle(.goalongSwitch)
            Toggle("Titres et état des processus parallèles", isOn: binding(\.includeProcesses)).toggleStyle(.goalongSwitch)
            Toggle("Note du bilan du jour", isOn: binding(\.includeReview)).toggleStyle(.goalongSwitch)
            Text("Les masquages d’Analyse ChatGPT s’appliquent. L’historique du Mac, les documents et les conversations des agents ne sont pas inclus. Vous vérifiez l’aperçu avant chaque demande.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func binding<T>(_ key: WritableKeyPath<FocusDayCoachSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
    private func update(_ change: (inout FocusDayCoachSettings) -> Void) {
        var next = settings; change(&next)
        if next.provider == .chatGPT && (next.model == nil || next.reasoningEffort == nil) { next.enabled = false }
        do { try controller.updateCoachSettings(next); error = nil; runtime.invalidatePreview() }
        catch { self.error = "Le réglage du coach n’a pas pu être enregistré." }
    }
    private func chooseModel(_ id: String) {
        update { value in
            guard let choice = runtime.models.first(where: { $0.id == id }) else {
                value.model = nil; value.reasoningEffort = nil; value.enabled = false; return
            }
            value.model = choice.id
            if !choice.reasoningEfforts.contains(value.reasoningEffort ?? "") {
                value.reasoningEffort = choice.defaultReasoningEffort ?? choice.reasoningEfforts.first
            }
        }
    }
    private func effortName(_ value: String) -> String {
        switch value {
        case "low": return "Faible"
        case "medium": return "Moyen"
        case "high": return "Élevé"
        default: return value
        }
    }
}

@MainActor struct FocusDayCoachCard: View {
    @ObservedObject var controller: ConcentrationController
    @ObservedObject private var runtime = FocusDayCoachRuntime.shared
    @State private var note = ""
    @State private var showingPreview = false
    @State private var copied = false
    private var settings: FocusDayCoachSettings { controller.settings.coachSettings }

    var body: some View {
        Group {
            if settings.enabled {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Un conseil pour la suite").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if settings.provider == .chatGPT, let usage = runtime.usage {
                            Text("\(usage.calls)/\(usage.limit) demande\(usage.limit > 1 ? "s" : "") aujourd’hui")
                                .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                        }
                    }
                    if settings.provider == .externalAgent {
                        Text("Votre agent peut préparer la suite, coordonner plusieurs processus et tenir l’agenda à jour.")
                            .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                        Button(copied ? "Consigne copiée" : "Copier la consigne pour mon agent") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.externalInstructions, forType: .string)
                            copied = true
                        }.buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("focus-coach-external-copy")
                    } else {
                        TextField("Un obstacle à signaler ? Facultatif.", text: $note)
                            .textFieldStyle(.roundedBorder).disabled(runtime.isBusy)
                            .accessibilityIdentifier("focus-coach-note")
                        if let value = runtime.result, value.day == controller.plan.day { answer(value) }
                        HStack(spacing: 12) {
                            Button(runtime.isBusy && !runtime.isLoadingModels ? "Conseil en cours…" : "Vérifier les données et demander") {
                                runtime.preparePreview(controller: controller, note: note)
                                showingPreview = runtime.preview != nil
                            }.buttonStyle(LHSecondaryButtonStyle())
                                .disabled(runtime.isBusy || note.count > 1000 || runtime.usage?.remaining == 0)
                                .accessibilityIdentifier("focus-coach-preview")
                            if runtime.isBusy {
                                Button("Arrêter", action: runtime.cancel).buttonStyle(LHQuietButtonStyle())
                            }
                        }
                        if runtime.usage?.remaining == 0 {
                            Text("Le quota de conseils est atteint. Votre agenda et ses rappels restent disponibles.")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        }
                        if let error = runtime.error { GoalongNote(error, tone: .warning, onDismiss: runtime.clearError) }
                    }
                }
                .padding(16).background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("focus-coach-card")
            }
        }
        .onAppear { runtime.refreshUsage(settings: settings) }
        .onChange(of: note) { _ in runtime.discardPreview() }
        .onChange(of: controller.plan.effectiveRevision) { _ in runtime.discardPreview() }
        .onChange(of: controller.plan.day) { _ in runtime.discardPreview(); runtime.refreshUsage(settings: settings) }
        .onChange(of: controller.settings.coach) { _ in runtime.invalidatePreview(); runtime.refreshUsage(settings: settings) }
        .sheet(isPresented: $showingPreview) {
            FocusDayCoachPreviewSheet(runtime: runtime, onClose: { showingPreview = false }, onSend: {
                showingPreview = false
                Task { try? await runtime.generate(controller: controller) }
            }).goalongControls()
        }
    }
    private func answer(_ value: FocusDayCoachResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.answer.summary).font(.system(size: 13))
            Label(value.answer.nextAction, systemImage: "arrow.right.circle").font(.system(size: 13, weight: .medium))
            if !value.answer.adjustment.isEmpty { Text(value.answer.adjustment).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText) }
            if !value.answer.question.isEmpty { Text(value.answer.question).font(.system(size: 13)) }
            Text("\(value.model) · \(value.reasoningEffort)" + (value.tokens.map { " · \($0) tokens rapportés" } ?? " · usage non communiqué"))
                .font(.system(size: 10)).foregroundStyle(LHTheme.secondaryText)
            if value.planRevision != controller.plan.effectiveRevision {
                Text("Le plan a évolué depuis cette demande. Vérifiez que le conseil convient encore.")
                    .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
            }
            Text("Proposition à examiner ; l’agenda n’a pas été modifié.")
                .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
        }.textSelection(.enabled).accessibilityIdentifier("focus-coach-result")
    }
    static let externalInstructions = """
    Lis mon plan avec goalong plan show today et mon bilan avec goalong review show today.
    Aide-moi à choisir le prochain geste utile, en distinguant mon travail des processus
    délégués qui avancent en parallèle. Réponds brièvement, avec zéro ou une question.
    Propose un plan réaliste, garde les contraintes de repos et n’invente pas de tâche terminée.
    Utilise les commandes documentées du CLI Goalong pour mettre à jour le plan convenu,
    avec sa révision actuelle. Ne récupère aucun identifiant d’un autre outil.
    """
}

@MainActor private struct FocusDayCoachPreviewSheet: View {
    @ObservedObject var runtime: FocusDayCoachRuntime
    let onClose: () -> Void
    let onSend: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vérifiez ce qui sera envoyé").font(LHTheme.sheetTitleFont)
            if let value = runtime.preview {
                Text("\(value.settings.model ?? "") · \(value.settings.reasoningEffort ?? "") · \(value.characterCount) caractères")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                ScrollView {
                    Text(value.outboundText).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("focus-coach-exact-preview")
                Text("Une seule demande. Le compteur conserve les demandes envoyées, même si elles échouent ou sont arrêtées. Les limites de réponse ne constituent pas un plafond exact de tokens de raisonnement.")
                    .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Le contexte a changé. Fermez cette fenêtre et préparez un nouvel aperçu.")
            }
            HStack {
                Button("Annuler", action: onClose).buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Envoyer cette demande", action: onSend).buttonStyle(LHPrimaryButtonStyle())
                    .disabled(runtime.preview == nil || runtime.isBusy)
                    .accessibilityIdentifier("focus-coach-send")
            }
        }.padding(24).frame(width: 680, height: 620)
    }
}
#endif
