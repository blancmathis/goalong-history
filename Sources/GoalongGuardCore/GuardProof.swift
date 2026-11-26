import Darwin
import Foundation
import Security

/// L1L2-01: a perso lease is proved by a process in the request's stage folder, a path anyone with the user's
/// rights can create. Only a genuine, running process counts there: its own path is exactly the proof path (no
/// symlink or redirection), it is not stopped, and its code is valid and signed like this guard (same team).
/// Anything else fails closed: the guard then relaunches the app at once.
public enum GuardProof {
    /// Live, authenticated processes at exactly `executable`.
    public static func authenticPids(executable: String, requirement: String) -> [Int32] {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return [] }
        return GuardProcesses.pids(executable: executable).filter { pid in
            GuardProcesses.path(of: pid) == executable && !GuardProcesses.isStopped(pid) && valid(pid: pid, parsed)
        }
    }

    static func valid(pid: Int32, _ requirement: SecRequirement) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The guard's own signing identifier suffix; the relauncher of the same bundle is `<base>.relauncher`
    /// (scripts/build_app_core.sh signs both).
    public static let guardIdentifierSuffix = ".blocking-guard"
    public static let relauncherIdentifierSuffix = ".relauncher"

    /// F1: "the relauncher of this guard's bundle family, signed by `signer`". Any other binary of the same team
    /// (another product, a long-running CLI) copied to the proof path proves nothing. nil (no proof ever) when
    /// the guard identifier is not `<base>.blocking-guard` or holds characters a requirement cannot quote.
    public static func relauncherRequirement(signer: String, guardIdentifier: String) -> String? {
        guard guardIdentifier.hasSuffix(guardIdentifierSuffix) else { return nil }
        let base = String(guardIdentifier.dropLast(guardIdentifierSuffix.count))
        guard !base.isEmpty, base.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
        else { return nil }
        return "(\(signer)) and identifier \"\(base)\(relauncherIdentifierSuffix)\""
    }

    /// "The relauncher of this guard's bundle, signed by an Apple-issued developer certificate of this process's
    /// team"; nil when this process has no team (unsigned or ad hoc) or no guard identifier: then no stage proof
    /// is ever accepted.
    public static func sameTeamRequirement() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any],
              let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
              team.allSatisfy({ $0.isLetter || $0.isNumber }), !team.isEmpty else { return nil }
        return relauncherRequirement(signer: "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"",
                                     guardIdentifier: identifier)
    }
}
