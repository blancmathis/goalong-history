#if os(macOS)
import Foundation

enum BlockingListAdditionFailure: Error, LocalizedError, Equatable {
    case notFound, invalidTarget, notBlockList, storageFailed
    case refused(String)
    var errorDescription: String? {
        switch self {
        case .notFound: return "Cette liste n’existe plus."
        case .invalidTarget: return "Cette distraction ne peut pas être ajoutée."
        case .notBlockList: return "Choisissez une liste de distractions à bloquer, pas une liste d’autorisations."
        case .storageFailed: return "Goalong ne peut pas enregistrer la liste de blocage."
        case .refused(let reason): return reason
        }
    }
}
#endif
