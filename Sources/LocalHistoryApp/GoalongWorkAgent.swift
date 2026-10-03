#if os(macOS)
import Combine
import Foundation
import LocalHistoryCore

/// What may leave the Mac for classification: the global exclusions and the choices made
/// in « Données pour ChatGPT » (applications, sites, window titles, name masking) apply.
struct GoalongWorkSharingFilter {
    let policy: GoalongPrivacyPolicy
    let scope: GoalongAnalysisScope?
    let transformer: GoalongTextTransformer?

    init(policy: GoalongPrivacyPolicy, selection: GoalongAnalysisSelection) {
        self.policy = policy
        scope = selection.reviewed ? selection.scope : nil
        transformer = try? GoalongTextTransformer(selection.replacements ?? [])
    }

    /// A label safe to send, or nil when this context must stay on the Mac.
    func label(_ label: GoalongWorkContext.Label) -> GoalongWorkContext.Label? {
        guard !policy.blocked, !policy.excludes(appID: label.bundleIdentifier, name: label.application),
              !policy.excludes(domain: label.host) else { return nil }
        var host = label.host, title = label.title
        if let scope {
            guard scope.allows(id: label.bundleIdentifier, name: label.application), scope.allows(domain: label.host) else { return nil }
            if !scope.allows(.websiteDomains, id: label.bundleIdentifier, name: label.application) { host = nil }
            if !scope.allows(.windowTitles, id: label.bundleIdentifier, name: label.application) { title = nil }
        }
        func masked(_ value: String?) -> String? {
            guard let value else { return nil }
            guard let transformer else { return nil }
            return try? transformer.apply(value, maximumCharacters: 1_000)
        }
        guard let application = masked(label.application) else { return nil }
        return GoalongWorkContext.Label(application: application, bundleIdentifier: label.bundleIdentifier,
                                        host: masked(host), title: masked(title))
    }

    /// True when the scope removes window titles: classification still works, less precisely.
    var withholdsTitles: Bool { scope.map { !$0.windowTitles && $0.perApplicationFields.isEmpty } ?? false }
}

extension GoalongWorkSharingFilter {
    func permitsVisibleContext(_ label: GoalongWorkContext.Label) -> Bool {
        self.label(label) != nil && scope?.allows(.visibleText, id: label.bundleIdentifier, name: label.application) == true
    }
    func excerpt(_ text: String, label: GoalongWorkContext.Label) -> String? {
        guard permitsVisibleContext(label), let transformer else { return nil }
        return (try? transformer.apply(text, maximumCharacters: 2_000)).map { String($0.prefix(240)) }
    }
}

/// Runs the user's definition over the contexts of a day through the connected ChatGPT
/// account (isolated, tool-less Codex thread). Unknown contexts are sent longest first; automatic unclear verdicts may receive bounded daily reassessment.
@MainActor final class GoalongWorkAgent: ObservableObject {
    static let shared = GoalongWorkAgent()

    enum Readiness: Equatable {
        case ready, noDefinition, historyOff, noConsent, notConnected, paused
        var message: String {
            switch self {
            case .ready: return ""
            case .noDefinition: return "Décrivez d’abord ce qui compte comme travail pour vous."
            case .historyOff: return "L’historique de ce Mac est désactivé : il n’y a rien à classer."
            case .noConsent: return "Autorisez ChatGPT à classer votre temps."
            case .notConnected: return "Connectez votre compte ChatGPT pour lancer le classement."
            case .paused: return "Goalong est en pause : le classement reprendra ensuite."
            }
        }
    }

    @Published private(set) var runningDay: Date?
    @Published private(set) var progress: String?
    @Published private(set) var lastOutcome: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastRun: Date?

    private var attempts: [Date: (date: Date, failed: Bool)] = [:]
    private var task: Task<Void, Never>?
    private var session: CodexAppServerSession?
    private var operation = UUID()
    private let store: GoalongWorkStore
    private let root: URL

    init(store: GoalongWorkStore = .shared, root: URL = AppPaths.applicationSupportDirectory) {
        self.store = store; self.root = root
    }

    var isRunning: Bool { runningDay != nil }

    var readiness: Readiness {
        let consents = GoalongCapabilityConsentStore.shared
        if store.definition.isEmpty { return .noDefinition }
        if !consents.isEnabled(.localComputerHistory) { return .historyOff }
        if !consents.isEnabled(.chatGPTAnalysis) { return .noConsent }
        if GoalongGlobalPause.isPaused() { return .paused }
        guard case .connected = ChatGPTRecapRuntime.shared.connectionState else { return .notConnected }
        return .ready
    }

    /// Called by Activité with the days on screen, never on a timer: today at most every
    /// 15 minutes, another day once per launch, and nothing while a daily report runs.
    func classifyIfNeeded(_ days: [GoalongLocalAnalytics.Day], now: Date = Date()) {
        guard store.automatic, !isRunning, readiness == .ready, !ChatGPTRecapRuntime.shared.isGenerating else { return }
        let calendar = Calendar.current
        for day in days.reversed() where day.state == .ready && day.seconds(.unclassified) >= 120 {
            let today = calendar.isDate(day.date, inSameDayAs: now)
            if let attempt = attempts[day.date] {
                let wait: TimeInterval = attempt.failed ? 1_800 : (today ? 900 : .infinity)
                guard now.timeIntervalSince(attempt.date) >= wait else { continue }
            }
            classify(day: day.date, userInitiated: false)
            return
        }
    }

    /// The day note goes to the agent only when the reviewed recap shares it, and never beside an exclusion.
    static func sharedDayNote(root: URL, day: Date, selection: GoalongAnalysisSelection, policy: GoalongPrivacyPolicy) -> String? {
        guard selection.isValid(for: policy), selection.systemSources?.dayNote == true, !policy.hasExclusions else { return nil }
        return try? GoalongDayNoteStore.get(root: root, day: day)
    }

    func classify(day: Date, userInitiated: Bool = true, dayNote: String? = nil) {
        guard !isRunning else { return }
        let state = readiness
        guard state == .ready else {
            if userInitiated { lastError = state.message }
            return
        }
        if userInitiated, ChatGPTRecapRuntime.shared.isGenerating {
            lastError = "Un bilan quotidien est en cours. Réessayez dans quelques minutes."
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let id = UUID(); operation = id
        runningDay = start; progress = "Lecture de la journée sur ce Mac…"; lastError = nil
        attempts[start] = (Date(), false)
        let definition = store.definition, revision = store.revision, root = self.root
        let policy = GoalongPrivacyPolicy.load(in: root), selection = GoalongAnalysisSelection.load(root: root)
        let filter = GoalongWorkSharingFilter(policy: policy, selection: selection)
        let note = dayNote ?? Self.sharedDayNote(root: root, day: start, selection: selection, policy: policy)
        let dayName = Self.dayString(start, calendar: calendar)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let observation = await Task.detached(priority: .utility) {
                    GoalongWorkClassification.observe(root: root, day: start, calendar: calendar,
                                                      shouldContinue: { !Task.isCancelled })
                }.value
                guard operation == id else { return }
                guard let observation else {
                    throw GoalongWorkClassification.Failure.invalid("La journée n’a pas pu être lue entièrement. Réessayez ; rien n’a été envoyé.")
                }
                var labels: [String: GoalongWorkContext.Label] = [:]
                for (key, label) in observation.labels { labels[key] = filter.label(label) }
                let pending = GoalongWorkClassification.pending(day: observation.day, labels: labels, verdicts: store.verdicts, calendar: calendar)
                guard !pending.keys.isEmpty else {
                    finish(id, outcome: "Tout ce qui pouvait être classé le \(GoalongUIFormat.day(start)) l’est déjà.")
                    return
                }
                let reasks = Set(pending.keys.filter { store.verdicts.contexts[$0]?.verdict == .unclear })
                let rawExcerpts = await Task.detached(priority: .utility) {
                    GoalongWorkReassessment.excerpts(root: root, day: start, keys: reasks, calendar: calendar,
                        permits: filter.permitsVisibleContext, shouldContinue: { !Task.isCancelled })
                }.value
                guard operation == id else { return }
                var excerpts: [String: String] = [:]
                for (key, text) in rawExcerpts {
                    if let label = observation.labels[key] { excerpts[key] = filter.excerpt(text, label: label) }
                }
                let size = GoalongWorkClassification.maximumContextsPerRequest
                let keys = Array(pending.keys.prefix(size * 3))
                let batches = stride(from: 0, to: keys.count, by: size).map { Array(keys[$0..<min($0 + size, keys.count)]) }
                guard let executable = CodexExecutableLocator.locate() else { throw CodexAppServerError.executableUnavailable }
                try ChatGPTSecureStorage.prepareDirectory(AppPaths.chatGPTDirectory)
                // The connected ChatGPT account, under the strict tool-less, network-less profile.
                let session = try CodexAppServerSession(executableURL: executable,
                    codexHomeURL: AppPaths.chatGPTCodexHomeDirectory, siteAnalysisOnly: true)
                self.session = session
                defer { session.close(); if operation == id { self.session = nil } }
                var classified = 0, work = 0
                for (index, batch) in batches.enumerated() {
                    guard operation == id, readiness == .ready, store.revision == revision else {
                        throw GoalongWorkClassification.Failure.invalid("La définition ou une autorisation a changé : classement arrêté.")
                    }
                    progress = batches.count > 1
                        ? "L’agent classe \(batch.count) contextes (\(index + 1)/\(batches.count))…"
                        : "L’agent classe \(batch.count) contexte\(batch.count > 1 ? "s" : "")…"
                    let request = GoalongWorkClassification.request(date: dayName, definition: definition, pending: pending,
                        batch: batch, day: observation.day, verdicts: store.verdicts, knownTasks: store.knownTasks,
                        examples: store.examples, calendar: calendar, contextExcerpts: excerpts, dayNote: note)
                    let prompt = GoalongWorkClassification.prompt(request, definition: definition)
                    let privacyRevision = filter.policy.revision
                    guard store.markAsked(batch, revision: revision, day: dayName) else { throw GoalongWorkClassification.Failure.invalid("La tentative n’a pas pu être enregistrée. Rien n’a été envoyé.") }
                    let response = try await Task.detached(priority: .userInitiated) {
                        let directory = try GoalongSiteAnalysisModel.makeWorkingDirectory()
                        defer { try? FileManager.default.removeItem(at: directory) }
                        return try session.generateWorkClassification(prompt: prompt, privacyRevision: privacyRevision,
                                                                      workingDirectory: directory)
                    }.value
                    guard operation == id else { return }
                    let assignments = try GoalongWorkClassification.apply(response, to: request)
                    store.merge(assignments, revision: revision, day: dayName)
                    classified += assignments.count
                    work += assignments.values.filter { $0.verdict == .work }.count
                }
                let rest = pending.keys.count - keys.count
                finish(id, outcome: "\(classified) contexte\(classified > 1 ? "s" : "") classé\(classified > 1 ? "s" : "") le \(GoalongUIFormat.day(start)), dont \(work) de travail."
                    + (rest > 0 ? " \(rest) autre\(rest > 1 ? "s" : "") au prochain passage." : ""))
            } catch {
                guard operation == id else { return }
                attempts[start] = (Date(), true)
                SupportDiagnostics.shared.failure(error, component: .analysis)
                lastError = (error as? LocalizedError)?.errorDescription ?? "Le classement n’a pas abouti. Réessayez."
                runningDay = nil; progress = nil
            }
        }
    }

    func cancel() {
        operation = UUID(); task?.cancel(); session?.close(); session = nil
        runningDay = nil; progress = nil
    }

    private func finish(_ id: UUID, outcome: String) {
        guard operation == id else { return }
        lastOutcome = outcome; lastRun = Date(); runningDay = nil; progress = nil
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
#endif
