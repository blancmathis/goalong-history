#if os(macOS)
import SwiftUI

/// Shares the same preference as History; does not introduce another source of truth.
struct VisibleContextControl: View {
    @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey) private var enabled = false
    @State private var confirming = false
    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { enabled }, set: { value in
                    if value { confirming = true } else { enabled = false }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Texte affiché").font(.system(size: 13, weight: .semibold))
                        Text("Facultatif · sur ce Mac").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).accessibilityIdentifier("recording-visible-text")
                Text("Peut contenir des messages et documents personnels.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if enabled {
                    Text("Activé · les anciennes données sont conservées après arrêt.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: enabled) { value in
            GoalongRecordingSetup.rememberVisibleText(value)
            ActivityAnalysisRuntime.shared.richContextPreferenceDidChange()
        }
        .alert("Enregistrer le texte affiché ?", isPresented: $confirming) {
            Button("Annuler", role: .cancel) {}
            Button("Autoriser le texte affiché") { enabled = true }
        } message: {
            Text("Des messages et documents personnels pourront être conservés sur ce Mac. Cela n’autorise aucun envoi à ChatGPT ou à Goalong.")
        }
    }
}
#endif
