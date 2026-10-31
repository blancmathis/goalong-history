#if os(macOS)
import SwiftUI
import LocalHistoryQueryCLI

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
                        Text(sender.enabled ? "Chaque jour" : sender.savedConfiguration == nil ? "Envoi ponctuel" : "Envoi quotidien en pause").font(.system(size: 13, weight: .semibold))
                        Text(sender.enabled ? "La veille, après l’heure choisie" : "Vous vérifiez puis confirmez chaque envoi")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    Spacer()
                    // The page's one lime action is linking the account, in the card above.
                    Button("Configurer les envois") { presentation = .init(day: nil) }.buttonStyle(LHSecondaryButtonStyle())
                }
                if let plan = sender.savedConfiguration {
                    Divider()
                    Text(Self.planSummary(plan.options))
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    if let hour = plan.hour {
                        Text(GoalongWebsiteSettings.scheduleLabel(hour: hour, minute: plan.minute ?? 0, zone: plan.timeZoneIdentifier))
                            .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    }
                }
            }
            GoalongSettingsGroup(title: "Envoyer une journée") {
                HStack {
                    Text(GoalongUIFormat.day(model.selectedDay)).font(.system(size: 14))
                    Spacer()
                    Button("Choisir et voir l’aperçu") { presentation = .init(day: model.selectedDay) }.buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("website-open-selected-day")
                }
                Text("Tout est préparé localement. Seul le bouton d’envoi transmet les données.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
        }
        .sheet(item: $presentation) { request in GoalongWebsiteSharingSheet(initialDay: request.day).id(request.id).goalongControls() }
    }

    /// « 8 h 00 (heure de Paris) » rather than the raw `Europe/Paris` identifier.
    static func scheduleLabel(hour: Int, minute: Int, zone: String?) -> String {
        let time = String(format: "%d h %02d", hour, minute)
        guard let zone, let tz = TimeZone(identifier: zone),
              let city = tz.localizedName(for: .generic, locale: Locale(identifier: "fr_FR")) else { return time }
        return "\(time) (\(city))"
    }

    /// A nil selection means "no filter" (every app or site), never zero.
    static func planSummary(_ options: GoalongSiteExportOptions) -> String {
        func count(_ value: Int, _ singular: String, _ plural: String) -> String {
            "\(value) \(value > 1 ? plural : singular)"
        }
        let devices = options.deviceIDs.isEmpty ? "tous les appareils" : count(options.deviceIDs.count, "appareil", "appareils")
        let apps = !options.includeApplications ? "sans applications"
            : options.selectedApplicationIDs.map { count($0.count, "application", "applications") } ?? "toutes les applications"
        let sites = !options.includeWebsites ? "sans sites"
            : options.selectedWebsiteDomains.map { count($0.count, "site", "sites") } ?? "tous les sites"
        return [devices, apps, sites].joined(separator: ", ")
    }
}
#endif
