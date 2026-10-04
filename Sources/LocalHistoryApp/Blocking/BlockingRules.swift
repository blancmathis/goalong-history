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
    var isInternalPage = false
    var isForeground = true
    var isActivation = false
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

    static func hasSites(_ list: BlockList) -> Bool { list.mode == .allowOnly || !list.sites.isEmpty }
    static func wouldBlock(_ target: BlockingObservation, list: BlockList) -> Bool {
        guard !exempt(target) else { return false }
        let appMatch = list.apps.contains { $0.bundleIdentifier == target.bundleIdentifier }
        if target.isBrowser {
            if list.mode == .block && appMatch { return true }
            if target.isInternalPage { return false }
            guard let url = target.url else { return false }
            let siteMatch = list.sites.contains { matches($0, url: url) }
            return list.mode == .block ? siteMatch : !siteMatch
        }
        return list.mode == .block ? appMatch : !appMatch
    }

    static func validate(_ document: BlockingDocument) -> Bool {
        guard document.version == 1, Set(document.lists.map(\.id)).count == document.lists.count,
              Set(document.sessions.map(\.id)).count == document.sessions.count else { return false }
        for list in document.lists {
            guard !list.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  list.sites.allSatisfy({ normalize($0.pattern) != nil }),
                  list.apps.allSatisfy({ !$0.bundleIdentifier.isEmpty }),
                  (3...60).contains(list.delaySeconds), (1...60).contains(list.allowanceMinutes),
                  list.quotaMinutesPerDay.map({ (1...720).contains($0) }) ?? true,
                  list.breaks.map({ (1...12).contains($0.count) && (1...30).contains($0.minutes) }) ?? true,
                  list.program.ranges.allSatisfy({ !$0.weekdays.isEmpty && $0.weekdays.isSubset(of: Set(1...7))
                    && (0...1440).contains($0.startMinute) && (0...1440).contains($0.endMinute) }) else { return false }
        }
        let ids = Set(document.lists.map(\.id))
        guard document.sessions.allSatisfy({ $0.start < $0.end && !$0.listIDs.isEmpty
            && Set($0.listIDs).isSubset(of: ids) }),
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
