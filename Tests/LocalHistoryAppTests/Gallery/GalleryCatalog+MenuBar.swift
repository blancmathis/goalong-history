#if os(macOS)
import AppKit
import Combine
import Ambiance
import Foundation
import SwiftUI
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Menu bar panel (its content, not the real popover), the status button alone with its title, and the toast.
extension GalleryCatalog {
    static var menuBarEntries: [GalleryEntry] {
        func state(_ name: String, themes: [GalleryTheme] = GalleryTheme.standard,
                   redScreen: RedScreenState? = nil,
                   _ configure: @escaping @MainActor (MenuBarPanelModel) -> Void = { _ in }) -> GalleryEntry {
            panel("menubar/\(name)", width: MenuBarPanelView.width, themes: themes, clock: .injected,
                  note: "Contenu du panneau ; le vrai popover ajoute son matériau translucide.") { ctx in
                let model = menuBarModel(ctx, redScreen: redScreen)
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
                model.consentOff = true; model.tracking = .attention("Enregistrement désactivé"); model.trackingDetail = "Activez l’enregistrement dans Réglages"
                model.focusUnavailableReason = "Activez l’enregistrement dans Réglages."
                model.focusUnavailableFix = .recording
            },
            state("ambiance-chargement") { model in model.ambianceLoading = true },
            state("ambiance-erreur") { model in
                model.ambianceError = "Le son n’a pas pu démarrer. Réessayez."
            },
            state("permission-manquante") { model in
                // The app's own words for this state (CaptureHealthPresentation.swift).
                model.tracking = .attention(CaptureHealthState.permissionRequired.frenchTitle)
                model.trackingDetail = CaptureHealthState.permissionRequired.frenchDetail
                model.attentionFix = .permissions
            },
            state("blocage-verrouille") { model in
                model.blockLists[0] = .init(id: "social", title: "Réseaux sociaux", detail: "Verrouillé jusqu’à 16:34",
                                            isActive: true, isLocked: true)
            },
            state("ecran-rouge-eteint", themes: GalleryTheme.withContrast, redScreen: RedScreenState()),
            state("ecran-rouge-allume", redScreen: RedScreenState(on: true, intensity: 0.7, followsSchedule: true)),
            GalleryEntry("menubar-menu/ecran-rouge", sizes: [.fixed(300, 220)], clock: .none,
                         note: "Lignes du menu clic droit ; le vrai menu ajoute son fond système.") { ctx in
                let control = GalleryRedScreen(RedScreenState(on: true, intensity: 0.7))
                let menu = RedScreenMenu(control: control, onOpenSettings: {})
                ctx.keep(control); ctx.keep(menu)
                return AnyView(GalleryMenuItems(items: menu.items))
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
                GoalongToastCenter.shared.setForTesting("Données à analyser enregistrées")
                return AnyView(GoalongToastHost())
            },
            panel("bandeau/icone-masquee", width: 900) { _ in AnyView(MenuBarVisibilityNotice(state: .parkedBySystem)) },
            panel("bandeau/icone-encoche", width: 900) { _ in AnyView(MenuBarVisibilityNotice(state: .underNotch)) },
        ] + supportEntries
    }

    /// « Signaler un problème », in its window's size: the report being prepared (idle looks the same), the report
    /// ready with what was found, a failure. Texts are the app's own (SupportReport.swift, SupportRequest.swift).
    static var supportEntries: [GalleryEntry] {
        let findings = [
            SupportFinding(severity: .warning, code: .recordingWasInterrupted, title: "Enregistrement interrompu 2 fois",
                           detail: "Au moins une interruption venait d’un disque plein. 14 événements n’ont pas pu être "
                               + "enregistrés ; chaque interruption est marquée dans l’historique."),
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
    @MainActor static func menuBarModel(_ ctx: GalleryContext, redScreen: RedScreenState? = nil) -> MenuBarPanelModel {
        let control = redScreen.map(GalleryRedScreen.init)
        if let control { ctx.keep(control) }
        let support = AppPaths.applicationSupportDirectory
        let model = MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: ctx.defaults),
            concentration: { nil },
            ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: ctx.defaults), supportDirectory: { support }),
            blocking: { nil }, globalPause: { GoalongGlobalPause() }, clock: { GalleryClock.now },
            calendar: GalleryClock.calendar,
            onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {},
            redScreen: control)
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

/// A fixed red screen for the gallery: no controller, no gamma call.
@MainActor final class GalleryRedScreen: RedScreenControlling {
    private let subject: CurrentValueSubject<RedScreenState, Never>
    init(_ state: RedScreenState) { subject = CurrentValueSubject(state) }
    var redScreen: RedScreenState { subject.value }
    var redScreenChanges: AnyPublisher<RedScreenState, Never> { subject.eraseToAnyPublisher() }
    func setRedScreen(_ on: Bool) { subject.value.on = on }
    func setRedScreenIntensity(_ value: Double) { subject.value.intensity = value }
    func followRedScreenSchedule() { subject.value.followsSchedule = true }
    func restoreColors() { subject.value.on = false }
}

/// Menu items drawn as plain rows (an NSMenu cannot be drawn offscreen); view items show their real view.
struct GalleryMenuItems: NSViewRepresentable {
    let items: [NSMenuItem]

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        for item in items {
            if item.isSeparatorItem { let line = NSBox(); line.boxType = .separator; stack.addArrangedSubview(line); continue }
            if let view = item.view { item.view = nil; stack.addArrangedSubview(view); continue }
            let mark = item.state == .on ? "✓ " : "   "
            var key = ""
            if !item.keyEquivalent.isEmpty {
                let mask = item.keyEquivalentModifierMask
                key = (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) ? "⇧" : "")
                    + (mask.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
            }
            let row = NSTextField(labelWithString: mark + item.title + (item.submenu == nil ? "" : "  ›") + (key.isEmpty ? "" : "    " + key))
            row.font = .menuFont(ofSize: 0)
            row.textColor = item.isEnabled ? .labelColor : .disabledControlTextColor
            stack.addArrangedSubview(row)
        }
        return stack
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {}
}
#endif
