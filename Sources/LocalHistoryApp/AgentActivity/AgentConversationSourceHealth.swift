#if os(macOS)
import AgentActivity

/// Errors *inside* a readable transcript are not source failures. Index/read
/// failures, bounded analysis work and inventory limits have distinct remedies.
enum AgentConversationSourceHealth: Equatable {
    case ready
    case invalidIndex
    case readFailures(Int)
    case analysisPending
    case capacityLimited(Int)

    init(indexIsValid: Bool, scan: AgentScanResult) {
        if !indexIsValid { self = .invalidIndex }
        else if !scan.failures.isEmpty { self = .readFailures(scan.failures.count) }
        else if scan.analysisIncomplete { self = .analysisPending }
        else if scan.capacityLimitedFolderCount > 0 { self = .capacityLimited(scan.capacityLimitedFolderCount) }
        else { self = .ready }
    }

    var hasReadFailure: Bool {
        switch self {
        case .invalidIndex, .readFailures: return true
        case .ready, .analysisPending, .capacityLimited: return false
        }
    }

    var title: String {
        switch self {
        case .ready: return "Original sources available"
        case .invalidIndex: return "The conversation index could not be read"
        case .readFailures: return "Some conversation sources could not be read"
        case .analysisPending: return "Conversation analysis is not finished"
        case .capacityLimited: return "Recent conversations are shown first"
        }
    }

    var message: String {
        switch self {
        case .ready: return "Error messages inside conversations do not indicate a source-access failure."
        case .invalidIndex:
            return "Réessayez pour vérifier l’index local, ou vérifiez vos dossiers autorisés. Les conversations d’origine n’ont pas été modifiées."
        case .readFailures(let count):
            return "\(count) problème(s) de lecture. Les conversations lisibles restent disponibles. Réessayez, ou vérifiez les dossiers concernés et leurs accès."
        case .analysisPending:
            return "Les sources sont analysées par lots. Les conversations disponibles restent visibles ; gardez cette fenêtre active pour continuer, ou relancez l’analyse."
        case .capacityLimited(let count):
            return "\(count) dossier(s) dépassent la limite de l’index local. Les conversations récentes restent disponibles. Réduisez le périmètre : réessayer ne lève pas cette limite."
        }
    }

    var actionTitle: String? {
        switch self {
        case .invalidIndex, .readFailures: return "Réessayer"
        case .analysisPending: return "Reprendre l’analyse"
        case .ready, .capacityLimited: return nil
        }
    }

    var symbol: String {
        switch self {
        case .invalidIndex, .readFailures: return "exclamationmark.circle"
        case .analysisPending: return "clock.arrow.circlepath"
        case .ready, .capacityLimited: return "info.circle"
        }
    }
}
#endif
