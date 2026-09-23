#if os(macOS)
import SwiftUI
import LocalHistoryCore

@MainActor struct JevInterventionControls: View {
    @ObservedObject private var preferences = JevInterventionPreferences.shared
    var body: some View {
        GoalongSettingsGroup(title: "Rappels et paliers") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dès la première détection fiable · premier rappel").font(.system(size: 14, weight: .semibold))
                Text("« Arrête de procrastiner. Ça fait 15 secondes que tu procrastines. »")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Fermer masque seulement le pop-up jusqu’à la prochaine détection. Le compteur et les effets continuent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Changer de position à chaque nouveau rappel", isOn: binding(\.moveAfterSecondAppearance))
                .toggleStyle(.switch).accessibilityIdentifier("jev-move-warning")
            Divider()
            Toggle("Activer les effets progressifs", isOn: binding(\.effectsEnabled))
                .toggleStyle(.switch).accessibilityIdentifier("jev-effects-enabled")
            Text("Optionnel. Par défaut : assombrissement à 2 min, puis assombrissement + rouge dès 5 min. Ensuite, ce dernier effet et les rappels continuent sans nouveau palier. Retour productif, pause ou arrêt de la surveillance dans Goalong : tout disparaît.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(0..<preferences.settings.stages.count, id: \.self) { index in
                stageRow(index)
                if index < preferences.settings.stages.count - 1 { Divider() }
            }
            Text("Assombrissement = voile visuel, pas modification de la luminosité du Mac. Aucun clignotement ni blocage des clics. L’intensité est limitée à 40 %. Si la surveillance ne reçoit plus de résultat, les effets disparaissent sous 30 secondes.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Le compteur additionne des fenêtres de 15 s contenant de la procrastination ; il ne prouve pas que chaque seconde était improductive. Inactivité, contexte privé, erreur ou résultat indéterminé remettent la série à zéro.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = preferences.error { Text(error).foregroundStyle(LHTheme.warning).font(.caption) }
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
                Stepper("Intensité : \(stages[index].intensity) %", value: stageBinding(index, \.intensity), in: 10...40, step: 5)
                    .fixedSize().accessibilityIdentifier("jev-stage-\(index)-intensity")
            }.disabled(!stages[index].enabled)
        }.disabled(!preferences.settings.effectsEnabled)
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
