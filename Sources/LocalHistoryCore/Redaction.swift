import Foundation

public enum StringSanitizer {
    public static func clean(_ input: String?, maxLength: Int) -> String? {
        guard let input else { return nil }

        let whitespaceNormalized = input.replacingOccurrences(
            of: "[\\r\\n\\t]+",
            with: " ",
            options: .regularExpression
        )

        let filteredScalars = whitespaceNormalized.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x20...0xD7FF, 0xE000...0xFFFD:
                return true
            default:
                return false
            }
        }

        let cleaned = String(String.UnicodeScalarView(filteredScalars))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= maxLength { return cleaned }
        return String(cleaned.prefix(maxLength)) + "…"
    }
}

public enum PrivacyClassifier {
    public static func containsPrivateMarker(in values: [String?], markers: [String]) -> Bool {
        let normalizedValues = values.compactMap { value in
            value?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }

        let normalizedMarkers = markers.compactMap { marker -> String? in
            let normalized =
                marker
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }

        return normalizedValues.contains { value in
            normalizedMarkers.contains { marker in
                value.localizedCaseInsensitiveContains(marker)
            }
        }
    }
}

public enum URLRedactor {
    private static let sensitiveParameterNames: Set<String> = [
        "access_token", "auth", "authorization", "code", "credential", "jwt",
        "key", "magic", "nonce", "oauth_token", "password", "refresh_token",
        "secret", "session", "sessionid", "signature", "sso", "state", "ticket", "token",
    ]

    public static func sanitize(
        _ rawValue: String?,
        redactAllQueryValues: Bool,
        maxLength: Int
    ) -> URLSnapshot? {
        guard let cleaned = StringSanitizer.clean(rawValue, maxLength: maxLength * 2) else {
            return nil
        }

        guard var components = URLComponents(string: cleaned) else {
            // Fail closed: never serialize a value that could not be parsed and redacted.
            return nil
        }

        var redactionApplied = false

        if components.user != nil {
            components.user = nil
            redactionApplied = true
        }
        if components.password != nil {
            components.password = nil
            redactionApplied = true
        }
        if components.fragment != nil {
            components.fragment = nil
            redactionApplied = true
        }

        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                let normalizedName = item.name.lowercased()
                if redactAllQueryValues || sensitiveParameterNames.contains(normalizedName) {
                    if item.value != nil { redactionApplied = true }
                    return URLQueryItem(name: item.name, value: nil)
                }
                return item
            }
        }

        let rendered = components.string ?? cleaned
        let finalValue = StringSanitizer.clean(rendered, maxLength: maxLength) ?? rendered
        if finalValue.count < rendered.count { redactionApplied = true }

        return URLSnapshot(
            value: finalValue,
            host: components.host?.lowercased(),
            redactionApplied: redactionApplied
        )
    }

    public static func domain(_ host: String?, matches excludedDomains: [String]) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }

        return excludedDomains.contains { rawDomain in
            let domain =
                rawDomain
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard !domain.isEmpty else { return false }
            return host == domain || host.hasSuffix("." + domain)
        }
    }
}
