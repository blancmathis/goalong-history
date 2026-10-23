#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// Main window pages (spec C §6: shell, Activité, Mon travail, Historique, Temps d'écran, Conversations IA, Bilan…).
extension GalleryCatalog {
    static var dashboardEntries: [GalleryEntry] {
        [
            // Activité, the home page: real, minimum and large window sizes, whole page, high contrast.
            dashboard("activite/journee-vide", section: .overview, sizes: [.window, .minimum, .large, .full(1240)],
                      themes: GalleryTheme.withContrast),
            dashboard("activite/apercu", section: .analytics),
            dashboard("activite/permission-manquante", section: .overview,
                      environment: { $0.permissions = .galleryMissing }),
            dashboard("fenetre/pause-globale", section: .overview, paused: true),
            dashboard("fenetre/espace-faible", section: .overview, environment: { $0.freeBytes = 900_000_000 }),
            dashboard("mon-travail/vide", section: .work, sizes: [.window, .full(1240)]),
            dashboard("mon-travail/definition-enregistree", section: .work, configure: { _, _ in
                try JevWorkContextStore.shared.save("Goalong : app macOS et site. Atlas : préparer le lancement.",
                    applications: "Xcode et GitHub pour Goalong. T3 Code pour coder avec les agents.",
                    content: "Documentation Swift, e-mails clients, rédaction de posts Goalong.",
                    procrastination: "jeux, x.com, youtube.com")
            }),
            dashboard("historique/vide", section: .history, sizes: [.window, .full(1240)]),
            dashboard("enregistrement/journal", section: .activity),
            dashboard("temps-ecran/vide", section: .screenTime),
            dashboard("conversations-ia/vide", section: .agentActivity),
            dashboard("bilan/non-connecte", section: .chatGPTRecap),
            dashboard("partage/vide", section: .share),
            dashboard("confidentialite/choix-par-defaut", section: .privacy),
            dashboard("confidentialite/pause-globale", section: .privacy, paused: true),
            dashboard("terminal/aide", section: .cli),
            dashboard("surveillance/a-configurer", section: .monitoring),
            dashboard("concentration/page", section: .concentration, sizes: [.window, .full(1240)]),
            dashboard("distractions/page", section: .distractions),
            dashboard("programme/page", section: .blocking),
            dashboard("braise/page-fenetre", section: .braise),
            dashboard("ambiance/page-fenetre", section: .ambiance),
        ]
    }
}
#endif
