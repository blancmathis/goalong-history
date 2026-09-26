#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct JevInterventionControls: View {
    @ObservedObject private var preferences: JevInterventionPreferences
    init(preferences: JevInterventionPreferences = .shared) { self.preferences = preferences }
    var body: some View {
        GoalongSettingsGroup(title: "Rappels et paliers") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dès la première détection fiable · premier rappel").font(.system(size: 14, weight: .semibold))
                Text("« Arrête de procrastiner. »")
                    .font(.callout).foregroundStyle(.secondary)
                Text("La durée ne s’affiche qu’à partir de 10 minutes. Fermer masque seulement le pop-up jusqu’à la prochaine détection ; le suivi interne et les effets continuent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Changer de position à chaque nouveau rappel", isOn: binding(\.moveAfterSecondAppearance))
                .toggleStyle(.switch).accessibilityIdentifier("jev-move-warning")
            Divider()
            Toggle("Activer les effets progressifs", isOn: binding(\.effectsEnabled))
                .toggleStyle(.switch).accessibilityIdentifier("jev-effects-enabled")
            Text("Optionnel. Par défaut : assombrissement à 2 min, puis assombrissement + rouge dès 5 min. Ensuite, ce dernier effet et les rappels continuent sans nouveau palier. Retour productif, pause ou arrêt de la surveillance dans Goalong : tout disparaît.")
                .font(.caption).foregroundStyle(.secondary)
            strengthPresets
            ForEach(0..<preferences.settings.stages.count, id: \.self) { index in
                stageRow(index)
                if index < preferences.settings.stages.count - 1 { Divider() }
            }
            Text("Assombrissement = voile visuel, pas modification de la luminosité du Mac. Aucun clignotement ni blocage des clics. L’intensité peut aller jusqu’à 85 %, sans noir total. Au-delà de 60 %, la lecture de l’écran devient nettement plus difficile. Les rappels restent au-dessus du voile et les commandes de pause et d’arrêt restent dans Goalong. Si la surveillance ne reçoit plus de résultat, les effets disparaissent sous 30 secondes.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Le compteur additionne des fenêtres de 15 s contenant de la procrastination ; il ne prouve pas que chaque seconde était improductive. Inactivité, contexte privé, erreur ou résultat indéterminé remettent la série à zéro.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = preferences.error { Text(error).foregroundStyle(LHTheme.warning).font(.caption) }
        }
    }
    private var strengthPresets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Intensité des effets").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 10) {
                ForEach(JevEffectStrength.allCases, id: \.self) { strength in
                    Button {
                        preferences.update { $0.applyStrength(strength) }
                    } label: {
                        VStack(spacing: 4) {
                            Text(strength.title).fontWeight(.semibold)
                            Text("\(strength.intensities[0]) % puis \(strength.intensities[1]) %")
                                .font(.caption)
                        }.frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("jev-strength-\(strength.rawValue)")
                    .accessibilityLabel("\(strength.title) : palier 1 à \(strength.intensities[0]) %, palier 2 à \(strength.intensities[1]) %")
                }
            }
            Text("Ces préréglages changent uniquement les intensités. Les délais et vos choix d’activation sont conservés. Vous pouvez les préparer avant d’activer les effets.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func binding(_ path: WritableKeyPath<JevInterventionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { preferences.settings[keyPath: path] }, set: { value in preferences.update { $0[keyPath: path] = value } })
    }
    private func stageBinding<T>(_ index: Int, _ path: WritableKeyPath<JevInterventionStage, T>) -> Binding<T> {
        Binding(get: { preferences.settings.stages[index][keyPath: path] },
                set: { value in preferences.update { $0.stages[index][keyPath: path] = value } })
    }
    private func stageRow(_ index: Int) -> some View {
        let stages = preferences.settings.stages
        let lower = index == 0 ? 1 : stages[index - 1].afterMinutes + 1
        let upper = index == stages.count - 1 ? 60 : stages[index + 1].afterMinutes - 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Palier \(index + 1)", isOn: stageBinding(index, \.enabled)).toggleStyle(.switch)
                    .accessibilityIdentifier("jev-stage-\(index)-enabled")
                Spacer()
                Stepper("Après \(stages[index].afterMinutes) min", value: stageBinding(index, \.afterMinutes), in: lower...upper)
                    .fixedSize().disabled(!stages[index].enabled)
                    .accessibilityIdentifier("jev-stage-\(index)-minutes")
            }
            HStack(spacing: 16) {
                if index == stages.count - 1 {
                    Text("Assombrir + rouge · puis maintien")
                        .accessibilityIdentifier("jev-stage-\(index)-effect")
                } else {
                    Picker("Effet", selection: stageBinding(index, \.effect)) {
                        ForEach(JevScreenEffect.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 280)
                        .accessibilityIdentifier("jev-stage-\(index)-effect")
                }
                Spacer(minLength: 0)
                Text("\(stages[index].intensity) %")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .accessibilityLabel("Intensité du palier \(index + 1) : \(stages[index].intensity) %")
            }.disabled(!stages[index].enabled)
            Slider(value: Binding(
                get: { Double(preferences.settings.stages[index].intensity) },
                set: { value in
                    let intensity = Int(value.rounded())
                    guard intensity != preferences.settings.stages[index].intensity else { return }
                    preferences.update { $0.stages[index].intensity = intensity }
                }), in: Double(JevInterventionSettings.intensityRange.lowerBound)...Double(JevInterventionSettings.intensityRange.upperBound), step: 5)
                .accessibilityLabel("Intensité du palier \(index + 1)")
                .accessibilityValue("\(stages[index].intensity) %")
                .accessibilityIdentifier("jev-stage-\(index)-intensity")
                .disabled(!stages[index].enabled)
        }
    }
}

/// Everyday break: affects only Jev. Deliberately has no recorder or global-pause action.
@MainActor struct JevQuickPauseControl: View {
    @ObservedObject private var monitor = JevMonitor.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Surveillance du travail").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Menu {
                if monitor.timedBreak != nil {
                    Button("Reprendre la surveillance") { monitor.endBreak() }
                }
                ForEach([5, 10, 15, 30], id: \.self) { minutes in
                    Button("Pause de \(minutes) min") { monitor.startBreak(minutes: minutes) }
                }
            } label: {
                Label(monitor.timedBreak == nil ? "Faire une pause" : String(format: "Pause · %02d:%02d", monitor.remainingSeconds / 60, monitor.remainingSeconds % 60),
                      systemImage: "cup.and.saucer")
                    .font(.system(size: 12, weight: .medium))
            }.menuStyle(.borderlessButton)
                .accessibilityIdentifier("jev-quick-pause")
                .disabled(!consents.isEnabled(.jevMonitoring) && monitor.timedBreak == nil)
            Text("Sans arrêter l’historique")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
#endif
