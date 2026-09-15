import Foundation

/// Pure syntax filter for observed sites. Invalid/local values are omitted; one bad
/// observation must not make every other application's export unavailable.
public enum GoalongPublicDomain {
    public static func normalized(_ observed: String) -> String? {
        var value = observed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, value.utf8.count <= 1024,
              !value.contains(where: { $0.isWhitespace }),
              !value.contains(where: { "/\\:@?#%[]".contains($0) }),
              let url = URL(string: "https://" + value), let ascii = url.host?.lowercased(), ascii.utf8.count <= 253 else { return nil }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }), let tld = labels.last, !tld.allSatisfy(\.isNumber), tld.count >= 2,
        !["localhost", "local", "localdomain", "internal", "invalid", "test", "example", "home", "lan"].contains(String(tld)) else { return nil }
        guard !["localhost", "localdomain", "home.arpa"].contains(ascii), !ascii.hasSuffix(".home.arpa") else { return nil }
        return ascii
    }
}
