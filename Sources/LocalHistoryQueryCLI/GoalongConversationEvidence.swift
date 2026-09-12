import Foundation
import LocalHistoryCore

/// Reuses the read-only conversation broker, including source consent and bounded pagination.
/// Source locators and provider IDs never enter the analysis context.
public enum GoalongConversationEvidence {
    public struct Selection: Sendable {
        public var evidence: [GoalongProfileAnalysis.Evidence]
        public var notice: String
    }
    struct Page: Decodable {
        struct Conversation: Decodable {
            struct Message: Decodable { var role: String; var text: String }
            var id: String; var providerName: String; var title: String
            var readStatus: String; var messages: [Message]; var messagesTruncated: Bool
        }
        var status: String; var nextCandidateOffset: Int?; var conversations: [Conversation]
        var issues: [String]
    }
    public static func load(root: URL, start: Date, end: Date) throws -> Selection {
        guard GoalongQueryCLI.capabilityConsentEnabled(rootDirectory: root, capability: "aiConversations") else {
            throw GoalongProfileAnalysis.invalid("Activez Conversation History dans les réglages avant de lire cette source.")
        }
        let selection = try collect(start: start, end: end) { day, offset in
            var bytes = Data()
            try GoalongQueryCLI.printAgentConversations(root: root, day: day, tokenBudget: 24_000,
                conversationLimit: 24, candidateOffset: offset, authorizedOnly: true, emit: { bytes = $0 })
            return bytes
        }
        guard GoalongQueryCLI.capabilityConsentEnabled(rootDirectory: root, capability: "aiConversations") else {
            throw GoalongProfileAnalysis.invalid("Conversation History a été désactivé pendant la lecture.")
        }
        return selection
    }
    static func collect(start: Date, end: Date, read: (Date, Int) throws -> Data) throws -> Selection {
        let calendar = Calendar.current, first = calendar.startOfDay(for: start)
        guard end > start, end.timeIntervalSince(first) <= 31 * 86400 else {
            throw GoalongProfileAnalysis.invalid("Choisissez au plus 31 jours de contexte conversationnel.")
        }
        let iso = ISO8601DateFormatter(), dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX"); dayFormat.dateFormat = "yyyy-MM-dd"
        let deadline = Date().addingTimeInterval(60)
        var day = first, rows: [GoalongProfileAnalysis.Evidence] = [], seen = Set<String>(), bytes = 0, partial = false
        while day < end {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
            var offset = 0
            repeat {
                guard Date() < deadline, !Task.isCancelled else { throw GoalongProfileAnalysis.invalid("Lecture interrompue ou trop longue. Réduisez la période de conversations.") }
                let page = try JSONDecoder().decode(Page.self, from: read(day, offset))
                guard ["available", "partial", "noConversations"].contains(page.status) else {
                    throw GoalongProfileAnalysis.invalid("Conversation History indisponible pour le \(dayFormat.string(from: day)) (\(page.status)). Vérifiez les sources ou réduisez la période.")
                }
                partial = partial || !page.issues.isEmpty
                for conversation in page.conversations {
                    if conversation.readStatus != "available" { partial = true; continue }
                    partial = partial || conversation.messagesTruncated
                    for message in conversation.messages {
                        guard ["user", "assistantFinal"].contains(message.role) else { throw GoalongProfileAnalysis.invalid("Rôle inattendu dans une conversation.") }
                        let key = conversation.id + "\n" + message.role + "\n" + message.text
                        guard !message.text.isEmpty, seen.insert(key).inserted else { continue }
                        let role = message.role == "user" ? "Utilisateur (déclaration ou demande)" : "Réponse finale de l’IA (proposition, pas une décision utilisateur)"
                        let note = "Conversation repérée pour le \(dayFormat.string(from: day)). Fenêtre de sélection uniquement : timestamp individuel indisponible ; du contexte antérieur peut être inclus."
                        let title = String(conversation.title.prefix(240))
                        // Split complete selected messages instead of silently dropping their tail.
                        var remaining = message.text[...]
                        while !remaining.isEmpty {
                            let chunk = String(remaining.prefix(3000)); remaining = remaining.dropFirst(chunk.count)
                            let text = "\(note)\nConversation : \(title)\n\(role)\nExtrait borné : \(conversation.messagesTruncated ? "oui" : "non")\n\(chunk)"
                            bytes += text.utf8.count
                            guard rows.count < 1400, bytes <= 160 * 1024 else { throw GoalongProfileAnalysis.invalid("Trop de contexte conversationnel. Choisissez moins de jours ou une sélection via ai-conversations et la CLI.") }
                            rows.append(.init(id: "c\(rows.count + 1)", start: iso.string(from: day), end: iso.string(from: nextDay),
                                kind: "ai", application: String(conversation.providerName.prefix(80)), text: text))
                        }
                    }
                }
                guard let next = page.nextCandidateOffset else { break }
                guard next > offset, next <= 50_000 else { throw GoalongProfileAnalysis.invalid("Pagination des conversations invalide.") }
                offset = next
            } while true
            day = nextDay
        }
        let notice = "Conversation History : \(rows.count) extraits sélectionnables. " + (partial ? "Lecture partielle : certains échanges sont tronqués ou indisponibles. " : "") + "Les dates sont des fenêtres de sélection, pas des timestamps de messages. Aucune durée ni exhaustivité de la journée n’est déduite."
        rows.insert(.init(id: "c0", start: iso.string(from: first), end: iso.string(from: end), kind: "ai", application: "Conversation History", text: notice), at: 0)
        return Selection(evidence: rows, notice: notice)
    }
}
