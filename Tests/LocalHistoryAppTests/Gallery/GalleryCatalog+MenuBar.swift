#if os(macOS)
import AppKit
import Ambiance
import Foundation
import SwiftUI
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Menu bar panel (its content, not the real popover), the status button alone with its title, and the toast.
extension GalleryCatalog {
    static var menuBarEntries: [GalleryEntry] {
        func state(_ name: String, themes: [GalleryTheme] = GalleryTheme.standard,
                   _ configure: @escaping @MainActor (MenuBarPanelModel) -> Void = { _ in }) -> GalleryEntry {
            panel("menubar/\(name)", width: MenuBarPanelView.width, themes: themes, clock: .injected,
                  note: "Contenu du panneau ; le vrai popover ajoute son matériau translucide.") { ctx in
                let model = menuBarModel(ctx)
                configure(model)
                return AnyView(MenuBarPanelView(model: model))
            }
        }
        return [
            state("repos", themes: GalleryTheme.withContrast),
            state("seance") { model in
                model.focusRun = .init(phaseTitle: "Concentration", remaining: 1_122, elapsed: 378, progress: 0.25,
                                       cycle: 2, cycles: 4, nextBreak: GalleryClock.at(10, 0), isPaused: false)
                model.ambiancePlaying = true
                model.blockLists[0] = .init(id: "social", title: "Réseaux sociaux",
                                            detail: "Actif jusqu’à la fin de la séance, 3 tentatives", isActive: true, isLocked: false)
            },
            state("pause") { model in
                model.tracking = .paused(since: GalleryClock.at(9, 2)); model.trackingDetail = "Suivi en pause depuis 09:02"
                model.focusAvailable = false; model.focusKind = .free
                model.focusUnavailableReason = "Reprenez le suivi pour lancer une séance."
                model.ambianceEnabled = false; model.blockingEnabled = false
            },
            state("focus-indisponible") { model in
                model.focusAvailable = false
                model.focusUnavailableReason = "Activez Concentration dans Réglages."
                model.focusUnavailableFix = .modules
            },
            state("ambiance-chargement") { model in model.ambianceLoading = true },
            state("ambiance-erreur") { model in
                model.ambianceError = "Le son n’a pas pu démarrer. Réessayez."
            },
            state("permission-manquante") { model in
                model.tracking = .attention("Accessibilité requise")
                model.trackingDetail = "Autorisez Goalong dans Accessibilité pour reprendre le suivi."
                model.attentionFix = .permissions
            },
            state("blocage-verrouille") { model in
                model.blockLists[0] = .init(id: "social", title: "Réseaux sociaux", detail: "Verrouillé jusqu’à 16:34",
                                            isActive: true, isLocked: true)
            },
            GalleryEntry("menubar-bouton/repos", sizes: [.fixed(40, 24)], clock: .none) { _ in
                AnyView(GalleryStatusButton(title: nil))
            },
            GalleryEntry("menubar-bouton/seance", sizes: [.fixed(90, 24)], clock: .none) { _ in
                AnyView(GalleryStatusButton(title: "25:00"))
            },
        ]
    }

    static var systemEntries: [GalleryEntry] {
        [
            panel("temoin/date-et-heure", width: 420, clock: .injected) { ctx in AnyView(GalleryWitness.View(now: ctx.now)) },
            GalleryEntry("toast/exemple", sizes: [.fixed(460, 120)], clock: .none) { _ in
                GoalongToastCenter.shared.setForTesting("Choix d’analyse enregistrés")
                return AnyView(GoalongToastHost())
            },
        ] + supportEntries
    }

    /// « Signaler un problème », in its window's size: the report being prepared (idle looks the same), the report
    /// ready with what was found, a failure. Texts are the app's own (SupportReport.swift, SupportRequest.swift).
    static var supportEntries: [GalleryEntry] {
        let findings = [
            SupportFinding(severity: .warning, code: .recordingWasInterrupted, title: "Enregistrement interrompu 2 fois",
                           detail: "Au moins une coupure venait d’un disque plein. 14 observation(s) n’ont pas pu être "
                               + "enregistrées ; chaque coupure est marquée dans l’historique."),
            SupportFinding(severity: .info, code: .noProblemDetected, title: "Aucun problème détecté automatiquement",
                           detail: "Décrivez ce que vous avez fait et ce que vous attendiez dans votre message."),
        ]
        let phases: [(String, SupportRequestController.Phase)] = [
            ("preparation", .preparing),
            ("rapport-pret", .ready(URL(fileURLWithPath: "/private/tmp/goalong-gallery-rapport.zip"), findings,
                                    byteCount: 182_400, eventCount: 1_284)),
            ("echec", .failed("Le rapport n’a pas pu être préparé (erreur d’écriture). Rien n’a été envoyé.")),
        ]
        return phases.map { name, phase in
            panel("support/\(name)", width: 580, height: 660) { ctx in
                let controller = ctx.keep(SupportRequestController())
                controller.phase = phase
                return AnyView(SupportRequestView(controller: controller))
            }
        }
    }

    /// The panel model with fixed data: an ordinary Friday morning, nothing read from the Mac.
    @MainActor static func menuBarModel(_ ctx: GalleryContext) -> MenuBarPanelModel {
        let support = AppPaths.applicationSupportDirectory
        let model = MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: ctx.defaults),
            concentration: { nil },
            ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: ctx.defaults), supportDirectory: { support }),
            blocking: { nil }, globalPause: { GoalongGlobalPause() }, clock: { GalleryClock.now },
            calendar: GalleryClock.calendar,
            onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {})
        let sources = [("ambre", "Ambre", AmbianceSource.Kind.focus, true), ("canopee", "Canopée", .focus, true),
                       ("meridien", "Méridien", .focus, true), ("sillage", "Sillage", .focus, true),
                       ("filigrane", "Filigrane", .focus, true), ("orbit", "Orbite", .focus, false),
                       ("lagoon", "Lagon", .relax, true), ("rain", "Pluie douce", .texture, true), ("ocean", "Marée", .texture, true)]
            .map { AmbianceSource(id: $0.0, title: $0.1, kind: $0.2, isAvailable: $0.3) }
        model.tracking = .active; model.trackingDetail = "Enregistrement local actif"
        model.workSeconds = 11_520; model.workKnown = true; model.otherSeconds = 2_880
        model.segments = [
            .init(id: 0, start: 0.34, end: 0.40, kind: .work), .init(id: 1, start: 0.405, end: 0.425, kind: .other),
            .init(id: 2, start: 0.43, end: 0.47, kind: .work), .init(id: 3, start: 0.475, end: 0.487, kind: .unclassified),
        ]
        model.nowFraction = 0.40
        model.focusAvailable = true; model.concentrationEnabled = true; model.focusUnavailableReason = nil
        model.focusKind = .pomodoro; model.focusMinutes = 25; model.focusRun = nil
        model.ambianceEnabled = true; model.ambianceSources = sources; model.ambianceCurrent = sources[1]
        model.ambiancePlaying = false; model.ambianceLoading = false; model.ambianceError = nil
        model.blockingEnabled = true
        model.blockLists = [
            .init(id: "social", title: "Réseaux sociaux", detail: "6 sites, 2 apps", isActive: false, isLocked: false),
            .init(id: "news", title: "Actualités", detail: "9 sites", isActive: false, isLocked: false),
        ]
        ctx.keep(model)
        return model
    }
}

/// The status item button alone: the same image, title font and placement as `MenuBarController`.
struct GalleryStatusButton: NSViewRepresentable {
    let title: String?

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = GoalongBrandAssets.menuBarImage
        button.imageScaling = .scaleProportionallyDown
        if let title {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor])
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }
        button.contentTintColor = .labelColor
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}
}
#endif
