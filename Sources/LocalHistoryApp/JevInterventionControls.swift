#if os(macOS)
import SwiftUI
import LocalHistoryCore

/// « Personnaliser » of a « Surveillance » block (T-050 B1): the rows of one rule or session. It edits a draft; the
/// editor saves it with the rule. The strength sits outside, as three choices.
@MainActor struct JevInterventionControls: View {
    @Binding var settings: JevInterventionSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Changer de position à chaque nouveau rappel", isOn: $settings.moveAfterSecondAppearance)
                .toggleStyle(.goalongSwitch).accessibilityIdentifier("jev-move-warning")
            Toggle("Voiles progressifs", isOn: $settings.effectsEnabled)
                .toggleStyle(.goalongSwitch).accessibilityIdentifier("jev-effects-enabled")
            Text("Un voile sur l’écran, sans toucher à la luminosité du Mac ni bloquer les clics. Si Jev ne reçoit plus de résultat, les effets disparaissent sous 30 secondes.")
                .font(.caption).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(0..<settings.stages.count, id: \.self) { index in
                stageRow(index).disabled(!settings.effectsEnabled)
                if index < settings.stages.count - 1 { Divider() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("jev-intervention-settings")
    }
    private func stageBinding<T>(_ index: Int, _ path: WritableKeyPath<JevInterventionStage, T>) -> Binding<T> {
        Binding(get: { settings.stages[index][keyPath: path] }, set: { settings.stages[index][keyPath: path] = $0 })
    }
    private func stageRow(_ index: Int) -> some View {
        let stages = settings.stages
        let lower = index == 0 ? 1 : stages[index - 1].afterMinutes + 1
        let upper = index == stages.count - 1 ? 60 : stages[index + 1].afterMinutes - 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Palier \(index + 1)", isOn: stageBinding(index, \.enabled)).toggleStyle(.goalongSwitchInline)
                    .accessibilityIdentifier("jev-stage-\(index)-enabled")
                Spacer()
                Stepper("Après \(stages[index].afterMinutes) min", value: stageBinding(index, \.afterMinutes), in: lower...upper)
                    .fixedSize().disabled(!stages[index].enabled)
                    .accessibilityIdentifier("jev-stage-\(index)-minutes")
            }
            HStack(spacing: 16) {
                if index == stages.count - 1 {
                    Text("Assombrir + rouge, puis maintien")
                        .accessibilityIdentifier("jev-stage-\(index)-effect")
                } else {
                    Picker("Effet", selection: stageBinding(index, \.effect)) {
                        ForEach(JevScreenEffect.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 280)
                        .accessibilityIdentifier("jev-stage-\(index)-effect")
                }
                Spacer(minLength: 0)
                Text(GoalongUIFormat.percent(stages[index].intensity))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .accessibilityLabel("Intensité du palier \(index + 1) : \(GoalongUIFormat.percent(stages[index].intensity))")
            }.disabled(!stages[index].enabled)
            Slider(value: Binding(
                get: { Double(settings.stages[index].intensity) },
                set: { value in
                    let intensity = Int(value.rounded())
                    guard intensity != settings.stages[index].intensity else { return }
                    settings.stages[index].intensity = intensity
                }), in: Double(JevInterventionSettings.intensityRange.lowerBound)...Double(JevInterventionSettings.intensityRange.upperBound), step: 5)
                .accessibilityLabel("Intensité du palier \(index + 1)")
                .accessibilityValue(GoalongUIFormat.percent(stages[index].intensity))
                .accessibilityIdentifier("jev-stage-\(index)-intensity")
                .disabled(!stages[index].enabled)
        }
    }
}
#endif
