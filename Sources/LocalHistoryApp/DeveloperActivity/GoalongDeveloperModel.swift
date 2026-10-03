#if os(macOS)
import Foundation
import Combine
import AgentActivity
import LocalHistoryCore

struct GoalongDeveloperDay: Equatable, Sendable {
    let day: Date
    let t3: T3CodeDay
    let agents: GoalongAgentProjectsDay
    let git: [GoalongGitActivity]
    let files: GoalongFileModificationsDay
    let selectedProjects: [GoalongDeveloperProject]
    let suggestions: [GoalongDeveloperProject]
    let developerStatus: GoalongDeveloperLaneStatus
}

actor GoalongDeveloperReader {
    private let root: URL
    private let t3URL: URL
    private var cache: [String: (Date, T3CodeDay)] = [:]
    private var gitCache: [String: GoalongGitActivity] = [:]
    init(root: URL, t3URL: URL = T3CodeMetadataReader.sourceURL()) { self.root = root; self.t3URL = t3URL }
    func read(day: Date, agents: AgentActivityOverview, aiEnabled: Bool, developerEnabled: Bool) throws -> GoalongDeveloperDay {
        try Task.checkCancellation()
        let paused = GoalongGlobalPause.isPaused(in: root)
        let aiEnabled = aiEnabled && !paused, developerEnabled = developerEnabled && !paused
        let start = Calendar.current.startOfDay(for: day)
        let fingerprint = aiEnabled ? T3CodeMetadataReader.fingerprint(at: t3URL) : "disabled"
        let key = "\(start.timeIntervalSince1970)|\(fingerprint)|\(aiEnabled)|\(Int(Date().timeIntervalSince1970 / 60))"
        let t3: T3CodeDay
        if let entry = cache[key], Date().timeIntervalSince(entry.0) < 60 { t3 = entry.1 }
        else {
            t3 = T3CodeMetadataReader.read(at: t3URL, day: start, enabled: aiEnabled, shouldContinue: { !Task.isCancelled && !GoalongGlobalPause.isPaused(in: self.root) })
            if cache.count >= 56 { cache.removeAll() }
            cache[key] = (Date(), t3)
        }
        try Task.checkCancellation()
        let grouped = GoalongAgentProjectGrouping.group(agents, t3: t3, enabled: aiEnabled)
        let store = GoalongDeveloperStore(root: root)
        var selected: [GoalongDeveloperProject] = [], git: [GoalongGitActivity] = []
        var status: GoalongDeveloperLaneStatus = .disabled
        var files = GoalongFileModificationsDay(status: .disabled, buckets: [])
        do { selected = try store.configuration().projects } catch { if developerEnabled { status = .failed("Les projets sélectionnés sont illisibles.") } }
        if developerEnabled {
            do {
                selected = try store.configuration().projects
                for project in selected {
                    try Task.checkCancellation()
                    let stamp = GoalongGitActivityReader.sourceFingerprint(project: project)
                    let gitKey = project.id + "|\(start.timeIntervalSince1970)|" + stamp
                    if let cached = gitCache[gitKey] { git.append(cached) }
                    else {
                        let value = GoalongGitActivityReader.read(project: project, day: start, shouldContinue: { !Task.isCancelled && !GoalongGlobalPause.isPaused(in: self.root) })
                        if gitCache.count >= 128 { gitCache.removeAll() }
                        if value.status != .partial { gitCache[gitKey] = value }
                        git.append(value)
                    }
                }
                let loaded = store.read(day: start)
                let ids = Set(selected.map(\.id))
                files = .init(status: loaded.status, buckets: loaded.buckets.filter { ids.contains($0.projectID) })
                let statuses = git.map(\.status) + [files.status]
                if statuses.contains(.partial) { status = .partial }
                else if statuses.contains(.permissionDenied) { status = .permissionDenied }
                else if statuses.contains(.ready) { status = .ready }
                else if !git.isEmpty && git.allSatisfy({ $0.status == .unsupported }) { status = .unsupported }
                else { status = .noData }
                if case .failed(let reason) = files.status { status = .failed(reason) }
            } catch is CancellationError { throw CancellationError() }
            catch { status = .failed("Les projets sélectionnés sont illisibles.") }
        }
        let selectedIDs = Set(selected.map(\.id))
        let suggested = Dictionary(grouping: grouped.projects.map(\.project) + t3.discoveredProjects, by: \.id).values.compactMap { GoalongDeveloperProject.combining($0) }
        let suggestions = suggested.filter { !selectedIDs.contains($0.id) && GoalongRepositoryResolver.commonGitDirectory(URL(fileURLWithPath: $0.rootPath)) != nil }
        return .init(day: start, t3: t3, agents: grouped, git: git, files: files, selectedProjects: selected, suggestions: suggestions, developerStatus: status)
    }
}

/// UI API only: no visual decisions and no implicit source or project consent.
@MainActor final class GoalongDeveloperModel: ObservableObject {
    @Published private(set) var value: GoalongDeveloperDay?
    @Published private(set) var selectedProjects: [GoalongDeveloperProject] = []
    @Published private(set) var status: GoalongDeveloperLaneStatus = .disabled
    @Published private(set) var t3Discovered = false
    private let root: URL
    private let consents: GoalongCapabilityConsentStore
    private let reader: GoalongDeveloperReader
    init(root: URL = AppPaths.applicationSupportDirectory, consents: GoalongCapabilityConsentStore = .shared) {
        self.root = root; self.consents = consents; reader = .init(root: root)
        selectedProjects = (try? GoalongDeveloperStore(root: root).configuration().projects) ?? []
    }
    func refresh(day: Date, agents: AgentActivityOverview? = nil) async {
        let ai = consents.isEnabled(.aiConversations), developer = consents.isEnabled(.developerActivity)
        t3Discovered = ai && !GoalongGlobalPause.isPaused(in: root) && T3CodeMetadataReader.isDiscovered()
        do {
            let result = try await reader.read(day: day, agents: agents ?? .init(day: day), aiEnabled: ai, developerEnabled: developer)
            guard consents.isEnabled(.aiConversations) == ai, consents.isEnabled(.developerActivity) == developer,
                  !GoalongGlobalPause.isPaused(in: root) else { value = nil; status = .disabled; return }
            value = result; selectedProjects = result.selectedProjects; status = result.developerStatus
        } catch is CancellationError { }
        catch { status = .failed("Le contexte de développement n’a pas pu être chargé.") }
    }
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        let saved = consents.set(.developerActivity, enabled: enabled, surface: .settings)
        if saved && !enabled { value = nil; status = .disabled }
        return saved
    }
    func addProject(_ directory: URL, name: String? = nil) throws {
        let store = GoalongDeveloperStore(root: root); try store.add(directory, name: name); selectedProjects = try store.configuration().projects
    }
    func addProject(_ suggestion: GoalongDeveloperProject) throws {
        for path in suggestion.observationRoots { try addProject(URL(fileURLWithPath: path), name: suggestion.name) }
    }
    func removeProject(id: String) throws {
        let store = GoalongDeveloperStore(root: root); try store.remove(projectID: id); selectedProjects = try store.configuration().projects; value = nil
    }
    var suggestions: [GoalongDeveloperProject] { value?.suggestions ?? [] }
}
#endif
