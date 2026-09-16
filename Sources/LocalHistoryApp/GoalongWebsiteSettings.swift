#if os(macOS)
import SwiftUI

@MainActor struct GoalongWebsiteSettings: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @State private var presentation: GoalongWebsitePresentation?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            GoalongWebsiteConnectionCard()
            GoalongSettingsGroup(title: "Fréquence et données") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sender.enabled ? "Chaque jour" : sender.savedConfiguration == nil ? "Envoi ponctuel" : "Envoi quotidien en pause").font(.system(size: 17, weight: .semibold))
                        Text(sender.enabled ? "La veille, après l’heure choisie" : "Vous vérifiez puis confirmez chaque envoi")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Configurer les envois") { presentation = .init(day: nil) }.buttonStyle(LHPrimaryButtonStyle())
                }
                if let plan = sender.savedConfiguration {
                    Divider()
                    Text("\(plan.options.deviceIDs.count) appareils · \(plan.options.selectedApplicationIDs?.count ?? 0) applications · \(plan.options.selectedWebsiteDomains?.count ?? 0) sites")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if let hour = plan.hour {
                        Text(String(format: "Horaire : %02d:%02d · %@", hour, plan.minute ?? 0, plan.timeZoneIdentifier ?? ""))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            GoalongSettingsGroup(title: "Envoyer une journée") {
                HStack {
                    Text(GoalongUIFormat.day(model.selectedDay)).font(.system(size: 14))
                    Spacer()
                    Button("Choisir et voir l’aperçu") { presentation = .init(day: model.selectedDay) }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("website-open-selected-day")
                }
                Text("Tout est préparé localement. Seul le bouton d’envoi transmet les données.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $presentation) { request in GoalongWebsiteSharingSheet(initialDay: request.day).id(request.id) }
    }
}
#endif
