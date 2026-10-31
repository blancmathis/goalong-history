#if os(macOS)
import SwiftUI

/// Local UI preference only. It grants no recording, sharing, or system permissions.
enum GoalongDeveloperPreferences {
    static let enabledKey = "goalong.developerMode.enabled"
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey) // An absent key is false, including in debug builds.
    }
}

struct GoalongDeveloperSettings: View {
    static let activeText = "Mode développeur actif : l’aperçu est dans Activité."
    @AppStorage(GoalongDeveloperPreferences.enabledKey) private var enabled = false

    var body: some View {
        GoalongSettingsGroup(title: "Développement") {
            Toggle("Mode développeur", isOn: $enabled)
                .toggleStyle(.goalongSwitch)
                .accessibilityIdentifier("settings-developer-mode")
            // UI-53: one sentence; the switch already shows its state.
            Text("Ajoute dans Activité un aperçu avec des données fictives, sans toucher à votre historique ni rien envoyer.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // UI-15A (58): while it is on, one line confirms it and says where to look.
            if enabled {
                Label {
                    Text(Self.activeText).foregroundStyle(LHTheme.text)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(LHTheme.success)
                }
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("settings-developer-mode-active")
            }
        }
    }
}
#endif
