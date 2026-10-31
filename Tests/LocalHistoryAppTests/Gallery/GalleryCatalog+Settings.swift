#if os(macOS)
import Foundation
import SwiftUI
import AgentActivity
import LocalHistoryCore
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
        // UI-9 (32, 44): --full too, so the bottom of « Règles d'usage » and « Titres et adresses » can be seen.
        entries += panes.map { name, pane in
            dashboard("settings/\(name)", section: .settings, pane: pane,
                      sizes: name == "applications" || name == "enregistrement" ? [.window, .full(1240)] : [.window])
        }
        entries += [
            // The unsaved-changes banner shows once the member leaves Réglages.
            dashboard("settings/non-enregistre", section: .overview, configure: { model, _ in
                model.settingsDraft.captureClicks.toggle()
            }),
            dashboard("settings/enregistrement-actif", section: .settings, pane: .recording, fixture: .realistic),
            dashboard("settings/stockage-avec-donnees", section: .settings, pane: .storage, fixture: .realistic),
            // UI-10 (59): macOS gave no login state: « État inconnu » on the row and one orange note under it (UI-43).
            dashboard("settings/accueil-etat-inconnu", section: .settings, pane: .home, sizes: [.full(1240)],
                      prepare: { ctx in
                LaunchAtLoginManager.galleryState = .unavailable
                ctx.cleanups.append { LaunchAtLoginManager.galleryState = nil }
            }),
            // UI-9 (58): Avancé with developer mode on, its switch and help shown.
            dashboard("settings/avance-developpeur", section: .settings, pane: .advanced,
                      configure: { _, ctx in ctx.defaults.set(true, forKey: GoalongDeveloperPreferences.enabledKey) }),
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
            // UI-9 (11, 29): the two analysis windows opened from Réglages › Stockage; both inits are inert until a button is pressed.
            panel("settings-sheets/comprendre-mon-travail", width: 760, clock: .injected) { _ in
                AnyView(GoalongProfileStudio(onSend: { _ in }, localOnly: true))
            },
            panel("settings-sheets/analyse-demande-site", width: 700, clock: .injected) { _ in AnyView(GoalongSiteAnalysisSheet()) },
            // UI-12B (29): the main state, connected, a request chosen and reviewed, « Analyser » active (inert model, no Codex).
            panel("settings-sheets/analyse-demande-site-pret", width: 700, clock: .injected) { _ in
                GoalongCapabilityConsentStore.shared.set(.chatGPTAnalysis, enabled: true, surface: .settings)
                let model = GoalongSiteAnalysisModel(consent: { true }, makeSession: { throw CodexAppServerError.executableUnavailable })
                let request = try GoalongSiteAnalysisRequest.parse(JSONSerialization.data(withJSONObject: [
                    "schema": "goalong.analysis-request.v1", "requestId": "11111111-2222-4333-8444-555555555555",
                    "date": "2026-09-07", "timezone": "Europe/Paris", "question": "Explain only these selected observations.",
                    "data": ["totals": [["device": "SELECTED_PHONE", "kind": "phone", "source": "apple-screen-time", "seconds": 3600]]],
                ], options: [.sortedKeys]))
                model.setStateForTesting(request: request, connected: true, accountLabel: "ChatGPT connecté, Plus")
                model.reviewed = true
                return AnyView(GoalongSiteAnalysisSheet(model: model))
            },
            // UI-9 (48): « Projets suivis », with a model on the gallery's own folder (no real project, no agent read).
            panel("settings-sheets/projets-suivis-vide", width: 620, height: 480) { ctx in
                AnyView(GoalongDeveloperProjectsSheet(developer: developerModel(ctx, followed: [], suggested: [])))
            },
            panel("settings-sheets/projets-suivis", width: 620, height: 560) { ctx in
                let site = GoalongDeveloperProject(root: URL(fileURLWithPath: "/Users/demo/Projets/goalong-site"), name: "goalong-site")
                let app = GoalongDeveloperProject(root: URL(fileURLWithPath: "/Users/demo/Projets/goalong-app"), name: "goalong-app")
                let seen = GoalongDeveloperProject(root: URL(fileURLWithPath: "/Users/demo/Projets/carnet"), name: "carnet")
                return AnyView(GoalongDeveloperProjectsSheet(developer: developerModel(ctx, followed: [site, app], suggested: [seen])))
            },
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

    /// A developer model on the gallery's temporary folder, with fixed projects and no consent: it reads nothing real.
    @MainActor private static func developerModel(_ ctx: GalleryContext, followed: [GoalongDeveloperProject],
                                                  suggested: [GoalongDeveloperProject]) -> GoalongDeveloperModel {
        let root = ctx.home.appendingPathComponent("developer", isDirectory: true)
        let model = ctx.keep(GoalongDeveloperModel(root: root, consents: GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("capability-consent.json"))))
        model.setSelectedProjectsForTesting(followed)
        let day = Calendar.current.startOfDay(for: GoalongToday.now)
        model.setValueForTesting(GoalongDeveloperDay(day: day, t3: T3CodeMetadataReader.read(day: day, enabled: false, shouldContinue: { true }),
            agents: GoalongAgentProjectGrouping.group(.init(day: day), t3: nil, enabled: false), git: [],
            files: .init(status: .noData, buckets: []), selectedProjects: followed, suggestions: suggested, developerStatus: .noData))
        return model
    }
}
#endif
