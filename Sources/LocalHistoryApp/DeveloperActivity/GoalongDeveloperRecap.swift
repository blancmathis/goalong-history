#if os(macOS)
import Foundation
import AgentActivity
import LocalHistoryCore

/// Explicitly selected, bounded aggregate context; never repository or modified-file paths.
enum GoalongDeveloperRecap {
    static let maximumProjects = 12
    static let maximumCharacters = 8000
    static func build(day: Date, selection: GoalongAnalysisSelection, agents: AgentActivityOverview,
                      privacy: GoalongPrivacyPolicy, root: URL = AppPaths.applicationSupportDirectory,
                      consents: GoalongCapabilityConsentStore = .shared,
                      transform: (String) throws -> String = { $0 },
                      onProjects: (Int) -> Void = { _ in }) throws -> String? {
        guard selection.developer == true else { return nil }
        // Provider/project metadata has no app/domain provenance; exclusions fail closed.
        guard !privacy.hasExclusions else { return "Développement : omis en raison des exclusions de confidentialité." }
        let pause = try GoalongGlobalPause.admit(in: root)
        try Task.checkCancellation()
        let ai = consents.isEnabled(.aiConversations)
        let developer = consents.isEnabled(.developerActivity)
        let t3 = T3CodeMetadataReader.read(day: day, enabled: ai, shouldContinue: { !Task.isCancelled && !GoalongGlobalPause.isPaused(in: root) })
        // Folder choices remain binding for already analysed agent captures.
        let allowed = selection.scope?.conversationFolderIDs
        var permittedAgents = agents
        permittedAgents.captures = agents.captures.filter { allowed?.contains($0.watchedFolderID) ?? true }
        let grouped = GoalongAgentProjectGrouping.group(permittedAgents, t3: t3, enabled: ai)
        let store = GoalongDeveloperStore(root: root)
        let selected = developer ? try store.configuration().projects : []
        let git = selected.prefix(maximumProjects).map { GoalongGitActivityReader.read(project: $0, day: day, shouldContinue: { !Task.isCancelled && !GoalongGlobalPause.isPaused(in: root) }) }
        let files = developer ? store.read(day: day) : .init(status: .disabled, buckets: [])
        let value = GoalongDeveloperDay(day: day, t3: t3, agents: grouped, git: git, files: files,
                                       selectedProjects: selected, suggestions: [], developerStatus: developer ? .ready : .disabled)
        let observed = Set(grouped.projects.map(\.id) + git.filter { !$0.actions.isEmpty }.map { $0.project.id }
            + files.buckets.filter { $0.modifiedFiles > 0 }.map(\.projectID))
        onProjects(min(maximumProjects, observed.count))
        let result = try render(value, transform: transform)
        try GoalongGlobalPause.revalidate(pause, in: root)
        guard GoalongPrivacyPolicy.load(in: root).revision == privacy.revision,
              consents.isEnabled(.aiConversations) == ai, consents.isEnabled(.developerActivity) == developer else { throw GoalongGlobalPause.PauseError.changed }
        return result
    }
    static func render(_ value: GoalongDeveloperDay, transform: (String) throws -> String = { $0 }) throws -> String {
        var projects = Dictionary(uniqueKeysWithValues: value.selectedProjects.map { ($0.id, $0) })
        for group in value.agents.projects { projects[group.id] = group.project }
        var lines = ["Développement — activité des outils, jamais le temps de travail de la personne.",
                     "T3 : \(value.t3.status.label). Fichiers : \(value.files.status.label).",
                     "Les spans de conversations ne prouvent pas une exécution continue ; les délais entre demandes sont plafonnés à 2 h."]
        for project in projects.values.sorted(by: { $0.id < $1.id }).prefix(maximumProjects) {
            let name = String((ActivitySemanticTextSanitizer.redact(try transform(project.name)) ?? "Projet").prefix(160)).replacingOccurrences(of: "\n", with: " ")
            let agent = value.agents.projects.first { $0.id == project.id }
            let git = value.git.first { $0.project.id == project.id }
            let changes = value.files.buckets.filter { $0.projectID == project.id }.reduce(0) { $0 + $1.modifiedFiles }
            var parts = [name]
            if let agent {
                if agent.sessions > 0 {
                    parts.append("\(agent.sessions) conversations")
                    if !agent.documentIntervals.isEmpty { parts.append("span observé \(Int(agent.documentSpanSeconds)) s") }
                    else { parts.append("durée de conversation inconnue") }
                }
                if let t3 = agent.t3 { parts.append("T3 : \(t3.requests) demandes, exécution \(Int(t3.busySeconds)) s, entre demandes \(Int(t3.waitingSeconds)) s, \(t3.maximumParallelTurns) tours simultanés au maximum") }
                if let tokens = agent.tokens { parts.append("\(tokens) jetons observés") }
                if let calls = agent.toolCalls { parts.append("\(calls) appels d’outils") }
                if let errors = agent.errors { parts.append("\(errors) erreurs") }
                if agent.partial { parts.append("métadonnées partielles") }
            }
            if let git {
                if git.status == .ready || git.status == .partial { parts.append("Git : \(git.commits.count) commits, \(git.actions.count - git.commits.count) autres actions (\(git.status.label))") }
                else { parts.append("Git : \(git.status.label)") }
            }
            if value.selectedProjects.contains(where: { $0.id == project.id }) {
                if value.files.buckets.contains(where: { $0.projectID == project.id }) { parts.append("\(changes) fichiers distincts par tranche de 5 min, cumul des tranches") }
                else { parts.append("Fichiers : \(value.files.status.label)") }
            }
            let line = parts.joined(separator: " · ")
            if lines.joined(separator: "\n").count + line.count + 1 > maximumCharacters - 160 { lines.append("Autres projets omis : section bornée."); break }
            lines.append(line)
        }
        if projects.count > maximumProjects { lines.append("\(projects.count - maximumProjects) autres projets omis.") }
        return lines.joined(separator: "\n")
    }
}
#endif
