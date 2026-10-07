import Foundation

/// Local identity for session suggestions. JevPayload never serializes this field.
public struct JevDistractionTarget: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case site, app }
    public let kind: Kind
    public let value: String
    public let name: String
    public var id: String { kind.rawValue + ":" + value }

    private init(kind: Kind, value: String, name: String) {
        self.kind = kind; self.value = value; self.name = name
    }
    public static func site(host: String) -> Self? {
        guard let domain = JevRegistrableDomain.domain(host) else { return nil }
        return Self(kind: .site, value: domain, name: domain)
    }
    public static func app(bundleIdentifier: String?, name: String) -> Self? {
        guard let id = bundleIdentifier, id.utf8.count <= 255,
              id.split(separator: ".", omittingEmptySubsequences: false).count >= 2,
              id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        let label = JevPayload.clean(name, bytes: 140)
        return Self(kind: .app, value: id, name: label.isEmpty ? JevPayload.clean(id, bytes: 140) : label)
    }
    public var isValid: Bool {
        switch kind {
        case .site: return Self.site(host: value) == self
        case .app: return Self.app(bundleIdentifier: value, name: name) == self
        }
    }
}

/// Public Suffix List algorithm, with private hosting boundaries and wildcard exceptions.
public enum JevRegistrableDomain {
    private struct Rules {
        var exact = Set<String>(), wildcard = Set<String>(), exceptions = Set<String>()
        init() {
            for line in JevPublicSuffixRules.text.split(separator: "\n") {
                if line.hasPrefix("!") { exceptions.insert(String(line.dropFirst())) }
                else if line.hasPrefix("*.") { wildcard.insert(String(line.dropFirst(2))) }
                else { exact.insert(String(line)) }
            }
        }
    }
    private static let rules = Rules()
    public static func domain(_ observed: String) -> String? {
        var input = observed.lowercased()
        if input.hasSuffix(".") { input.removeLast() }
        guard !input.isEmpty, input.utf8.count <= 1024,
              !input.contains(where: { $0.isWhitespace || "/\\:@?#%[]".contains($0) }),
              let host = URL(string: "https://" + input)?.host?.lowercased(), host.utf8.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host != "home.arpa", !host.hasSuffix(".home.arpa"), labels.count >= 2, labels.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }), let tld = labels.last,
              rules.exact.contains(String(tld)) || rules.wildcard.contains(String(tld)) else { return nil }
        var suffixCount = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.exceptions.contains(suffix) { suffixCount = labels.count - index - 1; break }
            if rules.exact.contains(suffix) { suffixCount = max(suffixCount, labels.count - index) }
            if index > 0, rules.wildcard.contains(suffix) { suffixCount = max(suffixCount, labels.count - index + 1) }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }
}
