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
                        Text("Visible-text context").font(.system(size: 13, weight: .semibold))
                        Text("Independent control · applies immediately").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).accessibilityIdentifier("recording-visible-text")
                Text("Off by default. When enabled with Computer History, selected and visible text exposed by Accessibility can be stored. It may include messages, documents or personal information, even though keystrokes are never decoded. Exclusions, secure fields and the private-window choice still apply.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if enabled {
                    Text("Visible-text capture is enabled. Turning it off stops future snapshots; existing snapshots need retention or deletion.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.warning)
                }
            }
        }
        .onChange(of: enabled) { _ in ActivityAnalysisRuntime.shared.richContextPreferenceDidChange() }
        .alert("Store visible text from eligible windows?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Enable visible-text context") { enabled = true }
        } message: {
            Text("This is more sensitive than app usage. Selected and visible text can contain personal information. Only local capture is authorized here, not sending it to ChatGPT or a website.")
        }
    }
}
#endif
