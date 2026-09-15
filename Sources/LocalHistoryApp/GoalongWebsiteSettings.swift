#if os(macOS)
import SwiftUI

@MainActor struct GoalongWebsiteSettings: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var sender = GoalongWebsiteAutoSender.shared
    @State private var showing = false
    @State private var day: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            GoalongWebsiteConnectionCard()
            GoalongSettingsGroup(title: "Fréquence et données") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sender.enabled ? "Chaque jour" : "Envoi ponctuel").font(.system(size: 17, weight: .semibold))
                        Text(sender.enabled ? "La veille, après l’heure choisie" : "Vous vérifiez puis confirmez chaque envoi")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Configurer les envois") { day = nil; showing = true }.buttonStyle(LHPrimaryButtonStyle())
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
                    Text(model.selectedDay.formatted(date: .long, time: .omitted)).font(.system(size: 14))
                    Spacer()
                    Button("Choisir et voir l’aperçu") { day = model.selectedDay; showing = true }.buttonStyle(.bordered).controlSize(.large)
                }
                Text("Tout est préparé localement. Seul le bouton d’envoi transmet les données.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showing) { GoalongWebsiteSharingSheet(initialDay: day) }
    }
}
#endif
