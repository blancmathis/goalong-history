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
    @AppStorage(GoalongDeveloperPreferences.enabledKey) private var enabled = false

    var body: some View {
        GoalongSettingsGroup(title: "Développement") {
            Toggle("Mode développeur", isOn: $enabled)
                .toggleStyle(.switch)
                .accessibilityIdentifier("settings-developer-mode")
            Text("Désactivé par défaut. Ajoute dans Analyses un bouton pour explorer un exemple complet avec des données fictives.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("L’aperçu est temporaire : il ne modifie pas votre historique, ne lance pas d’analyse IA et ne peut pas être envoyé à Goalong. Désactiver ce mode ferme immédiatement l’aperçu.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
#endif
