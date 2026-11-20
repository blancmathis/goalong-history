import Foundation
import os

/// `make perso`: the owner's daily build of a worktree, signed like a release, in /Applications.
/// `scripts/build_app_core.sh` writes its exact source commit into Info.plist; releases have no key.
struct PersoBuildInfo: Equatable, Sendable {
    static let commitKey = "GoalongPersoSourceCommit"
    static let branchKey = "GoalongPersoSourceBranch"
    static let builtAtKey = "GoalongPersoBuiltAt"

    let commit: String
    let branch: String?
    let builtAt: String?

    /// Nil without a full 40-hex lowercase commit (every release, Goalong Dev, a damaged plist).
    init?(info: [String: Any]?) {
        guard let commit = info?[Self.commitKey] as? String, PersoReleaseGate.isFullCommit(commit) else { return nil }
        self.commit = commit
        func text(_ key: String) -> String? {
            guard let value = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value != "unknown" else { return nil }
            return value
        }
        branch = text(Self.branchKey)
        builtAt = text(Self.builtAtKey)
    }

    static let current = PersoBuildInfo(info: Bundle.main.infoDictionary)

    var shortCommit: String { String(commit.prefix(8)) }

    /// "Build perso · feat/x · 1a2b3c4d"
    var label: String { ["Build perso", branch, shortCommit].compactMap { $0 }.joined(separator: " · ") }
}

/// Does a published release contain the perso commit? Each release tag points at the exact main commit
/// it was built from (continuous-release.yml, promote_prepared_release.py), so GitHub's compare API answers:
/// the perso commit is an ancestor of the tag, or it belongs to a pull request merged (squash or merge
/// commit) into main whose merge commit is. Anything else, or any doubt, is "not now": a perso build
/// is never replaced by a release without its work, and Sparkle never downgrades it.
enum PersoReleaseVerdict: Equatable, Sendable {
    case contains
    case lacks
    case unknown(String)
}

typealias PersoFetch = @Sendable (URL) async -> (status: Int, body: Data)?

enum PersoReleaseGate {
    static let downloadRoot = "https://github.com/blancmathis/goalong-history/releases/download/"
    static let apiRepository = "https://api.github.com/repos/blancmathis/goalong-history/"
    /// Pull requests looked at for one commit (a commit is in one PR in practice).
    static let maximumPullRequests = 3

    static func isFullCommit(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func isTag(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.first != "." && value.first != "-"
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The immutable release tag in `…/releases/download/<tag>/<asset>`; nil for any other URL.
    static func releaseTag(enclosure: URL?) -> String? {
        guard let absolute = enclosure?.absoluteString, absolute.hasPrefix(downloadRoot) else { return nil }
        let parts = absolute.dropFirst(downloadRoot.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, isTag(String(parts[0])), parts[0] != "latest-main" else { return nil }
        return String(parts[0])
    }

    /// `compare/<base>...<tag>`: "ahead" or "identical" means base is in the tag's history.
    static func compareURL(base: String, tag: String) -> URL? {
        guard isFullCommit(base), isTag(tag) else { return nil }
        return URL(string: apiRepository + "compare/\(base)...\(tag)?per_page=1")
    }

    static func pullsURL(commit: String) -> URL? {
        guard isFullCommit(commit) else { return nil }
        return URL(string: apiRepository + "commits/\(commit)/pulls?per_page=\(maximumPullRequests)")
    }

    static func compareVerdict(status: Int, body: Data) -> PersoReleaseVerdict {
        switch status {
        case 200:
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let state = object["status"] as? String else { return .unknown("réponse GitHub illisible") }
            switch state {
            case "ahead", "identical": return .contains
            case "behind", "diverged": return .lacks
            default: return .unknown("réponse GitHub illisible")
            }
        case 404, 422: return .unknown("commit inconnu de GitHub (pas encore poussé ?)")
        case 403, 429: return .unknown("limite de l’API GitHub atteinte")
        default: return .unknown("GitHub a répondu \(status)")
        }
    }

    /// Merge commits of the pull requests merged into main that contain the commit; nil when unreadable.
    static func mergedMainCommits(status: Int, body: Data) -> [String]? {
        guard status == 200, let list = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return nil }
        return list.prefix(maximumPullRequests).compactMap { pull in
            guard pull["merged_at"] is String, (pull["base"] as? [String: Any])?["ref"] as? String == "main",
                  let sha = pull["merge_commit_sha"] as? String, isFullCommit(sha) else { return nil }
            return sha
        }
    }

    /// The whole decision for one release tag; every doubt is `.unknown`, retried at a later check.
    static func verdict(commit: String, tag: String, fetch: PersoFetch) async -> PersoReleaseVerdict {
        guard let direct = compareURL(base: commit, tag: tag), let pulls = pullsURL(commit: commit) else {
            return .unknown("commit ou version invalide")
        }
        guard let response = await fetch(direct) else { return .unknown("GitHub injoignable") }
        let first = compareVerdict(status: response.status, body: response.body)
        if first == .contains { return .contains }
        // Not an ancestor: a squash merge still contains it through its pull request.
        guard let listed = await fetch(pulls) else { return .unknown("GitHub injoignable") }
        guard let merges = mergedMainCommits(status: listed.status, body: listed.body) else {
            // Without the pull request list, "lacks" is not proven.
            guard first == .lacks else { return first }
            return .unknown(listed.status == 200 ? "réponse GitHub illisible" : "GitHub a répondu \(listed.status)")
        }
        var doubt: PersoReleaseVerdict?
        for merge in merges {
            guard let url = compareURL(base: merge, tag: tag) else { continue }
            guard let answer = await fetch(url) else { return .unknown("GitHub injoignable") }
            switch compareVerdict(status: answer.status, body: answer.body) {
            case .contains: return .contains
            case .lacks: continue
            case .unknown(let reason): doubt = .unknown(reason)
            }
        }
        if let doubt { return doubt }
        // Nothing merged contains it. A commit GitHub does not know stays unknown, never "lacks".
        return first
    }
}

/// Remembers final answers per release tag (a tag never moves) and starts at most one check per tag.
@MainActor
final class PersoReleaseChecker {
    enum Decision: Equatable {
        case install
        case skip(String)
    }

    let build: PersoBuildInfo
    private let fetch: PersoFetch
    private let now: () -> Date
    private var finalVerdicts: [String: PersoReleaseVerdict] = [:]
    private var lastReasons: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var lastAttempts: [String: Date] = [:]
    /// Unknown answers are retried, but not more often than this (GitHub allows 60 anonymous calls an hour).
    static let retryInterval: TimeInterval = 600
    /// Called on the main actor once a check ends with a new answer.
    var onVerdict: ((String, PersoReleaseVerdict) -> Void)?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                                       category: "perso-updates")

    init(build: PersoBuildInfo, fetch: @escaping PersoFetch, now: @escaping () -> Date = Date.init) {
        self.build = build
        self.fetch = fetch
        self.now = now
    }

    func decide(tag: String?, version: String) -> Decision {
        let ignored = "Release \(version) ignorée"
        guard let tag else { return .skip("\(ignored) : sa version d’origine est illisible.") }
        switch finalVerdicts[tag] {
        case .contains?:
            return .install
        case .lacks?:
            return .skip("\(ignored) : ne contient pas ton commit \(build.shortCommit).")
        default:
            startCheck(tag: tag)
            if let reason = lastReasons[tag] {
                return .skip("\(ignored) pour l’instant : \(reason). Nouvel essai à la prochaine vérification.")
            }
            return .skip("\(ignored) pour l’instant : vérification de ton commit \(build.shortCommit) en cours.")
        }
    }

    private func startCheck(tag: String) {
        guard !inFlight.contains(tag) else { return }
        if let last = lastAttempts[tag], now().throttleElapsed(since: last) < Self.retryInterval { return }
        inFlight.insert(tag)
        lastAttempts[tag] = now()
        let commit = build.commit
        let fetch = self.fetch
        Task { [weak self] in
            let verdict = await PersoReleaseGate.verdict(commit: commit, tag: tag, fetch: fetch)
            self?.finish(tag: tag, verdict: verdict)
        }
    }

    /// Internal for tests: records one answer as a finished check would.
    func finish(tag: String, verdict: PersoReleaseVerdict) {
        inFlight.remove(tag)
        switch verdict {
        case .contains, .lacks:
            finalVerdicts[tag] = verdict
            lastReasons[tag] = nil
        case .unknown(let reason):
            lastReasons[tag] = reason
        }
        Self.logger.notice("perso \(self.build.shortCommit, privacy: .public) vs release \(tag, privacy: .public): \(String(describing: verdict), privacy: .public)")
        onVerdict?(tag, verdict)
    }
}
