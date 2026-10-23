#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// Main window pages (spec C §6: shell, Activité, Mon travail, Historique, Temps d'écran, Conversations IA, Bilan…).
extension GalleryCatalog {
    static var dashboardEntries: [GalleryEntry] {
        [
            // Activité, the home page: a realistic day at the real, minimum and large window sizes, whole page,
            // high contrast; then the week, the month and the sparse states.
            dashboard("activite/jour-realiste", section: .overview, sizes: [.window, .minimum, .large, .full(1240)],
                      themes: GalleryTheme.withContrast, fixture: .realistic),
            dashboard("activite/7-jours", section: .overview, sizes: [.window, .full(1240)], fixture: .realistic, period: 7),
            dashboard("activite/28-jours", section: .overview, sizes: [.window, .full(1240)], fixture: .realistic, period: 28),
            dashboard("activite/journee-vide", section: .overview, sizes: [.window, .full(1240)], fixture: .recordingOn),
            dashboard("activite/traces-isolees", section: .overview, fixture: .sparse),
            dashboard("activite/enregistrement-desactive", section: .overview),
            // Developer mode shows the preview switch; the preview itself is page state, not reachable from here.
            dashboard("activite/mode-developpeur", section: .analytics, fixture: .recordingOn,
                      configure: { _, ctx in ctx.defaults.set(true, forKey: GoalongDeveloperPreferences.enabledKey) }),
            dashboard("activite/permission-manquante", section: .overview,
                      environment: { $0.permissions = .galleryMissing }, fixture: .recordingOn),
            dashboard("fenetre/interactions-indisponibles", section: .overview,
                      environment: { $0.inputTapWorks = false }, fixture: .recordingOn),
            dashboard("fenetre/pause-globale", section: .overview, paused: true),
            dashboard("fenetre/espace-faible", section: .overview, environment: { $0.freeBytes = 900_000_000 },
                      fixture: .recordingOn),
            dashboard("mon-travail/vide", section: .work, sizes: [.window, .full(1240)]),
            dashboard("mon-travail/definition-enregistree", section: .work, configure: { _, _ in
                try JevWorkContextStore.shared.save("Goalong : app macOS et site. Atlas : préparer le lancement.",
                    applications: "Xcode et GitHub pour Goalong. T3 Code pour coder avec les agents.",
                    content: "Documentation Swift, e-mails clients, rédaction de posts Goalong.",
                    procrastination: "jeux, x.com, youtube.com")
            }),
            dashboard("mon-travail/avec-donnees", section: .work, fixture: .realistic),
            dashboard("mon-travail/definition-et-donnees", section: .work, fixture: .realistic, configure: { _, _ in
                try JevWorkContextStore.shared.save("Atlas : préparer le lancement de l’app mobile.",
                    applications: "Xcode, Terminal et GitHub pour Atlas.",
                    content: "Documentation Swift, notes de lancement.",
                    procrastination: "youtube.com, Messages")
            }),
            dashboard("historique/vide", section: .history, sizes: [.window, .full(1240)]),
            dashboard("historique/journee-vide", section: .history, fixture: .recordingOn),
            dashboard("historique/chronologie", section: .history, sizes: [.window, .minimum, .full(1240)],
                      fixture: .realistic),
            dashboard("enregistrement/journal", section: .activity),
            dashboard("enregistrement/journal-rempli", section: .activity, fixture: .realistic),
            dashboard("partage/avec-donnees", section: .share, fixture: .realistic),
            dashboard("temps-ecran/vide", section: .screenTime),
            dashboard("conversations-ia/vide", section: .agentActivity),
            dashboard("bilan/non-connecte", section: .chatGPTRecap),
            dashboard("partage/vide", section: .share),
            dashboard("confidentialite/choix-par-defaut", section: .privacy),
            dashboard("confidentialite/pause-globale", section: .privacy, paused: true),
            dashboard("confidentialite/suivi-actif", section: .privacy, fixture: .realistic),
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
