#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// Main window pages (spec C §6: shell, Activité, Mon travail, Historique, Temps d'écran, Conversations IA, Bilan…).
extension GalleryCatalog {
    /// `homeDirectoryForCurrentUser` answers `/Users/exemple` until the entry ends. Set last, after the fixture is
    /// written in the shard HOME: only text read from the home (a command to copy) changes.
    static func showFixedHome(_ ctx: GalleryContext) {
        let key = "CFFIXED_USER_HOME"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "/Users/exemple", 1)
        ctx.cleanups.append { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
    }

    /// The day's contexts by task with the member's verdicts (Mon travail › Vérifier et corriger, and the sheet
    /// Activité opens with « Corriger »), loaded from the classified fixture.
    static var workReviewEntry: GalleryEntry {
        var review: GoalongWorkReviewModel?
        return GalleryEntry("mon-travail/correction-du-classement", sizes: [.fitWidth(720)], clock: .injected,
                            ready: { _ in review.map { $0.loadedDay != nil && !$0.loading } ?? false }) { ctx in
            try GalleryFixtureHome.install(.classified)
            let model = ctx.keep(GoalongWorkReviewModel())
            review = model
            return AnyView(GoalongWorkReviewCard(review: model, day: GalleryClock.today, focusTask: "Atlas",
                                                 loadsOnAppear: true).padding(24))
        }
    }

    static var dashboardEntries: [GalleryEntry] {
        [workReviewEntry] + [
            // Activité, the home page: a realistic, classified day at the real, minimum and large window sizes, whole
            // page, high contrast; then the week, the month, the same day before any verdict and the sparse states.
            dashboard("activite/jour-realiste", section: .overview, sizes: [.window, .minimum, .large, .full(1240)],
                      themes: GalleryTheme.withContrast, fixture: .classified),
            dashboard("activite/7-jours", section: .overview, sizes: [.window, .full(1240)], fixture: .classified, period: 7),
            dashboard("activite/28-jours", section: .overview, sizes: [.window, .full(1240)], fixture: .classified, period: 28),
            dashboard("activite/non-classe", section: .overview, sizes: [.window, .full(1240)], fixture: .realistic),
            dashboard("activite/journee-vide", section: .overview, sizes: [.window, .full(1240)], fixture: .recordingOn),
            dashboard("activite/traces-isolees", section: .overview, sizes: [.window, .full(1240)], fixture: .sparse),
            dashboard("activite/enregistrement-desactive", section: .overview),
            // Developer mode shows the preview switch; the preview itself is page state, not reachable from here.
            dashboard("activite/mode-developpeur", section: .analytics, sizes: [.window, .full(1240)], fixture: .recordingOn,
                      configure: { _, ctx in ctx.defaults.set(true, forKey: GoalongDeveloperPreferences.enabledKey) }),
            dashboard("activite/permission-manquante", section: .overview,
                      environment: { $0.permissions = .galleryMissing }, fixture: .recordingOn),
            dashboard("fenetre/interactions-indisponibles", section: .overview,
                      environment: { $0.inputTapWorks = false }, fixture: .recordingOn,
                      note: "bannière « Les clics et la frappe ne parviennent pas à Goalong… », et statut "
                          + "« Pas d’interactions » dans la barre latérale"),
            dashboard("fenetre/pause-globale", section: .overview, sizes: [.window, .full(1240)], paused: true),
            dashboard("fenetre/stockage-plein", section: .overview, environment: { $0.storageFailure = .diskFull },
                      fixture: .recordingOn),
            dashboard("fenetre/stockage-refuse", section: .history, environment: { $0.storageFailure = .permissionDenied },
                      fixture: .recordingOn),
            dashboard("fenetre/espace-faible", section: .overview, sizes: [.window, .full(1240)], environment: { $0.freeBytes = 900_000_000 },
                      fixture: .recordingOn),
            dashboard("mon-travail/vide", section: .work, sizes: [.window, .full(1240)]),
            dashboard("mon-travail/definition-enregistree", section: .work, configure: { _, _ in
                try JevWorkContextStore.shared.save("Goalong : app macOS et site. Atlas : préparer le lancement.",
                    applications: "Xcode et GitHub pour Goalong. T3 Code pour coder avec les agents.",
                    content: "Documentation Swift, e-mails clients, rédaction de posts Goalong.",
                    procrastination: "jeux, x.com, youtube.com")
            }),
            // Definition and the member's own verdicts (agent not allowed: allowing it would start a ChatGPT
            // account check, a process). The review is open on the gallery day, Atlas unfolded: --full shows the
            // contexts by task with their verdicts (C2-couverture-03).
            // --full only: at window size the review sits below the fold and the image matches
            // definition-et-donnees (C3-couverture-04).
            dashboard("mon-travail/classement-avec-donnees", section: .work, sizes: [.full(1240)],
                      fixture: .classified, reached: { (GoalongWorkReviewModel.lastLoadedRowCount ?? 0) > 0 },
                      configure: { _, _ in GoalongWorkPage.galleryReviewFocusTask = "Atlas" }),
            dashboard("mon-travail/definition-et-donnees", section: .work, fixture: .realistic, configure: { _, _ in
                try JevWorkContextStore.shared.save("Atlas : préparer le lancement de l’app mobile.",
                    applications: "Xcode, Terminal et GitHub pour Atlas.",
                    content: "Documentation Swift, notes de lancement.",
                    procrastination: "youtube.com, Messages")
            }),
            dashboard("historique/vide", section: .history, sizes: [.window, .full(1240)]),
            dashboard("historique/journee-vide", section: .history, sizes: [.window, .full(1240)], fixture: .recordingOn),
            // R4e-suite B: the gallery clock is 23 Oct, so the entry above shows today (« pas encore »); this one shows the day before.
            dashboard("historique/journee-passee-vide", section: .history, fixture: .recordingOn,
                      configure: { model, _ in
                          model.selectDay(GalleryClock.calendar.date(byAdding: .day, value: -1, to: GalleryClock.today) ?? GalleryClock.today)
                      }),
            dashboard("historique/chronologie", section: .history, sizes: [.window, .minimum, .full(1240)],
                      fixture: .realistic),
            // R-61 (T-043 R2c, décision 1): « enregistrement/journal » drew the same PNG as historique/vide (section
            // .activity opens the same page). 6bc0d8ad removed it for that reason, e2fef957 put it back only for the
            // DashboardSection coverage guard; the entry is gone again and the guard names .activity as covered by
            // historique/ (scripts/gallery.py NOT_COVERED says so).
            // R8-2: the large window shows several rows; the default one shows the fade.
            dashboard("partage/avec-donnees", section: .share, sizes: [.window, .large, .full(1240)], fixture: .realistic),
            dashboard("temps-ecran/vide", section: .screenTime, sizes: [.window, .full(1240)]),
            dashboard("conversations-ia/vide", section: .agentActivity, sizes: [.window, .full(1240)]),
            dashboard("partage/vide", section: .share, sizes: [.window, .full(1240)]),
            dashboard("confidentialite/choix-par-defaut", section: .privacy, sizes: [.window, .full(1240)]),
            dashboard("confidentialite/pause-globale", section: .privacy, sizes: [.window, .full(1240)], paused: true),
            dashboard("confidentialite/suivi-actif", section: .privacy, sizes: [.window, .full(1240)], fixture: .realistic),
            // The page shows the install command with the home folder: a fixed displayed home, not the shard's
            // `/tmp/goalong-gallery-<run>/shard-N-…`, which changes every run.
            // UI-9 (36): the installed app's executable, not the xctest runner's.
            dashboard("terminal/aide", section: .cli, sizes: [.window, .full(1240)], configure: { _, ctx in
                showFixedHome(ctx)
                GoalongCLIInstallation.galleryExecutableURL = URL(fileURLWithPath: "/Applications/Goalong History.app/Contents/MacOS/Goalong History")
                ctx.cleanups.append { GoalongCLIInstallation.galleryExecutableURL = nil }
            }),
            // Without a key but with history on and a work definition: not the same image as Réglages › Jev, which
            // the section opens (C2-couverture-01).
            dashboard("surveillance/a-configurer", section: .monitoring, fixture: .recordingOn, configure: { _, _ in
                try JevWorkContextStore.shared.save("Atlas : préparer le lancement de l’app mobile.",
                    applications: "Xcode, Terminal et GitHub pour Atlas.", content: "Documentation Swift.",
                    procrastination: "youtube.com, Messages")
            }),
            dashboard("concentration/page", section: .concentration, sizes: [.window, .full(1240)]),
            dashboard("distractions/page", section: .distractions),
            dashboard("programme/page", section: .blocking),
            // R8-5: the module is on, so its sidebar entry exists and is the selected one.
            dashboard("braise/page-fenetre", section: .braise, prepare: { ctx in
                let wasOn = GoalongModuleStore.shared.isEnabled(.braise)
                GoalongModuleStore.shared.setEnabled(.braise, true)
                ctx.cleanups.append { GoalongModuleStore.shared.setEnabled(.braise, wasOn) }
            }),
            dashboard("ambiance/page-fenetre", section: .ambiance),
        ]
    }
}
#endif
