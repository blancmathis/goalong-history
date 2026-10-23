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
            dashboard("settings/non-enregistre", section: .settings, pane: .recording, configure: { model, _ in
                model.settingsDraft.captureClicks.toggle()
            }),
            dashboard("settings/permission-manquante", section: .settings, pane: .permissions,
                      environment: { $0.permissions = .galleryMissing }),
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
        let activations: [(String, GoalongCapability, SourceAccessStatus)] = [
            ("historique-accessibilite", .localComputerHistory, .accessibility),
            ("historique-pret", .localComputerHistory, .ready),
            ("temps-ecran-acces-complet", .appleScreenTime, .fullDiskAccess),
            ("temps-ecran-pret", .appleScreenTime, .ready),
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
