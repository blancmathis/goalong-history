import Foundation

/// Where a verdict comes from. The user's answers are rules of three scopes; only the
/// agent can be wrong without the user having said anything.
public enum GoalongWorkSource: String, Codable, CaseIterable, Sendable {
    /// The user's answer for this one context (window title on an app or site).
    case context
    /// The user's rule for every context of an application.
    case application
    /// The user's rule for every page of a website.
    case site
    case agent
}

/// A rule written by the user. Goalong never creates one by itself: an application is
/// work only because the user said so.
public struct GoalongWorkRule: Codable, Equatable, Sendable {
    public let scope: GoalongWorkSource
    /// Context key, application target or site target.
    public let target: String
    /// What the user saw when answering: app name, host or title.
    public var label: String
    public var assignment: GoalongWorkAssignment
    /// Day of the answer (yyyy-MM-dd), for the list of answers.
    public var day: String?

    /// Nil for an unclear verdict or the agent scope: a rule always decides.
    public init?(scope: GoalongWorkSource, target: String, label: String, verdict: GoalongWorkVerdict,
                 task: String? = nil, day: String? = nil) {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard verdict != .unclear, scope != .agent, !target.isEmpty else { return nil }
        self.scope = scope
        switch scope {
        case .site: self.target = Self.siteTarget(target)
        case .application: self.target = target.lowercased()
        case .context, .agent: self.target = target
        }
        self.label = String(label.prefix(GoalongWorkContext.maximumTitleLength))
        self.assignment = GoalongWorkAssignment(verdict: verdict, task: task, byOwner: true)
        self.day = day
    }

    public static func applicationTarget(application: String, bundleIdentifier: String?) -> String {
        (bundleIdentifier?.isEmpty == false ? bundleIdentifier! : application).lowercased()
    }
    /// "www." is the same site.
    public static func siteTarget(_ host: String) -> String {
        let value = host.lowercased()
        return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
    }
}

/// App and site rules, ready to match a segment. Context answers live with the verdicts.
public struct GoalongWorkRules: Equatable, Sendable {
    public private(set) var applications: [String: GoalongWorkAssignment] = [:]
    public private(set) var sites: [String: GoalongWorkAssignment] = [:]
    public init() {}
    public init(_ rules: [GoalongWorkRule]) {
        for rule in rules {
            switch rule.scope {
            case .application: applications[rule.target] = rule.assignment
            case .site: sites[rule.target] = rule.assignment
            case .context, .agent: continue
            }
        }
    }
    public var isEmpty: Bool { applications.isEmpty && sites.isEmpty }

    /// A site is more precise than the browser that shows it.
    public func match(application: String?, bundleIdentifier: String?,
                      host: String?) -> (scope: GoalongWorkSource, assignment: GoalongWorkAssignment)? {
        if let host, !host.isEmpty, let rule = sites[GoalongWorkRule.siteTarget(host)] { return (.site, rule) }
        if let application, !application.isEmpty || bundleIdentifier?.isEmpty == false,
           let rule = applications[GoalongWorkRule.applicationTarget(application: application, bundleIdentifier: bundleIdentifier)] {
            return (.application, rule)
        }
        return nil
    }
}

extension GoalongWorkContext {
    /// Contexts whose titles differ only by counters, numbers or the app's own name are one
    /// group: the agent is asked once and its answer applies to every member.
    public static func groupKey(_ label: Label) -> String {
        "g" + Label(application: label.application, bundleIdentifier: label.bundleIdentifier, host: label.host,
                    title: groupTitle(label.title, application: label.application)).key
    }

    public static func groupTitle(_ raw: String?, application: String) -> String? {
        guard var text = displayTitle(raw)?.lowercased() else { return nil }
        let app = application.lowercased()
        for separator in [" - ", " — ", " – ", " | ", " · "] where !app.isEmpty && text.hasSuffix(separator + app) {
            text.removeLast((separator + app).count)
        }
        var folded = ""
        for character in text {
            if character.isNumber { if folded.last != "#" { folded.append("#") } } else { folded.append(character) }
        }
        let value = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—|·:()[]#"))
        return value.isEmpty ? nil : value
    }
}

extension GoalongWorkContext {
    /// Apps and sites whose page stays the same while what is written in it changes: AI chats, messaging, mail.
    /// Their app, site or title never says whether a moment is work (T-055).
    static let contentVaryingHosts: Set<String> = [
        "chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "perplexity.ai", "copilot.microsoft.com",
        "chat.mistral.ai", "chat.deepseek.com", "poe.com", "grok.com", "mail.google.com", "outlook.live.com",
        "outlook.office.com", "outlook.office365.com", "web.whatsapp.com", "web.telegram.org", "discord.com",
        "app.slack.com", "messenger.com", "teams.microsoft.com", "teams.live.com",
    ]
    static let contentVaryingBundles: Set<String> = [
        "com.openai.chat", "com.anthropic.claudefordesktop", "com.google.gemini", "ai.perplexity.mac",
        "com.tinyspeck.slackmacgap", "com.apple.mobilesms", "net.whatsapp.whatsapp", "desktop.whatsapp",
        "com.hnc.discord", "ru.keepcoder.telegram", "org.telegram.desktop", "com.facebook.archon",
        "com.apple.mail", "com.microsoft.outlook", "com.microsoft.teams2", "com.microsoft.teams", "com.readdle.smartemail-mac",
    ]
    /// Words that name no content: a home page, a new chat, an empty document.
    static let genericTitleWords: Set<String> = [
        "home", "accueil", "new chat", "nouveau chat", "nouvelle discussion", "nouvelle conversation", "new conversation",
        "untitled", "sans titre", "untitled document", "document sans titre", "new document", "nouveau document",
        "new tab", "nouvel onglet", "inbox", "boîte de réception", "messages", "chats", "discussions", "start page",
        "page de démarrage", "dashboard", "tableau de bord", "search", "recherche", "page d’accueil", "page d'accueil",
        "welcome", "bienvenue", "settings", "réglages", "paramètres", "preferences", "préférences", "explore", "explorer",
        "untitled document", "nouvelle page", "new page", "for you", "pour vous", "feed", "fil d’actualité",
    ]

    /// True when the title names nothing the user did: empty once the app and site names are taken out, or a home,
    /// a new chat, an untitled document… A nil title (no window seen) is not generic: it names the app.
    public static func isGenericTitle(_ label: Label) -> Bool {
        // Counters and numbers name nothing either (« (3) Home / X », « Untitled-1 »): start from the group title.
        guard displayTitle(label.title) != nil else { return false }
        let title = groupTitle(label.title, application: label.application) ?? ""
        var brands = Set(label.application.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if let host = label.host?.lowercased() {
            // « docs.google.com » names « docs » and « google »; the last label (« com ») names nothing.
            brands.formUnion(host.split(separator: ".").dropLast().map(String.init))
        }
        let words = title.split(whereSeparator: { $0.isWhitespace || "-–—|·:•()[]#/".contains($0) }).map(String.init)
            .filter { !brands.contains($0) }
        let rest = words.joined(separator: " ")
        return rest.isEmpty || genericTitleWords.contains(rest)
    }

    /// The content changes while the context stays the same: an AI chat, messaging or mail, or any page whose title
    /// names nothing (« ChatGPT Home », « Sans titre »). One answer for the whole context would classify every moment
    /// alike, so these are never asked to the user: the classification judges them on what is visible (T-055).
    public static func variesWithContent(_ label: Label) -> Bool {
        if let bundle = label.bundleIdentifier?.lowercased(), contentVaryingBundles.contains(bundle) { return true }
        if let host = label.host?.lowercased() {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if contentVaryingHosts.contains(bare) { return true }
        }
        return isGenericTitle(label)
    }
}

/// What the user sees for one context. Computed in one place for every screen.
public enum GoalongWorkState: Equatable, Hashable, Sendable {
    public enum Waiting: String, CaseIterable, Sendable {
        /// The agent has not run on it yet.
        case notYetPassed
        /// Its content changes (AI chat, messaging, untitled page): judged on what is visible, never asked (T-055).
        case judgedByContent
        case noDefinition, historyOff, noConsent, notConnected, paused
        case dailyCapReached
        /// Background passes need their own consent.
        case backgroundConsentMissing
        /// The exclusions block every text analysis.
        case sharingBlocked
        case accountLimitNear
        case codexBusy

        public var message: String {
            switch self {
            case .notYetPassed: "Pas encore classé : le prochain passage s’en chargera."
            case .judgedByContent: "Le contenu change : le prochain passage le juge sur le texte visible, pas sur le titre."
            case .noDefinition: "Écrivez d’abord ce qui compte comme du travail."
            case .historyOff: "L’historique est arrêté."
            case .noConsent: "L’envoi à ChatGPT n’est pas autorisé."
            case .notConnected: "ChatGPT n’est pas connecté."
            case .paused: "Goalong est en pause."
            case .dailyCapReached: "Limite du jour atteinte : la suite passera demain."
            case .backgroundConsentMissing: "Le classement en arrière-plan n’est pas autorisé."
            case .sharingBlocked: "Les exclusions bloquent l’envoi de texte."
            case .accountLimitNear: "Le compte ChatGPT approche de sa limite d’usage."
            case .codexBusy: "Codex est occupé : le classement attendra."
            }
        }
    }
    public enum Unclear: String, CaseIterable, Sendable {
        /// The agent could not decide.
        case agentUnsure
        /// Excluded from sharing and covered by no rule: only the user can answer.
        case neverSent
        /// Its content changes, but the classification cannot read it (visible text not shared, or no try left):
        /// only the user can say what that moment was (T-055).
        case contentUnseen
    }
    case classified(GoalongWorkVerdict, GoalongWorkSource)
    case waiting(Waiting)
    case toClarify(Unclear)
    /// Under 15 s, its group too, and no rule: neither sent nor counted as « à préciser ».
    case tooShort

    public enum Bucket: String, CaseIterable, Sendable { case classified, waiting, toClarify, tooShort }
    public var bucket: Bucket {
        switch self {
        case .classified: .classified
        case .waiting: .waiting
        case .toClarify: .toClarify
        case .tooShort: .tooShort
        }
    }
}

extension GoalongWorkClassification {
    public struct StateSummary: Equatable, Sendable {
        public var states: [String: GoalongWorkState] = [:]
        public var seconds: [GoalongWorkState.Bucket: TimeInterval] = [:]
        public var counts: [GoalongWorkState.Bucket: Int] = [:]
        public func count(_ bucket: GoalongWorkState.Bucket) -> Int { counts[bucket] ?? 0 }
    }

    /// One state per labelled context of the day. `blocker` is why the agent cannot run
    /// now (nil when it can and simply has not yet).
    /// `permitsContent`: the visible text of the context may be sent (nil: as `permits`).
    public static func states(day: GoalongLocalAnalytics.Day, labels: [String: GoalongWorkContext.Label],
                              verdicts: GoalongWorkVerdicts, permits: (GoalongWorkContext.Label) -> Bool = { _ in true },
                              permitsContent: ((GoalongWorkContext.Label) -> Bool)? = nil,
                              blocker: GoalongWorkState.Waiting? = nil) -> StateSummary {
        let seconds = contextSeconds(day)
        var groupSeconds: [String: TimeInterval] = [:]
        for (key, value) in seconds { if let label = labels[key] { groupSeconds[GoalongWorkContext.groupKey(label), default: 0] += value } }
        var summary = StateSummary()
        for (key, value) in seconds {
            guard let label = labels[key] else { continue }
            let state: GoalongWorkState
            // A context whose content changes is judged on what is visible in it (T-055). Left unsure, it waits only
            // while the next pass can still read it; otherwise the user is asked about it, never left silent.
            // Tested only where it changes the state: the view switches compute this for every context.
            let varies = GoalongWorkContext.variesWithContent(label)
            if let resolution = verdicts.resolution(key: key, label: label, varies: varies) {
                if resolution.assignment.verdict != .unclear {
                    state = .classified(resolution.assignment.verdict, resolution.source)
                } else if !varies {
                    state = .toClarify(.agentUnsure)
                } else {
                    let retry = verdicts.retries[key] ?? GoalongWorkRetryState()
                    let readable = permits(label) && (permitsContent.map { $0(label) } ?? true)
                    state = readable && retry.attempts < 3 && value >= 300 ? .waiting(.judgedByContent) : .toClarify(.contentUnseen)
                }
            } else if !permits(label) {
                state = .toClarify(.neverSent)
            } else if (groupSeconds[GoalongWorkContext.groupKey(label)] ?? 0) < minimumContextSeconds {
                state = .tooShort
            } else {
                state = .waiting(blocker ?? .notYetPassed)
            }
            summary.states[key] = state
            summary.seconds[state.bucket, default: 0] += value
            summary.counts[state.bucket, default: 0] += 1
        }
        return summary
    }

    /// Agent verdicts known for a group, given to every member not answered yet, without
    /// a call. Returns only the new assignments.
    public static func inherited(labels: [String: GoalongWorkContext.Label], verdicts: GoalongWorkVerdicts,
                                 groups: [String: GoalongWorkAssignment]) -> [String: GoalongWorkAssignment] {
        guard !groups.isEmpty else { return [:] }
        var result: [String: GoalongWorkAssignment] = [:]
        // A page whose content changes is judged moment by moment: a verdict on another member says nothing (T-055).
        for (key, label) in labels where !GoalongWorkContext.variesWithContent(label) && verdicts.resolution(key: key, label: label) == nil {
            if let known = groups[GoalongWorkContext.groupKey(label)] { result[key] = known }
        }
        return result
    }
}

/// When the background pass may call the agent. Pure, so the rhythm is tested.
public enum GoalongWorkSchedule {
    public static let backgroundCallsPerDay = 2
    public static let dailyTokenCap = 24_000
    /// Below this many tokens left, no call fits.
    public static let minimumCallTokens = 5_000
    public static let backlogTrigger = 40
    public static let slots: [(hour: Int, minute: Int)] = [(12, 30), (18, 30)]

    public enum Trigger: String, Equatable, Sendable { case backlog, slot, manual }
    public enum Decision: Equatable, Sendable {
        case call(Trigger)
        /// Nil: nothing to do or not time yet, without a problem to show.
        case skip(GoalongWorkState.Waiting?)
    }

    /// `margin`: the tokens one call is expected to use (`callMargin`), so the real count stays under the cap.
    public static func decide(now: Date, pendingGroups: Int, usage: GoalongWorkUsage.Day, manual: Bool,
                              margin: Int = minimumCallTokens, calendar: Calendar = .current) -> Decision {
        guard pendingGroups > 0 else { return .skip(nil) }
        guard !capReached(usage, margin: margin) else { return .skip(.dailyCapReached) }
        if manual { return .call(.manual) }
        guard usage.backgroundCalls < backgroundCallsPerDay else { return .skip(.dailyCapReached) }
        if pendingGroups >= backlogTrigger { return .call(.backlog) }
        let start = calendar.startOfDay(for: now)
        let reached = slots.compactMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: start) }
            .filter { $0 <= now }.max()
        if let reached, (usage.lastCallAt ?? .distantPast) < reached { return .call(.slot) }
        return .skip(nil)
    }

    /// Tokens left today for one call.
    public static func remainingTokens(_ usage: GoalongWorkUsage.Day) -> Int { max(0, dailyTokenCap - usage.tokens) }

    /// True when no further call fits today: the real (or estimated) tokens plus one call's margin pass the cap.
    public static func capReached(_ usage: GoalongWorkUsage.Day, margin: Int = minimumCallTokens) -> Bool {
        usage.tokens + max(minimumCallTokens, margin) > dailyTokenCap
    }

    /// Room kept for one call: the mean of the calls Codex measured (the week given), never below `minimumCallTokens`.
    public static func callMargin(_ week: GoalongWorkUsage.Day) -> Int {
        guard week.measuredCalls > 0 else { return minimumCallTokens }
        return max(minimumCallTokens, (week.measuredTokens + week.measuredCalls - 1) / week.measuredCalls)
    }

    /// Days a pass looks at: the last `passDays` days ending on `now`, oldest first, so contexts left
    /// waiting on a past day are classified before today's.
    public static let passDays = 7
    public static func days(endingOn now: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: now)
        return (0..<passDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: start) }
    }

    /// The day the one call of a pass goes to: the oldest with pending groups. `pending` is oldest first.
    public static func target<Day>(_ pending: [(day: Day, groups: Int)]) -> Day? {
        pending.first { $0.groups > 0 }?.day
    }
}

/// Calls and tokens of the classification, kept on the Mac (14 days).
public struct GoalongWorkUsage: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var calls = 0
        public var backgroundCalls = 0
        public var tokens = 0
        /// Calls whose tokens Codex did not report: their count is an estimate.
        public var estimatedCalls = 0
        public var lastCallAt: Date?
        /// Weekly share of the account used, in percent, before and after the last call.
        public var weeklyPercentBefore: Int?
        public var weeklyPercentAfter: Int?
        /// Calls whose tokens Codex reported, and those tokens: the mean sets the margin of the cap.
        public var measuredCalls = 0
        public var measuredTokens = 0
        public init() {}
        public var isEstimate: Bool { estimatedCalls > 0 }

        private enum CodingKeys: String, CodingKey {
            case calls, backgroundCalls, tokens, estimatedCalls, lastCallAt, weeklyPercentBefore, weeklyPercentAfter
            case measuredCalls, measuredTokens
        }
        /// A file written before a field existed still loads, with its counts kept.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
            backgroundCalls = try c.decodeIfPresent(Int.self, forKey: .backgroundCalls) ?? 0
            tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
            estimatedCalls = try c.decodeIfPresent(Int.self, forKey: .estimatedCalls) ?? 0
            lastCallAt = try c.decodeIfPresent(Date.self, forKey: .lastCallAt)
            weeklyPercentBefore = try c.decodeIfPresent(Int.self, forKey: .weeklyPercentBefore)
            weeklyPercentAfter = try c.decodeIfPresent(Int.self, forKey: .weeklyPercentAfter)
            measuredCalls = try c.decodeIfPresent(Int.self, forKey: .measuredCalls) ?? 0
            measuredTokens = try c.decodeIfPresent(Int.self, forKey: .measuredTokens) ?? 0
        }
    }
    public static let keptDays = 14
    public var days: [String: Day] = [:]
    public init() {}

    public func day(_ key: String) -> Day { days[key] ?? Day() }

    public mutating func record(day key: String, at date: Date, tokens: Int, estimated: Bool, background: Bool,
                                weeklyBefore: Int? = nil, weeklyAfter: Int? = nil) {
        var value = day(key)
        value.calls += 1
        if background { value.backgroundCalls += 1 }
        value.tokens += max(0, tokens)
        if estimated { value.estimatedCalls += 1 } else { value.measuredCalls += 1; value.measuredTokens += max(0, tokens) }
        value.lastCallAt = date
        // The pair describes the last call only: an older « after » must not stand beside a new « before ».
        value.weeklyPercentBefore = weeklyBefore
        value.weeklyPercentAfter = weeklyAfter
        days[key] = value
        let kept = Set(days.keys.sorted().suffix(Self.keptDays))
        days = days.filter { kept.contains($0.key) }
    }

    /// Replaces the estimate counted when a call was sent by the tokens Codex reported, once the answer came.
    /// A call that failed keeps its estimate: it still counts.
    public mutating func settle(day key: String, estimate: Int, tokens: Int?, weeklyAfter: Int?) {
        guard var value = days[key] else { return }
        if let tokens {
            value.tokens = max(0, value.tokens - max(0, estimate) + max(0, tokens))
            value.estimatedCalls = max(0, value.estimatedCalls - 1)
            value.measuredCalls += 1; value.measuredTokens += max(0, tokens)
        }
        value.weeklyPercentAfter = weeklyAfter ?? value.weeklyPercentAfter
        days[key] = value
    }

    /// The seven days ending on `key` (yyyy-MM-dd).
    public func week(endingOn key: String, calendar: Calendar = .current) -> Day {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        guard let end = GoalongDayParser.date(key, timeZone: calendar.timeZone) else { return day(key) }
        var total = Day()
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            let value = day(formatter.string(from: date))
            total.calls += value.calls; total.backgroundCalls += value.backgroundCalls
            total.tokens += value.tokens; total.estimatedCalls += value.estimatedCalls
            total.measuredCalls += value.measuredCalls; total.measuredTokens += value.measuredTokens
            if let last = value.lastCallAt, (total.lastCallAt ?? .distantPast) < last { total.lastCallAt = last }
        }
        return total
    }
}

/// What the ChatGPT account says about its own limits, read without inference.
public struct GoalongAccountLimits: Equatable, Sendable {
    /// Share of the short window used (percent).
    public var primaryPercent: Int?
    /// Share of the weekly window used (percent).
    public var weeklyPercent: Int?
    /// Codex reports that a limit is reached.
    public var reached: Bool
    public init(primaryPercent: Int? = nil, weeklyPercent: Int? = nil, reached: Bool = false) {
        self.primaryPercent = primaryPercent; self.weeklyPercent = weeklyPercent; self.reached = reached
    }
    public static let nearPercent = 90
    public var isNear: Bool {
        reached || (primaryPercent ?? 0) >= Self.nearPercent || (weeklyPercent ?? 0) >= Self.nearPercent
    }
}
