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
            return "Retry to check the local index, or review your authorized source folders. Original conversations have not been modified."
        case .readFailures(let count):
            return "\(count) source-read issue(s). Readable conversations remain available. Retry, or review the affected source folders and their access."
        case .analysisPending:
            return "Sources are analyzed in bounded batches. Available conversations remain visible; keep this window active to continue, or resume the analysis."
        case .capacityLimited(let count):
            return "\(count) folder(s) exceed the local index limit. The most recent conversations remain available. Review the source scope; retrying alone does not remove this limit."
        }
    }

    var actionTitle: String? {
        switch self {
        case .invalidIndex, .readFailures: return "Retry"
        case .analysisPending: return "Resume analysis"
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
