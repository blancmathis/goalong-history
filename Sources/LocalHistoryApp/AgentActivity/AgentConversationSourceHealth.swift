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
        case .ready: return "Sources d’origine disponibles"
        case .invalidIndex: return "L’index des conversations est illisible"
        case .readFailures: return "Certaines sources de conversations sont illisibles"
        case .analysisPending: return "Analyse des conversations en cours"
        case .capacityLimited: return "Les conversations récentes sont affichées en priorité"
        }
    }

    var message: String {
        switch self {
        case .ready: return "Les messages d’erreur contenus dans une conversation ne signifient pas que la source est inaccessible."
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
