#if os(macOS)
import Combine
import Foundation
import LocalHistoryCore
import SwiftUI

/// Lot B2 (T-049): what Activité says about the three states of the classification, the sheet « À préciser »
/// where the person answers one question at a time, and the texts both share. The engine (states, rules, usage)
/// is `GoalongWorkRules.swift`; nothing here decides a verdict by itself.

// MARK: - Status line

/// The line under the three states: last and next automatic pass, or why the pass waits, with the link that lifts it.
enum GoalongWorkPassLine {
    struct Line: Equatable {
        var text: String
        /// The title of the link that lifts the wait (it opens the definition and its settings); nil when it lifts by itself.
        var linkTitle: String?
    }

    static func line(isRunning: Bool, progress: String? = nil, waiting: GoalongWorkState.Waiting?, lastPass: Date?,
                     usageToday: GoalongWorkUsage.Day, pendingGroups: Int, now: Date,
                     margin: Int = GoalongWorkSchedule.minimumCallTokens, calendar: Calendar = .current) -> Line {
        if isRunning { return Line(text: progress ?? "Classement en cours…", linkTitle: nil) }
        if let waiting, waiting != .notYetPassed {
            return Line(text: waiting.message, linkTitle: link(for: waiting))
        }
        let last = lastPass.map { "Dernier passage : \(when($0, now: now, calendar: calendar))" } ?? "Pas encore de passage"
        return Line(text: last + " · Prochain passage : " + next(now: now, usageToday: usageToday, pendingGroups: pendingGroups,
                                                                  margin: margin, calendar: calendar), linkTitle: nil)
    }

    static func link(for waiting: GoalongWorkState.Waiting) -> String? {
        switch waiting {
        // The definition card already has « Écrire ma phrase »: one way in, not two for the same action.
        case .noDefinition: return nil
        case .noConsent: return "Autoriser l’envoi"
        case .notConnected: return "Connecter ChatGPT"
        case .historyOff: return "Voir les réglages"
        case .backgroundConsentMissing: return "Autoriser le classement automatique"
        case .notYetPassed, .paused, .dailyCapReached, .sharingBlocked, .accountLimitNear, .codexBusy: return nil
        }
    }

    /// « 12 h 30 », in the 24 h style of the app's French texts.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d h %02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd’hui à " + clock(date, calendar: calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "hier à " + clock(date, calendar: calendar)
        }
        return GoalongUIFormat.day(date) + " à " + clock(date, calendar: calendar)
    }

    /// The next time the background pass may call, from the same rules as `GoalongWorkSchedule.decide`.
    static func next(now: Date, usageToday: GoalongWorkUsage.Day, pendingGroups: Int,
                     margin: Int = GoalongWorkSchedule.minimumCallTokens, calendar: Calendar = .current) -> String {
        if pendingGroups == 0 { return "rien à classer pour l’instant" }
        let start = calendar.startOfDay(for: now)
        func slot(_ index: Int, on day: Date) -> Date? {
            calendar.date(bySettingHour: GoalongWorkSchedule.slots[index].hour, minute: GoalongWorkSchedule.slots[index].minute,
                          second: 0, of: day)
        }
        let capped = usageToday.backgroundCalls >= GoalongWorkSchedule.backgroundCallsPerDay
            || GoalongWorkSchedule.capReached(usageToday, margin: margin)
        if !capped {
            if pendingGroups >= GoalongWorkSchedule.backlogTrigger { return "au prochain contrôle (quelques minutes)" }
            let slots = GoalongWorkSchedule.slots.indices.compactMap { slot($0, on: start) }
            if let reached = slots.filter({ $0 <= now }).max(), (usageToday.lastCallAt ?? .distantPast) < reached {
                return "au prochain contrôle (quelques minutes)"
            }
            if let upcoming = slots.first(where: { $0 > now }) { return "vers " + clock(upcoming, calendar: calendar) }
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: start), let first = slot(0, on: tomorrow) else { return "demain" }
        return "demain vers " + clock(first, calendar: calendar)
    }
}

// MARK: - The three states of a period

/// The three states (and « trop court », shown apart) of the contexts of the days on screen, read on this Mac.
@MainActor final class GoalongWorkStateModel: ObservableObject {
    struct Question: Identifiable, Equatable {
        let id: String
        let label: GoalongWorkContext.Label
        let seconds: TimeInterval
        let reason: GoalongWorkState.Unclear
    }
    struct Snapshot: Equatable {
        var counts: [GoalongWorkState.Bucket: Int] = [:]
        var seconds: [GoalongWorkState.Bucket: TimeInterval] = [:]
        /// Everything to answer, longest first.
        var questions: [Question] = []
        /// Why the automatic pass cannot run now; nil when it can.
        var blocker: GoalongWorkState.Waiting?
        /// Groups the next pass would send.
        var pendingGroups = 0
        var dayCount = 1
        func count(_ bucket: GoalongWorkState.Bucket) -> Int { counts[bucket] ?? 0 }
    }

    /// A period longer than this reads its most recent days only: the figures name that scope.
    static let maximumDays = 7

    @Published private(set) var snapshot: Snapshot?
    init(snapshot: Snapshot? = nil) { self.snapshot = snapshot }
    #if DEBUG
    /// Test gallery only: the states are these, whatever the fixture's journals hold.
    static var galleryOverride: Snapshot?
    #endif
    private var operation = UUID()
    /// A newer load stops the reads of the older one.
    private var current: LoadToken?
    /// The one serial queue of the 7-day disk reads, shared with the pass of `GoalongWorkAgent` (T-049).
    static let readQueue = DispatchQueue(label: "goalong.work-states.read", qos: .utility)
    final class LoadToken: @unchecked Sendable {
        private let lock = NSLock(); private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
    private var request: (day: Date, period: Int)?
    /// Loads not finished yet (the test gallery waits for zero before a capture).
    private(set) static var loadsInFlight = 0

    /// The most recent days of a period, newest first.
    static func days(ending day: Date, period: Int, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: day)
        return (0..<max(1, min(period, maximumDays))).compactMap { calendar.date(byAdding: .day, value: -$0, to: start) }
    }

    /// Publishes only a real change, so a page that shows the states does not redraw for nothing.
    private func apply(_ new: Snapshot?) { if snapshot != new { snapshot = new } }

    func reload() { if let request { load(day: request.day, period: request.period) } }

    func load(day: Date, period: Int, store: GoalongWorkStore = .shared, agent: GoalongWorkAgent = .shared,
              root: URL = AppPaths.applicationSupportDirectory) {
        request = (day, period)
        #if DEBUG
        if let override = Self.galleryOverride { apply(override); return }
        #endif
        let id = UUID(); operation = id
        let days = Self.days(ending: day, period: period)
        current?.cancel()
        let token = LoadToken(); current = token
        Self.loadsInFlight += 1
        Task {
            defer { Self.loadsInFlight -= 1 }
            // Disk reads (observations, privacy policy, selection) stay off the main thread, on their own serial
            // queue: up to 7 days of reads never hold the shared task threads that a period click needs (T-049).
            let (observations, filter) = await withCheckedContinuation { continuation in
                Self.readQueue.async {
                    let observed = days.compactMap { GoalongWorkClassification.observe(root: root, day: $0, shouldContinue: { !token.isCancelled }) }
                    let filter = GoalongWorkSharingFilter(policy: GoalongPrivacyPolicy.load(in: root),
                                                          selection: GoalongAnalysisSelection.load(root: root))
                    continuation.resume(returning: (observed, filter))
                }
            }
            guard operation == id else { return }
            apply(Self.snapshot(observations: observations, verdicts: store.verdicts, groups: store.groupVerdicts,
                                permits: { filter.label($0) != nil }, blocker: agent.waitingReason(background: true, sharingBlocked: filter.policy.blocked),
                                dayCount: days.count))
        }
    }

    /// Pure: the states of several days merged by context. A context counts once, in the first state of this order:
    /// classified, to clarify, waiting, too short. Seconds add up per day.
    nonisolated static func snapshot(observations: [GoalongWorkClassification.Observation], verdicts: GoalongWorkVerdicts,
                                     groups: [String: GoalongWorkAssignment] = [:],
                                     permits: (GoalongWorkContext.Label) -> Bool = { _ in true },
                                     blocker: GoalongWorkState.Waiting?, dayCount: Int = 1) -> Snapshot {
        func rank(_ bucket: GoalongWorkState.Bucket) -> Int {
            switch bucket { case .classified: return 0; case .toClarify: return 1; case .waiting: return 2; case .tooShort: return 3 }
        }
        var finalState: [String: GoalongWorkState] = [:], labels: [String: GoalongWorkContext.Label] = [:]
        var secondsByKey: [String: TimeInterval] = [:]
        var result = Snapshot(blocker: blocker, dayCount: dayCount)
        var pending = Set<String>()
        for observation in observations {
            // A group already judged answers its new members without a call: they count as classified here too.
            let inherited = GoalongWorkClassification.inherited(labels: observation.labels, verdicts: verdicts, groups: groups)
            var withInherited = verdicts
            for (key, assignment) in inherited where withInherited.contexts[key] == nil { withInherited.contexts[key] = assignment }
            let summary = GoalongWorkClassification.states(day: observation.day, labels: observation.labels, verdicts: withInherited,
                                                           permits: permits, blocker: blocker)
            let seconds = GoalongWorkClassification.contextSeconds(observation.day)
            for (key, state) in summary.states {
                labels[key] = observation.labels[key]
                result.seconds[state.bucket, default: 0] += seconds[key] ?? 0
                secondsByKey[key, default: 0] += seconds[key] ?? 0
                if let known = finalState[key], rank(known.bucket) <= rank(state.bucket) { continue }
                finalState[key] = state
            }
            for (key, state) in summary.states {
                if case .waiting = state, let label = observation.labels[key] { pending.insert(GoalongWorkContext.groupKey(label)) }
            }
        }
        for (key, state) in finalState {
            result.counts[state.bucket, default: 0] += 1
            if case .toClarify(let reason) = state, let label = labels[key] {
                result.questions.append(Question(id: key, label: label, seconds: secondsByKey[key] ?? 0, reason: reason))
            }
        }
        result.questions.sort { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
        result.pendingGroups = pending.count
        return result
    }
}

// MARK: - Answers

/// What a person's answer writes. Context answers and rules go through the store's own entry points.
@MainActor enum GoalongWorkAnswering {
    struct Undo { let run: @MainActor () -> Void }

    /// The scopes the person may choose for a question; « site » only where the context has one.
    static func scopes(for label: GoalongWorkContext.Label) -> [GoalongWorkSource] {
        label.host?.isEmpty == false ? [.context, .application, .site] : [.context, .application]
    }

    static func scopeTitle(_ scope: GoalongWorkSource, label: GoalongWorkContext.Label) -> String {
        switch scope {
        case .context, .agent: return "Ce contexte seul"
        case .application: return "Toute l’app"
        case .site: return "Tout le site"
        }
    }

    /// One sentence under the scope choice: what the answer will cover.
    static func scopeHelp(_ scope: GoalongWorkSource, label: GoalongWorkContext.Label) -> String {
        switch scope {
        case .context, .agent: return "Seul ce contexte (même app, site et titre) est classé."
        case .application: return "Tout ce que vous faites dans \(label.application) est classé, sans nouvelle question."
        case .site: return "Toutes les pages de \(label.host ?? "ce site") sont classées, sans nouvelle question."
        }
    }

    /// Saves the answer and returns how to take it back.
    @discardableResult
    static func answer(_ question: GoalongWorkStateModel.Question, verdict: GoalongWorkVerdict, scope: GoalongWorkSource,
                       store: GoalongWorkStore = .shared, day: String) -> Undo? {
        guard verdict != .unclear else { return nil }
        let label = question.label
        switch scope {
        case .context, .agent:
            let previous = store.entry(for: question.id)
            store.correct(key: question.id, label: label, verdict: verdict, task: nil, day: day)
            return Undo {
                store.correct(key: question.id, label: label, verdict: nil, task: nil, day: day)
                if let previous, !previous.byOwner {
                    store.merge([question.id: GoalongWorkAssignment(verdict: previous.verdict, task: previous.task)],
                                revision: store.revision, day: previous.seen)
                }
            }
        case .application, .site:
            let target: String, name: String
            if scope == .site {
                guard let host = label.host, !host.isEmpty else { return nil }
                target = GoalongWorkRule.siteTarget(host); name = host
            } else {
                target = GoalongWorkRule.applicationTarget(application: label.application, bundleIdentifier: label.bundleIdentifier)
                name = label.application
            }
            let previous = store.rules.first { $0.scope == scope && $0.target == target }
            store.setRule(scope: scope, target: target, label: name, verdict: verdict, task: nil, day: day)
            return Undo {
                store.setRule(scope: scope, target: target, label: previous?.label ?? name,
                              verdict: previous?.assignment.verdict, task: previous?.assignment.task, day: previous?.day ?? day)
            }
        }
    }

    /// « Vos réponses »: the verdict of an existing answer, flipped or removed.
    static func change(_ rule: GoalongWorkRule, to verdict: GoalongWorkVerdict?, store: GoalongWorkStore = .shared, day: String) {
        switch rule.scope {
        case .application, .site:
            store.setRule(scope: rule.scope, target: rule.target, label: rule.label, verdict: verdict,
                          task: rule.assignment.task, day: day)
        case .context, .agent:
            let label = store.corrections.first { $0.key == rule.target }?.label
                ?? GoalongWorkContext.Label(application: rule.label.isEmpty ? "Contexte" : rule.label, bundleIdentifier: nil, host: nil, title: nil)
            store.correct(key: rule.target, label: label, verdict: verdict, task: verdict == .work ? rule.assignment.task : nil, day: day)
        }
    }
}

// MARK: - The sheet

/// « À préciser (N) » opens this sheet: one question at a time, the longest first.
@MainActor struct GoalongWorkClarifySheet: View {
    @ObservedObject var states: GoalongWorkStateModel
    @ObservedObject private var work = GoalongWorkStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var skipped: Set<String> = []
    /// Answered keys wait here until the states are read again, so a quick second click never answers twice.
    @State private var answered: Set<String> = []
    @State private var history: [(key: String, undo: GoalongWorkAnswering.Undo)] = []
    @State private var scope: GoalongWorkSource = .context
    @State private var initialTotal = 0
    @State private var editingDefinition = false

    private var questions: [GoalongWorkStateModel.Question] { (states.snapshot?.questions ?? []).filter { !answered.contains($0.id) } }
    private var current: GoalongWorkStateModel.Question? { questions.first { !skipped.contains($0.id) } }
    private var resolved: Int { max(0, max(initialTotal, questions.count) - questions.count) }
    private var total: Int { max(initialTotal, questions.count) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("À préciser").font(LHTheme.sheetTitleFont).accessibilityAddTraits(.isHeader)
                    Text("Le classement automatique n’a pas su trancher pour ces moments. Votre réponse sert ensuite à tous les contextes qu’elle couvre.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Terminé") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("clarify-done")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GoalongWorkDefinitionLine(onEdit: { editingDefinition.toggle() }, editing: editingDefinition)
                    if editingDefinition {
                        JevWorkContextControls(purpose: .workDefinition)
                        Button("Retour aux questions") { editingDefinition = false }.buttonStyle(LHSecondaryButtonStyle())
                    } else if let question = current {
                        questionView(question)
                    } else {
                        finished
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(24)
            }
        }
        .frame(width: 600, height: 560).background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .onAppear { states.reload(); if initialTotal == 0 { initialTotal = states.snapshot?.questions.count ?? 0 } }  // own layout: the sheet writes only its own state
        .onChange(of: states.snapshot) { snapshot in
            answered = answered.intersection(Set(snapshot?.questions.map(\.id) ?? []))
            initialTotal = max(initialTotal, snapshot?.questions.count ?? 0)
        }
        .onChange(of: work.verdicts) { _ in states.reload() }
        .accessibilityIdentifier("clarify-sheet")
    }

    private func questionView(_ question: GoalongWorkStateModel.Question) -> some View {
        let label = question.label
        let name = label.title ?? label.host ?? label.application
        let scopes = GoalongWorkAnswering.scopes(for: label)
        return VStack(alignment: .leading, spacing: 16) {
            progress
            VStack(alignment: .leading, spacing: 6) {
                Text("\(name) (\(GoalongAnalyticsFormatting.duration(question.seconds))) : est-ce du travail ?")
                    .font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clarify-question")
                Text(([label.application, label.host].compactMap { $0 }).joined(separator: ", ")
                     + (question.reason == .neverSent ? " · exclu de l’envoi : seule votre réponse peut le classer" : ""))
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Votre réponse vaut pour").font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                Picker("Portée", selection: $scope) {
                    ForEach(scopes, id: \.self) { Text(GoalongWorkAnswering.scopeTitle($0, label: label)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("clarify-scope")
                Text(GoalongWorkAnswering.scopeHelp(scopes.contains(scope) ? scope : .context, label: label))
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Travail") { answer(question, .work) }.buttonStyle(LHPrimaryButtonStyle()).accessibilityIdentifier("clarify-work")
                Button("Pas du travail") { answer(question, .other) }.buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("clarify-other")
                Button("Passer") { skipped.insert(question.id) }.buttonStyle(LHQuietButtonStyle()).accessibilityIdentifier("clarify-skip")
                Spacer(minLength: 0)
            }
            undoButton
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(resolved) sur \(total) précisé\(total > 1 ? "s" : "")").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(LHTheme.secondaryText).accessibilityIdentifier("clarify-progress")
            ProgressView(value: Double(resolved), total: Double(max(total, 1))).progressViewStyle(.linear).tint(LHTheme.accent)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var undoButton: some View {
        if !history.isEmpty {
            Button("Annuler la dernière réponse") {
                guard let last = history.popLast() else { return }
                last.undo.run(); answered.remove(last.key); skipped.remove(last.key)
            }.buttonStyle(LHQuietButtonStyle()).font(.system(size: 12)).accessibilityIdentifier("clarify-undo")
        }
    }

    @ViewBuilder private var finished: some View {
        VStack(alignment: .leading, spacing: 14) {
            if skipped.isEmpty || questions.isEmpty {
                GoalongEmptyState(title: "Rien d’autre à préciser", kind: .empty,
                                  message: "Tout ce que le classement automatique ne savait pas est répondu. Les nouveaux contextes seront classés au prochain passage.")
            } else {
                GoalongEmptyState(title: "Il reste \(skipped.count) question\(skipped.count > 1 ? "s" : "") passée\(skipped.count > 1 ? "s" : "")", kind: .empty,
                                  message: "Vous pouvez y répondre maintenant ou plus tard : elles restent dans « À préciser ».")
                Button("Revoir les questions passées") { skipped = [] }.buttonStyle(LHSecondaryButtonStyle())
            }
            undoButton
        }
    }

    private func answer(_ question: GoalongWorkStateModel.Question, _ verdict: GoalongWorkVerdict) {
        let chosen = GoalongWorkAnswering.scopes(for: question.label).contains(scope) ? scope : .context
        guard let undo = GoalongWorkAnswering.answer(question, verdict: verdict, scope: chosen,
                                                     day: GoalongWorkAgent.dayString(GoalongToday.now)) else { return }
        answered.insert(question.id)
        history.append((question.id, undo))
        scope = .context
        states.reload()
    }
}

/// « Pour vous, le travail c'est : … » with « Modifier »; empty, it invites to write it and says what waits for it.
@MainActor struct GoalongWorkDefinitionLine: View {
    var onEdit: () -> Void
    var editing = false
    @ObservedObject private var definition = JevWorkContextStore.shared

    var body: some View {
        GoalongWorkDefinitionText.view(sentence: GoalongWorkDefinitionText.sentence(definition.context),
                                       editTitle: editing ? "Fermer" : nil, onEdit: onEdit)
    }
}

enum GoalongWorkDefinitionText {
    /// The sentence the person wrote for what counts as work: its goals, else the apps or contents they named.
    static func sentence(_ context: JevWorkContext) -> String? {
        let value = [context.summary, context.applications, context.content].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let emptyHint = "Le classement automatique attend cette phrase."

    @MainActor @ViewBuilder static func view(sentence: String?, editTitle: String? = nil, onEdit: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let sentence {
                    (Text("Pour vous, le travail c’est : ").foregroundColor(LHTheme.secondaryText) + Text("« \(sentence) »").fontWeight(.medium))
                        .font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Pour vous, le travail c’est : pas encore écrit.").font(.system(size: 13, weight: .medium))
                    Text(emptyHint).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if sentence == nil {
                Button("Écrire ma phrase", action: onEdit).buttonStyle(LHPrimaryButtonStyle()).accessibilityIdentifier("activity-define-work")
            } else {
                Button(editTitle ?? "Modifier", action: onEdit).buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                    .accessibilityIdentifier("activity-definition-edit")
            }
        }
    }
}

// MARK: - Réglages: answers and usage

enum GoalongWorkUsageText {
    static func tokens(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "fr_FR"))).replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")
    }

    /// « 7 000 jetons (estimation) · 1 passage », the estimate marked as such.
    static func total(_ day: GoalongWorkUsage.Day) -> String {
        guard day.calls > 0 else { return "Aucun passage" }
        let estimate = day.isEstimate ? (day.estimatedCalls == day.calls ? " (estimation)" : " (dont une part estimée)") : ""
        return "\(tokens(day.tokens)) jetons\(estimate) · \(day.calls) passage\(day.calls > 1 ? "s" : "")"
    }

    /// The share of the weekly quota: before and after the last call when known, else the account's current share.
    static func quota(day: GoalongWorkUsage.Day, limits: GoalongAccountLimits?) -> String {
        if let before = day.weeklyPercentBefore, let after = day.weeklyPercentAfter {
            return before == after ? "\(GoalongUIFormat.percent(after)) du quota de la semaine utilisés au dernier passage"
                : "Quota de la semaine : \(GoalongUIFormat.percent(before)) avant le dernier passage, \(GoalongUIFormat.percent(after)) après"
        }
        if let weekly = limits?.weeklyPercent { return "\(GoalongUIFormat.percent(weekly)) du quota de la semaine utilisés" }
        return "Part du quota de la semaine : pas encore connue"
    }

    static var cap: String { "Plafond : \(tokens(GoalongWorkSchedule.dailyTokenCap)) jetons par jour, passage manuel compris" }

    static func scope(_ rule: GoalongWorkRule) -> String {
        switch rule.scope {
        case .context, .agent: return "Ce contexte seul"
        case .application: return "Toute l’app"
        case .site: return "Tout le site"
        }
    }

    static func answerTitle(_ rule: GoalongWorkRule) -> String {
        if !rule.label.isEmpty { return rule.label }
        return rule.scope == .context ? "Contexte (ancienne correction)" : rule.target
    }
}

/// Réglages › Définition du travail › « Vos réponses »: every answer, changeable and removable.
@MainActor struct GoalongWorkAnswersCard: View {
    @ObservedObject private var work = GoalongWorkStore.shared
    @State private var showsAll = false
    private static let preview = 8

    var body: some View {
        let answers = work.answers
        GoalongSettingsGroup(title: "Vos réponses") {
            if answers.isEmpty {
                Text("Aucune réponse pour l’instant. Quand le classement automatique ne sait pas, « À préciser » dans Activité vous pose la question.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Vos réponses priment toujours sur le classement automatique : la plus précise gagne (contexte, puis site, puis app).")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array((showsAll ? answers : Array(answers.prefix(Self.preview))).enumerated()), id: \.offset) { index, rule in
                        if index > 0 { Divider() }
                        row(rule)
                    }
                }
                if answers.count > Self.preview {
                    Button(showsAll ? "Réduire" : "Voir les \(answers.count) réponses") { showsAll.toggle() }
                        .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                }
            }
        }.accessibilityIdentifier("work-answers")
    }

    private func row(_ rule: GoalongWorkRule) -> some View {
        let isWork = rule.assignment.verdict == .work
        let day = GoalongWorkAgent.dayString(GoalongToday.now)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(GoalongWorkUsageText.answerTitle(rule)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text([GoalongWorkUsageText.scope(rule), rule.day.map { GoalongUIFormat.day(key: $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(title: isWork ? "Travail" : "Pas du travail", kind: .ready, symbol: isWork ? "briefcase" : "cup.and.saucer",
                       tint: isWork ? LHTheme.success : LHTheme.secondaryText)
            Menu {
                Button(isWork ? "Changer en « Pas du travail »" : "Changer en « Travail »") {
                    GoalongWorkAnswering.change(rule, to: isWork ? .other : .work, day: day)
                }
                Divider()
                Button("Supprimer cette réponse", role: .destructive) { GoalongWorkAnswering.change(rule, to: nil, day: day) }
            } label: { Text("Modifier").font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.text) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(LHTheme.text).fixedSize()
                .accessibilityLabel("Modifier la réponse pour \(GoalongWorkUsageText.answerTitle(rule))")
        }.padding(.vertical, 6)
    }
}

/// Réglages › Définition du travail › « Usage »: tokens of the day and of the week, share of the quota, cap.
@MainActor struct GoalongWorkUsageCard: View {
    @ObservedObject private var work = GoalongWorkStore.shared
    @ObservedObject private var agent = GoalongWorkAgent.shared

    var body: some View {
        let today = GoalongWorkAgent.dayString(GoalongToday.now)
        let day = work.usage.day(today), week = work.usage.week(endingOn: today)
        GoalongSettingsGroup(title: "Usage du classement") {
            VStack(alignment: .leading, spacing: 6) {
                line("Aujourd’hui", GoalongWorkUsageText.total(day))
                line("Cette semaine", GoalongWorkUsageText.total(week))
                Text(GoalongWorkUsageText.quota(day: day, limits: agent.lastLimits)).font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)
                Text(GoalongWorkUsageText.cap).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }.fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("work-usage")
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).frame(width: 110, alignment: .leading)
            Text(value).font(.system(size: 13)).monospacedDigit()
        }
    }
}
#endif
