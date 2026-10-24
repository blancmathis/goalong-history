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
