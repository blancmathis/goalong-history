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

    static let maskingFailure = GoalongWorkClassification.Failure.invalid(
        "Les remplacements de noms n’ont pas pu être appliqués. Rien n’a été envoyé.")

    /// Free text (definition, note, task names) with the name replacements applied. Fails closed.
    func text(_ value: String, maximumCharacters: Int = 4_000) throws -> String {
        guard let transformer, let masked = try? transformer.apply(String(value.prefix(maximumCharacters)),
                                                                   maximumCharacters: maximumCharacters * 2) else {
            throw Self.maskingFailure
        }
        return masked
    }

    /// The definition as the agent may read it. Its revision is not used: callers keep the original one.
    func definition(_ value: GoalongWorkDefinition) throws -> GoalongWorkDefinition {
        GoalongWorkDefinition(goals: try text(value.goals), applications: try text(value.applications),
                              content: try text(value.content), notWork: try text(value.notWork))
    }

    /// The owner's corrections, filtered with today's exclusions, scope and replacements:
    /// a correction the current choices refuse stays on the Mac. The newest are kept.
    func examples(_ corrections: [GoalongWorkStore.Correction]) throws -> [GoalongWorkClassification.Example] {
        try candidates(corrections).suffix(GoalongWorkClassification.maximumExamples)
            .map { GoalongWorkClassification.Example(label: $0.label, assignment: $0.assignment) }
    }

    /// Every correction the current choices allow, masked, oldest first: the pool the
    /// nearest examples of a call are drawn from.
    func candidates(_ corrections: [GoalongWorkStore.Correction]) throws -> [(label: GoalongWorkContext.Label, assignment: GoalongWorkAssignment)] {
        var result: [(label: GoalongWorkContext.Label, assignment: GoalongWorkAssignment)] = []
        for correction in corrections {
            guard correction.verdict != .unclear, let label = label(correction.label) else { continue }
            let task = try correction.task.map { try text($0) }
            result.append((label, GoalongWorkAssignment(verdict: correction.verdict, task: task, byOwner: true)))
        }
        return result
    }

    /// Verdicts whose task names (shown in the timeline) carry the name replacements.
    func verdicts(_ value: GoalongWorkVerdicts, cache: inout [String: String]) throws -> GoalongWorkVerdicts {
        var result = value
        for (key, assignment) in value.contexts {
            guard let task = assignment.task else { continue }
            if cache[task] == nil { cache[task] = try text(task) }
            result.contexts[key]?.task = cache[task]
        }
        return result
    }
}

/// Runs the user's definition over the contexts of a day through the connected ChatGPT
/// account (isolated, tool-less Codex thread). Pending groups are sent longest first, in one
/// bounded call per pass; automatic unclear verdicts may receive bounded daily reassessment.
struct UncheckedSendable<T>: @unchecked Sendable { let value: T }

@MainActor final class GoalongWorkAgent: ObservableObject {
    static let shared = GoalongWorkAgent()

    enum Readiness: Equatable {
        case ready, noDefinition, historyOff, noConsent, notConnected, paused
        var message: String {
            switch self {
            case .ready: return ""
            case .noDefinition: return "Décrivez d’abord ce qui compte comme travail pour vous."
            case .historyOff: return "L’enregistrement est désactivé : il n’y a rien à classer."
            case .noConsent: return "Autorisez le classement automatique de votre temps."
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

    /// Why the last background tick did not call the agent; nil when nothing blocks it.
    @Published private(set) var waiting: GoalongWorkState.Waiting?
    /// The account limits read before and after the last call.
    @Published private(set) var lastLimits: GoalongAccountLimits?

    /// A background tick arrived during a run: the next tick handles it.
    private var rerunRequested = false
    private var backgroundTimer: Timer?
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

    /// The background pass: checked every 15 minutes while Goalong runs, with or without
    /// Activité open. It calls the agent only as `GoalongWorkSchedule` allows (2 calls and
    /// 24 000 tokens a day at most) and only with the background consent.
    func startBackgroundSchedule() {
        guard backgroundTimer == nil else { return }
        let timer = Timer(timeInterval: 900, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundTick() }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    func stopBackgroundSchedule() { backgroundTimer?.invalidate(); backgroundTimer = nil }

    func backgroundTick(now: Date = Date()) {
        guard store.backgroundConsent, !isRunning, readiness == .ready, !ChatGPTRecapRuntime.shared.isBusyWithCodex else { return }
        classify(day: now, userInitiated: false)
    }

    /// Why the agent cannot classify now, as « en attente » shows it; nil when it can.
    func waitingReason(background: Bool = true, now: Date = Date()) -> GoalongWorkState.Waiting? {
        switch readiness {
        case .noDefinition: return .noDefinition
        case .historyOff: return .historyOff
        case .noConsent: return .noConsent
        case .notConnected: return .notConnected
        case .paused: return .paused
        case .ready: break
        }
        if GoalongPrivacyPolicy.load(in: root).blocked { return .sharingBlocked }
        if lastLimits?.isNear == true { return .accountLimitNear }
        let usage = store.usage.day(Self.dayString(now))
        if usage.tokens + GoalongWorkSchedule.minimumCallTokens > GoalongWorkSchedule.dailyTokenCap { return .dailyCapReached }
        if background, !store.backgroundConsent { return .backgroundConsentMissing }
        if background, usage.backgroundCalls >= GoalongWorkSchedule.backgroundCallsPerDay { return .dailyCapReached }
        if ChatGPTRecapRuntime.shared.isBusyWithCodex { return .codexBusy }
        return nil
    }

    /// The day a manual "Classer maintenant" targets: the day itself for a one-day view, otherwise the
    /// most recent ready day of the period that still has unclassified time.
    nonisolated static func manualTarget(days: [GoalongLocalAnalytics.Day], fallback: Date) -> Date {
        guard days.count > 1 else { return fallback }
        return days.last(where: { $0.state == .ready && $0.seconds(.unclassified) >= 120 })?.date ?? fallback
    }

    /// The day note goes to the agent only when the reviewed recap shares it, and never beside an exclusion.
    static func sharedDayNote(root: URL, day: Date, selection: GoalongAnalysisSelection, policy: GoalongPrivacyPolicy) -> String? {
        guard selection.isValid(for: policy), selection.systemSources?.dayNote == true, !policy.hasExclusions else { return nil }
        return try? GoalongDayNoteStore.get(root: root, day: day)
    }

    /// One pass over a day: answers known locally first (rules, group verdicts: no call),
    /// then at most one call for the groups still pending, if the schedule allows it.
    /// `userInitiated` is the manual pass of Réglages; it counts in the daily token cap.
    func classify(day: Date, userInitiated: Bool = true, dayNote: String? = nil) {
        guard !isRunning else {
            if !userInitiated { rerunRequested = true }
            return
        }
        let state = readiness
        guard state == .ready else {
            if userInitiated { lastError = state.message }
            return
        }
        if !userInitiated, ChatGPTRecapRuntime.shared.isBusyWithCodex {
            // Codex is in use by a recap, an account check or a connection: the next tick tries again.
            return
        }
        if userInitiated, ChatGPTRecapRuntime.shared.isBusyWithCodex {
            lastError = ChatGPTRecapRuntime.shared.isGenerating
                ? "Un bilan quotidien est en cours. Réessayez dans quelques minutes."
                : "La connexion ChatGPT est en cours d’utilisation. Réessayez dans un instant."
            return
        }
        if !userInitiated, !store.backgroundConsent { return }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let id = UUID(); operation = id
        runningDay = start; progress = "Lecture de la journée sur ce Mac…"
        if userInitiated { lastError = nil }
        let definition = store.definition, revision = store.revision, root = self.root
        let policy = GoalongPrivacyPolicy.load(in: root), selection = GoalongAnalysisSelection.load(root: root)
        let filter = GoalongWorkSharingFilter(policy: policy, selection: selection)
        let selectionRevision = selection.revision
        let note = dayNote ?? Self.sharedDayNote(root: root, day: start, selection: selection, policy: policy)
        let dayName = Self.dayString(start, calendar: calendar)
        let today = Self.dayString(Date(), calendar: calendar)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let observation = await Self.detachedForwardingCancellation(priority: .utility) {
                    GoalongWorkClassification.observe(root: root, day: start, calendar: calendar,
                                                      shouldContinue: { !Task.isCancelled })
                }
                guard operation == id else { return }
                guard let observation else {
                    throw GoalongWorkClassification.Failure.invalid("La journée n’a pas pu être lue entièrement. Réessayez ; rien n’a été envoyé.")
                }
                // Rules and owner answers are matched on what the Mac saw, before any masking.
                var labels: [String: GoalongWorkContext.Label] = [:]
                for (key, label) in observation.labels {
                    if let known = store.verdicts.resolution(key: key, label: label), known.source != .agent { continue }
                    labels[key] = filter.label(label)
                }
                // A group the agent already judged answers its new members without a call.
                let inherited = GoalongWorkClassification.inherited(labels: labels, verdicts: store.verdicts, groups: store.groupVerdicts)
                let resolvedLocally = store.merge(inherited, revision: revision, day: dayName).count
                let pending = GoalongWorkClassification.pending(day: observation.day, labels: labels, verdicts: store.verdicts, calendar: calendar)
                let usage = store.usage.day(today)
                switch GoalongWorkSchedule.decide(now: Date(), pendingGroups: pending.keys.count, usage: usage,
                                                  manual: userInitiated, calendar: calendar) {
                case .skip(let reason):
                    if userInitiated {
                        if let reason { throw GoalongWorkClassification.Failure.invalid(reason.message) }
                        finish(id, outcome: "Tout ce qui pouvait être classé le \(GoalongUIFormat.day(start)) l’est déjà.")
                    } else {
                        waiting = reason
                        runningDay = nil; progress = nil
                        if resolvedLocally > 0 { lastOutcome = "\(resolvedLocally) contexte\(resolvedLocally > 1 ? "s" : "") classé\(resolvedLocally > 1 ? "s" : "") par vos règles et les groupes déjà connus." }
                    }
                    return
                case .call:
                    waiting = nil
                }
                let reasks = Set(pending.keys.filter { store.verdicts.contexts[$0]?.verdict == .unclear })
                let rawExcerpts = await Self.detachedForwardingCancellation(priority: .utility) {
                    GoalongWorkReassessment.excerpts(root: root, day: start, keys: reasks, calendar: calendar,
                        permits: filter.permitsVisibleContext, shouldContinue: { !Task.isCancelled })
                }
                guard operation == id else { return }
                var excerpts: [String: String] = [:]
                for (key, text) in rawExcerpts {
                    if let label = observation.labels[key] { excerpts[key] = filter.excerpt(text, label: label) }
                }
                guard let executable = CodexExecutableLocator.locate() else { throw CodexAppServerError.executableUnavailable }
                try ChatGPTSecureStorage.prepareDirectory(AppPaths.chatGPTDirectory)
                // The connected ChatGPT account, under the strict tool-less, network-less profile.
                // Built off the main actor: the launch and the initialize handshake can block for seconds.
                guard let session = try await Self.makeOffMain({
                    try CodexAppServerSession(executableURL: executable,
                        codexHomeURL: AppPaths.chatGPTCodexHomeDirectory, siteAnalysisOnly: true, homeLeaseWait: 0)
                }, isStale: { [weak self] in self?.operation != id }, close: { $0.close() }) else { return }
                self.session = session
                defer { session.close(); if operation == id { self.session = nil } }
                // The account's own limits, read without inference: stop before it runs out.
                let before = await Task.detached(priority: .userInitiated) { session.readAccountLimits() }.value
                guard operation == id else { return }
                if let before { lastLimits = before }
                if before?.isNear == true {
                    waiting = .accountLimitNear
                    throw GoalongWorkClassification.Failure.invalid(GoalongWorkState.Waiting.accountLimitNear.message)
                }
                // Name replacements apply to everything the agent reads, not only the contexts.
                let sharedDefinition = try filter.definition(definition)
                let sharedNote = try note.map { try filter.text($0) }
                var maskedTasks: [String: String] = [:]
                guard operation == id, readiness == .ready, store.revision == revision,
                      GoalongPrivacyPolicy.load(in: root).revision == policy.revision,
                      GoalongAnalysisSelection.load(root: root).revision == selectionRevision else {
                    throw GoalongWorkClassification.Failure.invalid("La définition ou une autorisation a changé : classement arrêté.")
                }
                let knownTasks = try store.knownTasks.prefix(GoalongWorkClassification.maximumKnownTasks).map {
                    try maskedTasks[$0] ?? filter.text($0)
                }
                let verdicts = try filter.verdicts(store.verdicts, cache: &maskedTasks)
                // Newest first, so equal scores keep the most recent answers.
                let candidates = try filter.candidates(store.corrections).reversed().map { $0 }
                // One call: the longest groups that fit in the tokens left today.
                var batch = Array(pending.keys.prefix(GoalongWorkClassification.maximumContextsPerRequest))
                var request: GoalongWorkClassification.Request
                var prompt: String
                repeat {
                    let batchLabels = batch.compactMap { pending.labels[$0] }
                    let examples = GoalongWorkClassification.nearestExamples(candidates, for: batchLabels)
                    request = GoalongWorkClassification.request(date: dayName, definition: definition, pending: pending,
                        batch: batch, day: observation.day, verdicts: verdicts, knownTasks: knownTasks, examples: examples,
                        calendar: calendar, contextExcerpts: excerpts, dayNote: sharedNote)
                    prompt = GoalongWorkClassification.prompt(request, definition: sharedDefinition)
                    if GoalongWorkClassification.estimatedTokens(prompt: prompt, contexts: request.contexts.count)
                        <= GoalongWorkSchedule.remainingTokens(usage) || batch.count <= 1 { break }
                    batch.removeLast(max(1, batch.count / 4))
                } while true
                progress = "L’agent classe \(batch.count) groupe\(batch.count > 1 ? "s" : "") de contextes…"
                let privacyRevision = filter.policy.revision
                guard store.markAsked(batch, revision: revision, day: dayName) else { throw GoalongWorkClassification.Failure.invalid("La tentative n’a pas pu être enregistrée. Rien n’a été envoyé.") }
                let sentPrompt = prompt
                let result = try await Task.detached(priority: .userInitiated) {
                    let directory = try GoalongSiteAnalysisModel.makeWorkingDirectory()
                    defer { try? FileManager.default.removeItem(at: directory) }
                    return try session.generateWorkClassification(prompt: sentPrompt, privacyRevision: privacyRevision,
                                                                  selectionRevision: selectionRevision, workingDirectory: directory)
                }.value
                let after = await Task.detached(priority: .utility) { session.readAccountLimits() }.value
                // Counted even if the answer is refused below: the tokens were spent.
                let estimate = GoalongWorkClassification.estimatedTokens(prompt: sentPrompt, contexts: request.contexts.count)
                store.recordUsage(day: today, at: Date(), tokens: result.tokens ?? estimate, estimated: result.tokens == nil,
                                  background: !userInitiated, weeklyBefore: before?.weeklyPercent, weeklyAfter: after?.weeklyPercent)
                if let after { lastLimits = after }
                guard operation == id else { return }
                let assignments = try GoalongWorkClassification.apply(result.response, to: request)
                guard store.revision == revision else {
                    throw GoalongWorkClassification.Failure.invalid("La définition ou une autorisation a changé : classement arrêté.")
                }
                let applied = store.merge(assignments, revision: revision, day: dayName)
                var groups: [String: GoalongWorkAssignment] = [:]
                for key in request.keys.values {
                    guard let label = pending.labels[key], let assignment = assignments[key] else { continue }
                    groups[GoalongWorkContext.groupKey(label)] = assignment
                }
                store.mergeGroups(groups, revision: revision)
                let classified = applied.count + resolvedLocally
                let work = applied.values.filter { $0.verdict == .work }.count
                let rest = pending.keys.count - batch.count
                finish(id, outcome: "\(classified) contexte\(classified > 1 ? "s" : "") classé\(classified > 1 ? "s" : "") le \(GoalongUIFormat.day(start)), dont \(work) de travail."
                    + (rest > 0 ? " \(rest) autre\(rest > 1 ? "s" : "") groupe\(rest > 1 ? "s" : "") au prochain passage." : ""))
            } catch {
                guard operation == id else { return }
                runningDay = nil; progress = nil
                if !userInitiated, Self.isHomeBusy(error) { waiting = .codexBusy; return }
                SupportDiagnostics.shared.failure(error, component: .analysis)
                lastError = (error as? LocalizedError)?.errorDescription ?? "Le classement n’a pas abouti. Réessayez."
                // An expired session: show « non connecté » instead of the cached connected state.
                if case CodexAppServerError.signedOut = error { ChatGPTRecapRuntime.shared.refreshAccount() }
            }
        }
    }

    /// Runs a blocking job off the main actor and forwards a cancellation of the caller to it
    /// (a detached task does not inherit it, so its `shouldContinue` checks would never stop).
    nonisolated static func detachedForwardingCancellation<T: Sendable>(priority: TaskPriority,
                                                                         _ body: @escaping @Sendable () -> T) async -> T {
        let scan = Task.detached(priority: priority, operation: body)
        return await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
    }

    /// Builds a session off the main actor. A run that became stale or cancelled meanwhile closes it and gets nil.
    static func makeOffMain<S>(_ make: @escaping @Sendable () throws -> S, isStale: @MainActor () -> Bool,
                               close: (S) -> Void) async throws -> S? {
        let built = try await Task.detached(priority: .userInitiated) { UncheckedSendable(value: try make()) }.value
        if Task.isCancelled || isStale() { close(built.value); return nil }
        return built.value
    }

    func cancel() {
        operation = UUID(); task?.cancel(); session?.close(); session = nil
        runningDay = nil; progress = nil; rerunRequested = false
    }

    private func finish(_ id: UUID, outcome: String) {
        guard operation == id else { return }
        lastOutcome = outcome; lastRun = Date(); runningDay = nil; progress = nil
        runPendingRerun()
    }

    /// Starts the background pass asked for while another run was going, through the usual guards.
    private func runPendingRerun() {
        guard rerunRequested, !isRunning, !ChatGPTRecapRuntime.shared.isBusyWithCodex else { return }
        rerunRequested = false
        backgroundTick()
    }

    nonisolated static func isHomeBusy(_ error: Error) -> Bool {
        if case CodexAppServerError.homeBusy = error { return true }
        return false
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        GoalongSystemSourceFiles.dayKey(date, calendar: calendar)
    }
}
#endif
