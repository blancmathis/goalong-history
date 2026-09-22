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
        case .privateAppleAggregateStore: return "Agrégat Apple"
        case .reconstructedAppleUsage: return "Reconstitution Apple partielle"
        }
    }

    var detail: String {
        switch assurance {
        case .appleSettingsObservablePresentation:
            return "Valeurs observées dans les Réglages Apple pour la date et les appareils sélectionnés."
        case .publicDeviceActivityExport:
            return "Données issues d’un export Apple autorisé, limitées à son périmètre et à sa date de mise à jour."
        case .privateAppleAggregateStore:
            return "Données issues de l’agrégat Apple local. Le périmètre des appareils et l’heure de mise à jour peuvent différer des Réglages Apple."
        case .reconstructedAppleUsage:
            return "L’agrégat Apple complet n’est pas disponible. Ces durées sont reconstituées à partir des sources accessibles et peuvent différer du Temps d’écran des Réglages Apple. Les données manquantes restent inconnues, pas à zéro."
        }
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
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("screen-time-source-assurance")
    }
}
#endif
