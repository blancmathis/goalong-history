#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// Réglages (every pane, in the real window), their sheets, the source activation sheets and the onboarding.
extension GalleryCatalog {
    static var settingsEntries: [GalleryEntry] {
        let panes: [(String, SettingsPane)] = [
            ("enregistrement", .recording), ("applications", .applications), ("connexions", .connections),
            ("site", .website), ("chatgpt", .chatGPT), ("jev", .jev), ("modules", .modules), ("permissions", .permissions),
            ("stockage", .storage), ("avance", .advanced), ("outils", .tools),
        ]
        var entries: [GalleryEntry] = [
            dashboard("settings/accueil", section: .settings, pane: .home, sizes: [.window, .full(1240)],
                      themes: GalleryTheme.withContrast),
        ]
        entries += panes.map { name, pane in dashboard("settings/\(name)", section: .settings, pane: pane) }
        entries += [
            // The unsaved-changes banner shows once the member leaves Réglages.
            dashboard("settings/non-enregistre", section: .overview, configure: { model, _ in
                model.settingsDraft.captureClicks.toggle()
            }),
            dashboard("settings/enregistrement-actif", section: .settings, pane: .recording, fixture: .realistic),
            dashboard("settings/stockage-avec-donnees", section: .settings, pane: .storage, fixture: .realistic),
            // Recording on, so the history row asks for the missing access instead of « Fonction désactivée ».
            dashboard("settings/permission-manquante", section: .settings, pane: .permissions,
                      environment: { $0.permissions = .galleryMissing }, fixture: .recordingOn),
            // R7-C-01: the four switch states side by side; a disabled one must look disabled, on or off.
            panel("settings-sheets/interrupteurs-etats", width: 360) { _ in
                AnyView(VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<4) { index in
                        let on = index % 2 == 0, enabled = index < 2
                        Toggle(on ? (enabled ? "Activé" : "Activé, indisponible") : (enabled ? "Désactivé" : "Désactivé, indisponible"),
                               isOn: .constant(on)).disabled(!enabled)
                    }
                }.toggleStyle(.goalongSwitch).padding(24))
            },
            panel("settings-sheets/connexion-jev", width: 560) { _ in AnyView(JevConnectionSheet()) },
            panel("settings-sheets/conservation", width: 700, height: 670) { _ in AnyView(HistoryRetentionSettingsSheet()) },
            panel("settings-sheets/partage-site", width: 740, clock: .injected) { _ in AnyView(GoalongWebsiteSharingSheet()) },
        ]
        for (tab, name) in ["applications", "sites", "categories"].enumerated() {
            entries.append(panel("settings-sheets/analyse-\(name)", width: 940, clock: .injected) { ctx in
                let model = try GalleryFixtures.dashboardModel(ctx, .init(section: .settings, settingsPane: .chatGPT))
                return AnyView(GoalongAnalysisSelectionSheet(model: model, selection: GoalongAnalysisSelection.load(),
                                                             initialTab: tab) { _ in })
            })
        }
        // A freshly added rule has no search text yet: the test area must not pretend it replaced something.
        entries.append(panel("settings-sheets/analyse-sites-regle-vide", width: 940, clock: .injected) { ctx in
            let model = try GalleryFixtures.dashboardModel(ctx, .init(section: .settings, settingsPane: .chatGPT))
            var selection = GoalongAnalysisSelection.load()
            selection.replacements = [GoalongTextReplacement()]
            return AnyView(GoalongAnalysisSelectionSheet(model: model, selection: selection, initialTab: 1) { _ in })
        })
        let activations: [(String, GoalongCapability, SourceAccessStatus)] = [
            ("historique-accessibilite", .localComputerHistory, .accessibility),
            ("historique-pret", .localComputerHistory, .ready),
            ("temps-ecran-acces-complet", .appleScreenTime, .fullDiskAccess),
            ("temps-ecran-pret", .appleScreenTime, .ready),
            ("historique-surveillance-entree", .localComputerHistory, .inputMonitoring),
            ("temps-ecran-a-configurer", .appleScreenTime, .screenTimeSetup),
            // The app's own messages (SourceActivation.swift).
            ("temps-ecran-indisponible", .appleScreenTime, .unavailable(
                "La source Apple n’a pas pu être ouverte. Vérifiez Temps d’écran dans Réglages Système, puis réessayez.")),
            ("historique-reparation-en-cours", .localComputerHistory,
             .unavailable("Une réparation d’autorisation est en cours. Aucun nouvel accès n’est confirmé.")),
        ]
        entries += activations.map { name, capability, status in
            panel("permissions/\(name)", width: 620, height: 690) { _ in
                AnyView(SourceActivationSheet(capability: capability, surface: .settings, prepare: {},
                                              check: { _, done in done(status) }, initialStatus: status))
            }
        }
        return entries
    }

    static var onboardingEntries: [GalleryEntry] {
        SetupStep.allCases.enumerated().map { index, step in
            var model: DashboardViewModel?
            return GalleryEntry("onboarding/etape-\(index)", sizes: [.fixed(1080, 680)], themes: GalleryTheme.standard,
                                clock: .injected,
                                ready: { ctx in model.map { GalleryFixtures.dashboardReady($0)(ctx) } ?? false }) { ctx in
                ctx.defaults.set(step.rawValue, forKey: "goalongOnboardingStep")
                if step != .privacy { ctx.defaults.set(true, forKey: "goalongOnboardingPrivacyReviewedV1") }
                let built = try GalleryFixtures.dashboardModel(ctx, .init(showWelcome: true))
                model = built
                return AnyView(LocalHistoryOnboardingView(model: built))
            }
        }
    }
}
#endif
