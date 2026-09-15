#if os(macOS)
import Foundation
import LocalHistoryCore

struct GoalongAnalysisScope: Codable, Equatable {
    var applicationIDs: [String]? = nil
    var detailApplicationIDs: [String]? = nil
    var applicationNames: [String: String] = [:]
    var perApplicationFields: [String: [String]] = [:]
    var deviceIDs: [String]? = nil
    var conversationFolderIDs: [String]? = nil
    var excludedDomains: [String] = []
    var windowTitles = false
    var websiteDomains = false
    var fullURLs = false
    var visibleText = false
    var interfaceLabels = false
    var clicks = false
    var scrolling = false
    var typing = false
    var shortcuts = false
    var timestamps = false
    var conversationTitles = false
    var conversationUserMessages = false
    var conversationAssistantMessages = false
    var conversationCounts = true

    static func key(id: String?, name: String) -> String {
        if let id, !id.isEmpty { return id.lowercased() }
        return "name:" + name.lowercased()
    }
    func contains(_ keys: [String]?, id: String?, name: String) -> Bool {
        guard let keys else { return true }
        let set = Set(keys.map { $0.lowercased() })
        if set.contains(Self.key(id: id, name: name)) { return true }
        if id == nil { return applicationNames.contains { set.contains($0.key.lowercased()) && $0.value.caseInsensitiveCompare(name) == .orderedSame } }
        return false
    }
    func allows(id: String?, name: String) -> Bool { contains(applicationIDs, id: id, name: name) }
    func allowsDetails(id: String?, name: String) -> Bool { allows(id: id, name: name) && contains(detailApplicationIDs, id: id, name: name) }
    var hasEventDetails: Bool { !perApplicationFields.isEmpty || windowTitles || websiteDomains || fullURLs || visibleText || interfaceLabels || clicks || scrolling || typing || shortcuts || timestamps }
    var hasConversationText: Bool { conversationTitles || conversationUserMessages || conversationAssistantMessages }
    func allows(domain: String?) -> Bool {
        guard let domain else { return true }
        return !URLRedactor.domain(domain.lowercased(), matches: excludedDomains)
    }
    func allows(_ field: GoalongAnalysisField, id: String?, name: String) -> Bool {
        guard allowsDetails(id: id, name: name) else { return false }
        if let fields = perApplicationFields[Self.key(id: id, name: name)] { return fields.contains(field.rawValue) }
        return self[keyPath: field.keyPath]
    }
    func validate() throws {
        for values in [applicationIDs, detailApplicationIDs, deviceIDs, conversationFolderIDs] {
            guard (values?.count ?? 0) <= 2048, values?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else {
                throw invalid("La sélection contient trop d’éléments ou un identifiant invalide.")
            }
        }
        guard applicationNames.count <= 2048, applicationNames.allSatisfy({ $0.key.utf8.count <= 512 && $0.value.utf8.count <= 512 }), perApplicationFields.count <= 2048, perApplicationFields.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }), perApplicationFields.values.allSatisfy({ values in values.allSatisfy { GoalongAnalysisField(rawValue: $0) != nil } }), excludedDomains.count <= 512 else { throw invalid("La sélection est trop volumineuse.") }
        _ = try PrivacyScopeInput.domains(excludedDomains.joined(separator: "\n"))
    }
    private func invalid(_ text: String) -> NSError { NSError(domain: "GoalongAnalysisScope", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

enum GoalongAnalysisField: String, CaseIterable, Identifiable {
    case windowTitles, websiteDomains, fullURLs, visibleText, interfaceLabels, clicks, scrolling, typing, shortcuts, timestamps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .windowTitles: return "Titres des fenêtres"
        case .websiteDomains: return "Noms des sites"
        case .fullURLs: return "Adresses complètes"
        case .visibleText: return "Texte affiché"
        case .interfaceLabels: return "Libellés des boutons"
        case .clicks: return "Clics"
        case .scrolling: return "Défilement"
        case .typing: return "Activité de frappe"
        case .shortcuts: return "Raccourcis"
        case .timestamps: return "Horaires précis"
        }
    }
    var keyPath: WritableKeyPath<GoalongAnalysisScope, Bool> {
        switch self {
        case .windowTitles: return \.windowTitles
        case .websiteDomains: return \.websiteDomains
        case .fullURLs: return \.fullURLs
        case .visibleText: return \.visibleText
        case .interfaceLabels: return \.interfaceLabels
        case .clicks: return \.clicks
        case .scrolling: return \.scrolling
        case .typing: return \.typing
        case .shortcuts: return \.shortcuts
        case .timestamps: return \.timestamps
        }
    }
}

struct GoalongTextReplacement: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var search = ""
    var replacement = ""
    var caseSensitive = false
    var wholeWord = false
}

/// Literal, longest-first, single-pass replacements. Replacement text is not a
/// regex template and is never fed back into the matcher (no cascade).
struct GoalongTextTransformer {
    private let expression: NSRegularExpression?
    private let replacements: [String]
    init(_ rules: [GoalongTextReplacement]) throws {
        guard rules.count <= 100 else { throw Self.invalid("Limite : 100 remplacements.") }
        let active = rules.filter { !$0.search.isEmpty }
        guard active.allSatisfy({ $0.search.utf8.count <= 512 && $0.replacement.utf8.count <= 512 }) else {
            throw Self.invalid("Un texte à remplacer est trop long (512 octets maximum).")
        }
        let sorted = active.enumerated().sorted {
            $0.element.search.utf16.count == $1.element.search.utf16.count ? $0.offset < $1.offset : $0.element.search.utf16.count > $1.element.search.utf16.count
        }.map(\.element)
        var patterns: [String] = []
        for rule in sorted {
            let plain = rule.search.precomposedStringWithCanonicalMapping
            let encoded = plain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? plain
            let variants = Array(Set([plain, encoded])).sorted { $0.utf16.count > $1.utf16.count }
            let literal = "(?:" + variants.map(NSRegularExpression.escapedPattern).joined(separator: "|") + ")"
            let bounded = rule.wholeWord ? "(?<![\\p{L}\\p{N}_])" + literal + "(?![\\p{L}\\p{N}_])" : literal
            patterns.append("(" + (rule.caseSensitive ? bounded : "(?i:" + bounded + ")") + ")")
        }
        expression = patterns.isEmpty ? nil : try NSRegularExpression(pattern: patterns.joined(separator: "|"))
        replacements = sorted.map(\.replacement)
    }
    func apply(_ value: String, maximumCharacters: Int = 175_000) throws -> String {
        guard value.count <= 350_000 else { throw Self.invalid("Le texte à filtrer dépasse la limite locale.") }
        let normalized = value.precomposedStringWithCanonicalMapping
        guard let expression else {
            guard normalized.count <= maximumCharacters else { throw Self.invalid("Le texte dépasse la limite autorisée.") }
            return normalized
        }
        let source = normalized as NSString
        var output = "", cursor = 0, exceeded = false, outputLength = 0
        expression.enumerateMatches(in: normalized, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard let match else { return }
            let unmatchedLength = match.range.location - cursor
            output += source.substring(with: NSRange(location: cursor, length: unmatchedLength))
            outputLength += unmatchedLength
            for index in replacements.indices where match.range(at: index + 1).location != NSNotFound {
                output += replacements[index]; outputLength += replacements[index].utf16.count; break
            }
            cursor = NSMaxRange(match.range)
            if outputLength > maximumCharacters * 2 { exceeded = true; stop.pointee = true }
        }
        guard !exceeded else { throw Self.invalid("Les remplacements produisent un texte trop volumineux.") }
        output += source.substring(from: cursor)
        guard output.count <= maximumCharacters else { throw Self.invalid("Les remplacements produisent un texte trop volumineux.") }
        return output
    }
    private static func invalid(_ message: String) -> NSError { NSError(domain: "GoalongReplacement", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
#endif
