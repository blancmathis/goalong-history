import Foundation

/// An error type whose `errorDescription` stays English (logs, journals) and that
/// also offers a finished French sentence for alerts and status lines.
protocol GoalongFrenchDescribable {
    var frenchDescription: String { get }
}

/// A short French message for an alert, never a Swift or NSError debug dump.
enum GoalongUserFacingError {
    static let genericMessage = "Une erreur inattendue s’est produite."

    static let unreadableFileMessage = "Un fichier de Goalong est illisible. Réessayez ; si cela continue, ouvrez l’aide."

    /// History storage errors (events, semantic context, derived files): no English, no private path (T-045 H2-01).
    static let unsafeHistoryPathMessage =
        "Goalong a refusé de modifier un dossier ou un fichier de l’historique qui n’est pas sûr (lien ou élément remplacé). Si cela continue, ouvrez l’aide."
    static let historyChangedMessage = "L’historique a changé pendant l’opération. Réessayez."
    static let historyIOMessage = "Goalong n’a pas pu lire ou écrire son historique. Vérifiez l’espace disque, puis réessayez."
    static let historyDiskFullMessage = "Le disque est plein : Goalong n’a pas pu modifier son historique. Libérez de l’espace, puis réessayez."
    static let historyAccessDeniedMessage =
        "macOS a refusé l’accès à un fichier de l’historique de Goalong. Réessayez ; si cela continue, ouvrez l’aide."
    static let invalidPeriodMessage = "La période choisie est invalide."
    static let tooManySelectedMessage = "Trop d’éléments choisis en une fois. Choisissez une période plus courte."
    static let inexactDeletionMessage =
        "Une ligne illisible empêche une suppression exacte. Aucune suppression n’a été faite pour cette sélection."

    /// Computer History day files (D-150b): no English, no private path.
    static let computerHistoryIncompleteMessage =
        "Goalong a gardé la dernière mémoire valide de l’ordinateur : les données de cette journée étaient incomplètes. Réessayez plus tard."
    static let computerHistoryTooLargeMessage =
        "La mémoire de cette journée dépasse la taille prévue. Les dernières vues valides sont conservées."

    /// Keeps what the old English `strerror` text told the user: a full disk or a refused access.
    static func historyIOMessage(code: Int32) -> String {
        switch code {
        case ENOSPC, EDQUOT: return historyDiskFullMessage
        case EACCES, EPERM, EROFS: return historyAccessDeniedMessage
        default: return historyIOMessage
        }
    }

    static func message(_ error: Error) -> String {
        if let french = (error as? GoalongFrenchDescribable)?.frenchDescription { return french }
        if let text = (error as? LocalizedError)?.errorDescription, !text.isEmpty {
            return text
        }
        if error is DecodingError { return unreadableFileMessage }
        let ns = error as NSError
        // Goalong's own NSErrors carry a finished French sentence.
        if let text = ns.userInfo[NSLocalizedDescriptionKey] as? String, !text.isEmpty { return text }
        let systemDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain]
        if systemDomains.contains(ns.domain) {
            // macOS localizes these into the system language.
            return error.localizedDescription
        }
        return genericMessage
    }
}
