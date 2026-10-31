#if os(macOS)
import SwiftUI

/// Shares the same preference as History; does not introduce another source of truth.
struct VisibleContextControl: View {
    @AppStorage(ActivityAnalysisPreferences.richContextEnabledKey) private var enabled = false
    @State private var confirming = false
    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 10) {
                // UI-17B (44): only the switch dims when locked; the title and the help keep their ink (no fade under AA).
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Texte affiché").font(.system(size: 13, weight: .semibold))
                        Text("Facultatif, sur ce Mac. Peut contenir des messages et documents personnels.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Texte affiché", isOn: Binding(get: { enabled }, set: { value in
                        if value { confirming = true } else { enabled = false }
                    }))
                    .labelsHidden().toggleStyle(.goalongSwitchOnly).accessibilityIdentifier("recording-visible-text")
                }.frame(minHeight: 44)
                if enabled {
                    Text("Activé, les anciennes données sont conservées après arrêt.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
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
