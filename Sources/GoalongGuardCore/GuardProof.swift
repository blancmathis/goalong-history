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

    /// "Signed by an Apple-issued developer certificate of this process's team"; nil when this process has no
    /// team (unsigned or ad hoc): then no stage proof is ever accepted.
    public static func sameTeamRequirement() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.allSatisfy({ $0.isLetter || $0.isNumber }), !team.isEmpty else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
