#if os(macOS)
import AppleScreenTime
import SwiftUI

/// A readable source is not necessarily equivalent to the total in Apple Settings.
/// Keep provenance visible beside the numbers, not only in a technical disclosure.
struct GoalongScreenTimeSourcePresentation {
    let assurance: AppleScreenTimeSourceAssurance

    init(provenance: AppleScreenTimeProvenance) { assurance = provenance.sourceAssurance }
    init(assurance: AppleScreenTimeSourceAssurance) { self.assurance = assurance }

    var isPartial: Bool { assurance == .reconstructedAppleUsage }

    var title: String {
        switch assurance {
        case .appleSettingsObservablePresentation: return "Présentation des Réglages Apple"
        case .publicDeviceActivityExport: return "Export Apple autorisé"
        case .privateAppleAggregateStore: return "Base Apple de ce Mac"
        case .reconstructedAppleUsage: return "Données Apple partielles"
        }
    }

    /// The page and the card are already titled « Temps d’écran Apple »: the figure says what it counts.
    var durationTitle: String { isPartial ? "Durée reconstituée" : "Total de la journée" }

    var detail: String {
        switch assurance {
        case .appleSettingsObservablePresentation:
            return "Valeurs observées dans les Réglages Apple pour la date et les appareils sélectionnés."
        case .publicDeviceActivityExport:
            return "Données issues d’un export Apple autorisé, limitées à son périmètre et à sa date de mise à jour."
        case .privateAppleAggregateStore:
            return "Durées lues dans la base Apple de ce Mac. Les appareils inclus et l’heure de mise à jour peuvent différer des Réglages Apple."
        case .reconstructedAppleUsage:
            return "macOS ne rend pas le total complet accessible à Goalong. Les durées ci-dessous sont reconstituées à partir des données Apple lisibles, pas le total officiel des Réglages, et peuvent différer de celui-ci. Les données manquantes restent inconnues, pas à zéro."
        }
    }
}

/// The source off: the same words on the page and in Activité, so the state has one form.
enum GoalongScreenTimeOffCopy {
    static let title = "Temps d’écran Apple désactivé"
    static func message(accessRevoked: Bool) -> String {
        accessRevoked ? "La lecture a été arrêtée car macOS refuse l’accès. Réactivez cette source pour vérifier les autorisations."
            : "Source facultative. L’accès est expliqué et vérifié avant toute lecture."
    }
}

struct GoalongScreenTimeSourceNotice: View {
    let presentation: GoalongScreenTimeSourcePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(presentation.title, systemImage: presentation.isPartial ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(presentation.isPartial ? LHTheme.warning : LHTheme.secondaryText)
            Text(presentation.detail)
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("screen-time-source-assurance")
    }
}
#endif
