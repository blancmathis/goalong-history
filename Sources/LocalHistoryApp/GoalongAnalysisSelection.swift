#if os(macOS)
import Foundation
import LocalHistoryCore

struct GoalongAnalysisSelection: Codable, Equatable {
    var version = 2
    var reviewed = false
    var computer = false
    var screenTime = false
    var conversations = false
    var details = false
    var revision = UUID().uuidString
    var privacyRevision: String?
    var scope: GoalongAnalysisScope?
    var replacements: [GoalongTextReplacement]?
    var outputGuidance: String?
    var hasSources: Bool { computer || screenTime || conversations }
    func isValid(for policy: GoalongPrivacyPolicy) -> Bool {
        guard reviewed, hasSources, !policy.blocked, privacyRevision == policy.revision else { return false }
        do { try validate(); return true } catch { return false }
    }
    static func load(root: URL = AppPaths.applicationSupportDirectory) -> Self {
        let file = root.appendingPathComponent("chatgpt-analysis-selection.json")
        guard let data = try? ChatGPTHistoryStore.readStableSource(at: file, maximumBytes: 1_048_576),
              let value = try? JSONDecoder().decode(Self.self, from: data), [1, 2].contains(value.version) else {
            var empty = Self(); empty.revision = "unreviewed"; return empty
        }
        return value
    }
    func validate() throws {
        guard [1, 2].contains(version) else { throw PrivacyScopeInput.invalid("Format de sélection inconnu.") }
        if version == 2 {
            guard let scope else { throw PrivacyScopeInput.invalid("Choisissez les données avant d’autoriser l’analyse.") }
            if computer || screenTime {
                guard scope.applicationIDs != nil, scope.detailApplicationIDs != nil else {
                    throw PrivacyScopeInput.invalid("La liste des applications doit être confirmée.")
                }
            }
            if screenTime, scope.deviceIDs == nil { throw PrivacyScopeInput.invalid("Confirmez les appareils autorisés.") }
            if conversations, scope.conversationFolderIDs == nil { throw PrivacyScopeInput.invalid("Confirmez les dossiers autorisés.") }
        }
        try scope?.validate()
        guard (outputGuidance?.count ?? 0) <= 4000 else { throw NSError(domain: "GoalongAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Limite : 4 000 caractères de consignes."]) }
        guard !(replacements ?? []).contains(where: { $0.search.isEmpty && !$0.replacement.isEmpty }) else {
            throw PrivacyScopeInput.invalid("Un remplacement est incomplet : indiquez le texte à rechercher.")
        }
        _ = try GoalongTextTransformer(replacements ?? [])
    }
    func save(root: URL = AppPaths.applicationSupportDirectory) throws {
        try validate()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("chatgpt-analysis-selection.json")
        try ChatGPTSecureStorage.writeFileAtomically(JSONEncoder().encode(self), to: url)
        guard Self.load(root: root) == self else { throw NSError(domain: "GoalongAnalysisSelection", code: 1) }
    }
}

#endif
