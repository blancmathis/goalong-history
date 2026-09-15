#if os(macOS)
import SwiftUI

/// Proposed defaults are drafts only: no source or capture is enabled by opening setup.
enum GoalongRecordingSetup {
    static let preparedKey = "goalong.recordingProposal.v2"
    static func proposed(from current: DashboardSettingsDraft) -> DashboardSettingsDraft {
        var next = current
        for signal in RecordingSignal.allCases { next[keyPath: signal.keyPath] = true }
        // Private windows and secret handling retain their independent safeguards.
        return next
    }
}

struct GoalongVisibleTextChoice: View {
    @Binding var enabled: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder").foregroundStyle(LHTheme.accent).frame(width: 24)
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Texte affiché").font(.system(size: 14, weight: .medium))
                    Text("Peut contenir des messages et documents personnels.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).accessibilityIdentifier("recording-visible-text-draft")
        }.padding(.vertical, 8)
    }
}
#endif
#if os(macOS)
struct GoalongCompleteRecordingButton: View {
    @ObservedObject var model: DashboardViewModel
    @State private var confirm = false
    var body: some View {
        Button("Tout activer, texte compris") { confirm = true }.buttonStyle(.bordered).controlSize(.large)
            .alert("Activer l’enregistrement complet ?", isPresented: $confirm) {
                Button("Annuler", role: .cancel) {}
                Button("Activer ces détails") {
                    guard model.applyRecordingChoice(GoalongRecordingSetup.proposed(from: model.appliedSettings)) else { return }
                    UserDefaults.standard.set(true, forKey: ActivityAnalysisPreferences.richContextEnabledKey)
                    ActivityAnalysisRuntime.shared.richContextPreferenceDidChange()
                }
            } message: { Text("Les titres, adresses, interactions et textes visibles seront conservés sur ce Mac. Les fenêtres privées gardent votre réglage actuel. Aucun envoi n’est autorisé par cette action.") }
    }
}
#endif
