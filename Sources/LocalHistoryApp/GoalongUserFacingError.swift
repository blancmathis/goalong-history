import Foundation

/// A short French message for an alert, never a Swift or NSError debug dump.
enum GoalongUserFacingError {
    static let genericMessage = "Une erreur inattendue s’est produite."

    static func message(_ error: Error) -> String {
        if let text = (error as? LocalizedError)?.errorDescription, !text.isEmpty {
            return text
        }
        let ns = error as NSError
        let systemDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain]
        if systemDomains.contains(ns.domain) {
            // macOS localizes these into the system language.
            return error.localizedDescription
        }
        return genericMessage
    }
}
