#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// « Signaler un problème »: each phase of the support window (spec C §6), drawn by the app's own view from a controller of
/// its own, so nothing prepares a report, opens a window or reads the real journal.
extension GalleryCatalog {
    private static func finding(_ level: SupportLevel, _ code: SupportFinding.Code, _ title: String, _ detail: String) -> SupportFinding {
        SupportFinding(severity: level, code: code, title: title, detail: detail)
    }

    private static func supportPanel(_ id: String, note: String, phase: SupportRequestController.Phase,
                                     feedback: String? = nil, kind: SupportRequestController.FeedbackKind = .success) -> GalleryEntry {
        panel(id, width: 580, height: 660, note: note) { ctx in
            let controller = ctx.keep(SupportRequestController())
            controller.phase = phase
            controller.feedback = feedback
            controller.feedbackKind = kind
            return AnyView(SupportRequestView(controller: controller))
        }
    }

    private static let supportFile = URL(fileURLWithPath: "/private/tmp/goalong-gallery-rapport.zip")

    /// The journal finding follows the journal: a state that says the journal is on must not list it as off.
    private static func supportReport(journalOff: Bool = true) -> SupportRequestController.Phase {
        .ready(supportFile, [
            finding(.error, .permissionMissing, "Autorisation d’accessibilité manquante",
                    "Goalong ne peut plus enregistrer l’activité tant que macOS n’a pas rétabli cette autorisation."),
            finding(.warning, .lowDiskSpace, "Espace disque faible", "Il reste moins de 2 Go sur le disque de l’app."),
        ] + (journalOff ? [finding(.info, .diagnosticsDisabled, "Journal technique désactivé", "Aucun nouvel événement n’est conservé.")] : []),
              byteCount: 184_320, eventCount: 212)
    }

    /// The states `support/preparation`, `rapport-pret` and `echec` (MenuBar file) leave out: every severity, a clean
    /// report, and the feedback line under the cards.
    static var supportRequestEntries: [GalleryEntry] {
        [
            supportPanel("support/constats-multiples", note: "trois constats : erreur, avertissement, information", phase: supportReport()),
            supportPanel("support/aucun-probleme", note: "rapport prêt, aucun problème détecté",
                         phase: .ready(supportFile, [finding(.info, .noProblemDetected, "Aucun problème détecté automatiquement",
                                                             "Décrivez ce que vous avez fait et ce que vous attendiez dans votre message.")],
                                       byteCount: 52_480, eventCount: 38)),
            supportPanel("support/retour-repere", note: "retour d’information : repère ajouté", phase: supportReport(journalOff: false),
                         feedback: "Repère ajouté à 09:41. Reproduisez le problème puis cliquez sur « Actualiser le rapport »."),
            supportPanel("support/retour-messagerie-absente", note: "retour d’information : aucune app de messagerie", phase: supportReport(journalOff: false),
                         feedback: "Aucune app de messagerie n’est configurée. Utilisez « Partager » ou « Enregistrer une copie ».",
                         kind: .problem),
            supportPanel("support/retour-journal-desactive", note: "retour d’information : journal technique désactivé", phase: supportReport(),
                         feedback: "Le journal technique est désactivé : activez « Conserver les journaux techniques sur ce Mac » dans Réglages › Avancé › Aide et diagnostic pour ajouter un repère.",
                         kind: .problem),
        ]
    }
}
#endif
