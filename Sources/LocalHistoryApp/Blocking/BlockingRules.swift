#if os(macOS)
import AppKit
import Foundation

struct BlockingObservation: Equatable {
    var bundleIdentifier: String
    var pid: Int32
    var windowFrame: CGRect?
    var isBrowser: Bool
    /// Host and path only, or a browser internal-page identifier. Never query/credentials.
    var url: String?
    var privateWindow: Bool
    var at: Date
    var regular = true
    var sessionAvailable = true
    var idleSeconds: Double = 0
    var windowIdentity: Int = 0
    var windowBoundary: AXReadBoundary? = nil
    var addressFieldMarkers: [String]? = nil
    var isInternalPage = false
    var isForeground = true
    var isActivation = false
    /// Only configured, folded keywords, never the tab/window title itself.
    var titleKeywordMatches: Set<String> = []
    var privateWindowMarkers: [String]? = nil
}

struct BlockingMatchExplanation: Equatable {
    enum Reason: Equatable {
        case exempt, appRule, internalPage, exception(String), keyword(String, Source)
        case siteRule(String), unlistedSite, unlistedApp, unreadableURL, noMatch
    }
    enum Source: Equatable { case url, title }
    var blocked: Bool
    var reason: Reason
    var message: String {
        switch reason {
        case .exempt: return "Cette application est toujours autorisée."
        case .appRule: return "Cette application figure dans la liste."
        case .internalPage: return "Les pages internes du navigateur sont autorisées."
        case .exception(let rule): return "Exception de cette liste : \(rule)."
        case .keyword(let keyword, let source): return "Mot-clé « \(keyword) » dans \(source == .url ? "l’adresse" : "le titre de l’onglet")."
        case .siteRule(let rule): return "Règle de site de cette liste : \(rule)."
        case .unlistedSite: return "Ce site ne figure pas parmi les sites autorisés."
        case .unlistedApp: return "Cette application ne figure pas parmi les applications autorisées."
        case .unreadableURL: return "L’adresse n’est pas lisible ; la protection du navigateur est évaluée séparément."
        case .noMatch: return "Aucune règle de cette liste ne bloque cette cible."
        }
    }
}

enum BlockingRules {
    static let neverBlocked: Set<String> = [
        "ai.goalong.localhistory", "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.Spotlight", "com.apple.SecurityAgent", "com.apple.coreautha", "com.apple.ScreenSaver.Engine",
    ]
    /// Browsers the blocker knows even when it cannot read their address, so it fails closed on them.
    /// Apps that only show web content (Electron apps, Mail) are not browsers: app rules apply.
    static let otherBrowsers: Set<String> = [
        "company.thebrowser.Browser", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly", "io.gitlab.librewolf-community", "one.ablaze.floorp", "net.waterfox.waterfox",
        "org.torproject.torbrowser", "net.mullvad.mullvadbrowser", "com.operasoftware.Opera",
        "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser",
        "com.sigmaos.sigmaos.macos", "ru.yandex.desktop.yandex-browser", "org.chromium.Thorium",
    ]
    static func isKnownBrowser(_ bundleIdentifier: String?, configured: [String]) -> Bool {
        guard let id = bundleIdentifier, !id.isEmpty else { return false }
        return configured.contains(id) || otherBrowsers.contains(id)
    }

    static func exempt(_ target: BlockingObservation) -> Bool {
        !target.regular || neverBlocked.contains(target.bundleIdentifier)
            || target.pid == ProcessInfo.processInfo.processIdentifier
    }

    static func normalize(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0 == "\\" }) else { return nil }
        let full = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: full), ["http", "https"].contains(url.scheme),
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.contains("."), !host.contains(":"), !host.hasPrefix("["),
              !host.allSatisfy({ $0.isNumber || $0 == "." }), host.count <= 253,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }) else { return nil }
        var path = url.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    static func matches(_ rule: BlockSiteRule, url: String) -> Bool {
        guard let normalized = normalize(url), let pattern = normalize(rule.pattern) else { return false }
        let candidate = normalized.split(separator: "/", maxSplits: 1).map(String.init)
        let expected = pattern.split(separator: "/", maxSplits: 1).map(String.init)
        guard candidate[0] == expected[0] || candidate[0].hasSuffix("." + expected[0]) else { return false }
        guard expected.count == 2 else { return true }
        guard candidate.count == 2 else { return false }
        return candidate[1] == expected[1] || candidate[1].hasPrefix(expected[1] + "/")
    }

    static func normalizeKeyword(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
        return (2...40).contains(value.count) ? value : nil
    }

    static func foldKeyword(_ input: String) -> String {
        input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().precomposedStringWithCanonicalMapping
    }

    static func matchesKeyword(_ keyword: String, text: String) -> Bool {
        let words = foldKeyword(keyword).split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return false }
        let sequence = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[^\\p{L}\\p{N}]+")
        guard let expression = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + sequence + "(?![\\p{L}\\p{N}])") else { return false }
        let target = foldKeyword(text)
        return expression.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil
    }

    static func matchingTitleKeywords(_ keywords: [String], readTitle: () -> String?, privateWindow: Bool) -> Set<String> {
        guard !privateWindow, !keywords.isEmpty, let title = readTitle() else { return [] }
        return Set(keywords.filter { matchesKeyword($0, text: title) }.map(foldKeyword))
    }

    static func hasSites(_ list: BlockList) -> Bool { list.mode == .allowOnly || !list.sites.isEmpty || !(list.keywords ?? []).isEmpty }
    static func wouldBlock(_ target: BlockingObservation, list: BlockList) -> Bool {
        explain(target, list: list).blocked
    }

    /// Pure, per-list explanation; title is consumed only for this call and never returned.
    static func explain(_ target: BlockingObservation, list: BlockList, title: String? = nil) -> BlockingMatchExplanation {
        guard !exempt(target) else { return .init(blocked: false, reason: .exempt) }
        let appMatch = list.apps.contains { $0.bundleIdentifier == target.bundleIdentifier }
        if target.isBrowser {
            if list.mode == .block && appMatch { return .init(blocked: true, reason: .appRule) }
            if target.isInternalPage { return .init(blocked: false, reason: .internalPage) }
            let url = target.privateWindow ? nil : target.url.flatMap(normalize)
            if list.mode == .block, let url,
               let rule = list.exceptions?.first(where: { matches($0, url: url) }) {
                return .init(blocked: false, reason: .exception(rule.pattern))
            }
            if !target.privateWindow {
                for keyword in list.keywords ?? [] {
                    if let url, matchesKeyword(keyword, text: url) { return .init(blocked: true, reason: .keyword(keyword, .url)) }
                    if target.titleKeywordMatches.contains(foldKeyword(keyword)) || title.map({ matchesKeyword(keyword, text: $0) }) == true {
                        return .init(blocked: true, reason: .keyword(keyword, .title))
                    }
                }
            }
            guard let url else { return .init(blocked: false, reason: .unreadableURL) }
            if let rule = list.sites.first(where: { matches($0, url: url) }) {
                return .init(blocked: list.mode == .block, reason: .siteRule(rule.pattern))
            }
            return .init(blocked: list.mode == .allowOnly, reason: list.mode == .allowOnly ? .unlistedSite : .noMatch)
        }
        return .init(blocked: list.mode == .block ? appMatch : !appMatch, reason: appMatch ? .appRule : (list.mode == .allowOnly ? .unlistedApp : .noMatch))
    }

    static func explain(url: String?, title: String? = nil, list: BlockList) -> BlockingMatchExplanation {
        var target = BlockingObservation(bundleIdentifier: "", pid: -1, windowFrame: nil, isBrowser: true,
                                         url: url, privateWindow: false, at: .distantPast)
        let lower = url?.lowercased() ?? ""
        target.isInternalPage = lower.hasPrefix("about:") || lower.hasPrefix("favorites:")
            || lower.hasPrefix("chrome://newtab") || lower.hasPrefix("edge://newtab")
        return explain(target, list: list, title: title)
    }

    static func validate(_ document: BlockingDocument) -> Bool {
        guard document.version == 1, Set(document.lists.map(\.id)).count == document.lists.count,
              Set(document.sessions.map(\.id)).count == document.sessions.count else { return false }
        let rangeIDs = document.lists.flatMap { $0.program.ranges.map(\.id) }
        guard Set(rangeIDs).count == rangeIDs.count, Set(rangeIDs).isDisjoint(with: Set(document.sessions.map(\.id))) else { return false }
        for list in document.lists {
            guard !list.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  list.sites.allSatisfy({ normalize($0.pattern) != nil }),
                  (list.exceptions ?? []).allSatisfy({ normalize($0.pattern) == $0.pattern }),
                  (list.keywords ?? []).count <= 50,
                  (list.keywords ?? []).allSatisfy({ keyword in normalizeKeyword(keyword).map { $0.utf8.elementsEqual(keyword.utf8) } ?? false }),
                  Set((list.keywords ?? []).map(foldKeyword)).count == (list.keywords ?? []).count,
                  list.apps.allSatisfy({ !$0.bundleIdentifier.isEmpty }),
                  (3...60).contains(list.delaySeconds), (1...60).contains(list.allowanceMinutes),
                  list.quotaMinutesPerDay.map({ (1...720).contains($0) }) ?? true,
                  list.breaks.map({ (1...12).contains($0.count) && (1...30).contains($0.minutes) }) ?? true,
                  list.program.ranges.allSatisfy({ !$0.weekdays.isEmpty && $0.weekdays.isSubset(of: Set(1...7))
                    && (0...1440).contains($0.startMinute) && (0...1440).contains($0.endMinute) }) else { return false }
        }
        let ids = Set(document.lists.map(\.id))
        guard document.sessions.allSatisfy({ session in
            if case .commitment(let id) = session.origin, (session.lock != .locked || session.id != id) { return false }
            return session.start < session.end && !session.listIDs.isEmpty && Set(session.listIDs).isSubset(of: ids)
        }),
            document.usage?.quotaSecondsUsed.values.allSatisfy({ $0.isFinite && $0 >= 0 }) ?? true,
            document.usage?.breaksTaken.values.allSatisfy({ $0 >= 0 }) ?? true,
            [document.usage?.slowDownShown, document.usage?.renounced, document.usage?.continued].allSatisfy({ $0?.values.allSatisfy { $0 >= 0 } ?? true }),
            document.usageHistory.map({ $0.count <= 366 }) ?? true else { return false }
        if let freeze = document.freeze { return freeze.end > freeze.start }
        return true
    }
}

enum BlockingSchedule {
    struct Window { var rangeID: UUID; var start: Date; var end: Date }
    static func windows(of program: BlockProgram, at now: Date, calendar: Calendar = .current) -> [Window] {
        var result: [Window] = []
        for offset in -1...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            for range in program.ranges where range.weekdays.contains(isoWeekday(day, calendar: calendar)) {
                guard let start = minute(range.startMinute, on: day, calendar: calendar),
                      let endDay = calendar.date(byAdding: .day, value: range.crossesMidnight ? 1 : 0, to: day),
                      let end = minute(range.endMinute, on: endDay, calendar: calendar), end > start else { continue }
                result.append(Window(rangeID: range.id, start: start, end: end))
            }
        }
        return result.sorted { $0.start < $1.start }
    }
    private static func minute(_ value: Int, on day: Date, calendar: Calendar) -> Date? {
        if value == 1440 { return calendar.date(byAdding: .day, value: 1, to: day) }
        // Civil time, not 24-hour arithmetic: missing times advance; repeated times use first occurrence.
        return calendar.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: day,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    static func currentWindow(of program: BlockProgram, at now: Date, calendar: Calendar = .current) -> Window? {
        var merged: [Window] = []
        for window in windows(of: program, at: now, calendar: calendar) {
            if let last = merged.last, window.start <= last.end {
                merged[merged.count - 1].end = max(last.end, window.end)
            } else { merged.append(window) }
        }
        return merged.first { $0.start <= now && now < $0.end }
    }
    static func nextStart(of program: BlockProgram, after now: Date, calendar: Calendar = .current) -> Date? {
        windows(of: program, at: now, calendar: calendar).first { $0.start > now }?.start
    }
    static func isoWeekday(_ date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }
}
#endif
