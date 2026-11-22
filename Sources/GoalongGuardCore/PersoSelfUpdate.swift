import Darwin
import Foundation

/// `make perso` self-update (Mathis, 2026-11-22): locked blocks run 24/7, so a perso build installs itself
/// from the running Goalong instead of the installer (which refuses during a block, spec K).
/// The script drops a signed bundle in `PersoUpdate/inbox/<id>/`; the app checks it (`PersoUpdatePolicy`,
/// signature against its own designated requirement), stages it beside itself, starts the staged relauncher,
/// swaps the two bundles (`PersoStage.swap`) and quits for an update. The relauncher reopens the new app and
/// rolls back unless it reports `health.json` in time. Pure parts live here so they are unit-tested.
public enum PersoUpdate {
    public static let releaseBundleIdentifier = "ai.goalong.localhistory"
    public static let commitKey = "GoalongPersoSourceCommit"
    public static let builtAtKey = "GoalongPersoBuiltAt"
    /// Mathis: during a locked block, at most one install per 10 minutes.
    public static let lockedInstallInterval: TimeInterval = 600
    /// The new app must report health within this delay, or the relauncher rolls back.
    public static let healthTimeout: TimeInterval = 45
    public static let stagePrefix = ".goalong-perso-stage-"

    /// Request ids are made by the script: letters, digits and dashes only (they name folders).
    public static func isValidRequestID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }
}

/// What a perso build says about itself (Info.plist).
public struct PersoBundleFacts: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var buildNumber: String?
    public var commit: String?
    public var builtAt: String?
    public init(bundleIdentifier: String?, buildNumber: String?, commit: String?, builtAt: String?) {
        self.bundleIdentifier = bundleIdentifier; self.buildNumber = buildNumber; self.commit = commit; self.builtAt = builtAt
    }
    public init(info: [String: Any]?) {
        self.init(bundleIdentifier: info?["CFBundleIdentifier"] as? String, buildNumber: info?["CFBundleVersion"] as? String,
                  commit: info?[PersoUpdate.commitKey] as? String, builtAt: info?[PersoUpdate.builtAtKey] as? String)
    }
    public static func read(app: URL) -> PersoBundleFacts {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return PersoBundleFacts(info: info)
    }
}

public enum PersoUpdateDecision: Equatable, Sendable {
    case accept
    case refuse(String)
}

/// Accept only a newer perso build of this very app. The signature is checked separately (Security framework).
public enum PersoUpdatePolicy {
    public static func decide(candidate: PersoBundleFacts, running: PersoBundleFacts, protected: Bool,
                              secondsSinceLaunch: TimeInterval) -> PersoUpdateDecision {
        guard running.bundleIdentifier == PersoUpdate.releaseBundleIdentifier,
              candidate.bundleIdentifier == running.bundleIdentifier else { return .refuse("autre identifiant d’app") }
        guard isFullCommit(candidate.commit), isFullCommit(running.commit) else { return .refuse("pas un build perso") }
        guard let newBuild = candidate.buildNumber, let oldBuild = running.buildNumber,
              compareBuildNumbers(newBuild, oldBuild) != .orderedAscending else { return .refuse("numéro de build plus ancien") }
        guard let newAt = candidate.builtAt, let oldAt = running.builtAt, isTimestamp(newAt), isTimestamp(oldAt),
              newAt > oldAt else { return .refuse("build pas plus récent que celui qui tourne") }
        if protected && secondsSinceLaunch < PersoUpdate.lockedInstallInterval {
            let wait = Int((PersoUpdate.lockedInstallInterval - max(0, secondsSinceLaunch)).rounded(.up))
            return .refuse("blocage verrouillé : 1 installation par 10 min, réessayez dans \(wait) s")
        }
        return .accept
    }

    static func isFullCommit(_ value: String?) -> Bool {
        guard let value, value.count == 40 else { return false }
        return value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `2026-11-22T10:00:00Z`: fixed width, so text order is time order.
    static func isTimestamp(_ value: String) -> Bool {
        value.count == 20 && value.hasSuffix("Z") && value.dropLast().unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || $0 == "-" || $0 == "T" || $0 == ":"
        }
    }

    public static func compareBuildNumbers(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? -1 }, right = b.split(separator: ".").map { Int($0) ?? -1 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0, r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// The staging folder beside the installed app: `/Applications/.goalong-perso-stage-<id>/Goalong History.app`.
public enum PersoStage {
    public static func stagedApp(for target: URL, request: String) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(PersoUpdate.stagePrefix + request, isDirectory: true)
            .appendingPathComponent(target.lastPathComponent, isDirectory: true)
    }

    /// The installed app a staged copy replaces, or nil when `staged` is not exactly a stage of `request`.
    public static func target(forStaged staged: URL, request: String) -> URL? {
        let stageDir = staged.deletingLastPathComponent()
        guard PersoUpdate.isValidRequestID(request), staged.pathExtension == "app",
              stageDir.lastPathComponent == PersoUpdate.stagePrefix + request else { return nil }
        return stageDir.deletingLastPathComponent().appendingPathComponent(staged.lastPathComponent, isDirectory: true)
    }

    /// Exchanges two folders atomically (same volume). Each path then holds the other bundle.
    public static func swap(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "échange impossible : \(String(cString: strerror(errno)))"])
        }
    }
}

/// Files under `~/Library/Application Support/LocalHistory/PersoUpdate/`.
public struct PersoUpdateFiles: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    /// The release data root; the relauncher has no AppPaths.
    public static var standard: PersoUpdateFiles {
        PersoUpdateFiles(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalHistory/PersoUpdate", isDirectory: true))
    }

    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var health: URL { root.appendingPathComponent("health.json") }
    public func request(_ id: String) -> URL { inbox.appendingPathComponent(id, isDirectory: true) }
    public func result(_ id: String) -> URL { request(id).appendingPathComponent("result.json") }

    public struct Health: Codable, Equatable, Sendable {
        public var pid: Int32
        public var builtAt: String
        public init(pid: Int32, builtAt: String) { self.pid = pid; self.builtAt = builtAt }
    }

    public struct Result: Codable, Equatable, Sendable {
        public static let accepted = "accepted", refused = "refused", installed = "installed", rolledBack = "rolled_back"
        public var state: String
        public var reason: String?
        public init(state: String, reason: String? = nil) { self.state = state; self.reason = reason }
    }

    public func writeHealth(_ health: Health) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? JSONEncoder().encode(health).write(to: self.health, options: .atomic)
    }

    public func healthMatches(pid: Int32, builtAt: String?) -> Bool {
        guard let builtAt, let data = try? Data(contentsOf: health),
              let value = try? JSONDecoder().decode(Health.self, from: data) else { return false }
        return value.pid == pid && value.builtAt == builtAt
    }

    /// Only into an existing request folder: a result never creates one.
    public func writeResult(_ id: String, _ result: Result) {
        guard PersoUpdate.isValidRequestID(id), FileManager.default.fileExists(atPath: request(id).path),
              let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: self.result(id), options: .atomic)
    }

    public func readResult(_ id: String) -> Result? {
        (try? Data(contentsOf: result(id))).flatMap { try? JSONDecoder().decode(Result.self, from: $0) }
    }

    /// Requests ready for the app: a folder named by a valid id, its `request.json`, no result yet. Oldest first.
    public func pendingRequests() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        return names.filter {
            PersoUpdate.isValidRequestID($0) && FileManager.default.fileExists(atPath: request($0).appendingPathComponent("request.json").path)
                && !FileManager.default.fileExists(atPath: result($0).path)
        }.sorted()
    }
}

/// After the swap: keep the new app when healthy, otherwise put the old one back. Both end by removing the
/// stage folder, which then holds the bundle that lost.
public enum PersoSwapFinish {
    public static func finish(target: URL, staged: URL, healthy: Bool) throws {
        if !healthy { try PersoStage.swap(target, staged) }
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }
}

#if os(macOS)
import Security

/// The candidate must pass a strict, nested, all-architecture check against the running app's own designated
/// requirement, and carry the same identifier, team and leaf certificate (the pinned identity).
public enum PersoSignature {
    public static func selfStaticCode() -> SecStaticCode? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    public static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    /// nil when valid, otherwise a short French reason.
    public static func check(candidate url: URL, reference: SecStaticCode) -> String? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(reference, [], &requirement) == errSecSuccess, let requirement else {
            return "exigence de signature de l’app introuvable"
        }
        guard let candidate = staticCode(at: url) else { return "signature illisible" }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            return "signature invalide ou d’une autre identité"
        }
        guard let mine = signingInfo(reference), let theirs = signingInfo(candidate),
              let id = mine.identifier, id == theirs.identifier,
              let team = mine.team, team == theirs.team,
              let leaf = mine.leaf, leaf == theirs.leaf else { return "identité de signature différente" }
        return nil
    }

    private static func signingInfo(_ code: SecStaticCode) -> (identifier: String?, team: String?, leaf: Data?)? {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any] else { return nil }
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        return (info[kSecCodeInfoIdentifier as String] as? String, info[kSecCodeInfoTeamIdentifier as String] as? String,
                certificates?.first.map { SecCertificateCopyData($0) as Data })
    }
}
#endif
