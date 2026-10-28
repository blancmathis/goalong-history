#if os(macOS)
import Foundation

/// French wording shared by the page, the veils and the shield.
enum BlockingFormat {
    private static let locale = Locale(identifier: "fr_FR")

    /// Blocks started by a trigger app have no end of their own.
    static func isOpenEnded(_ end: Date) -> Bool { end.timeIntervalSinceReferenceDate > GoalongToday.now.timeIntervalSinceReferenceDate + 400 * 86_400 }

    static func time(_ date: Date) -> String {
        GoalongUIFormat.time(date)
    }

    /// An end at 00:00 reads « minuit », so an all-day block is not shown as « 00:00 → 00:00 ».
    static func endTime(_ date: Date) -> String {
        let value = time(date)
        return value == "00:00" ? "minuit" : value
    }

    /// Quota bonus earned by focusing: « +1 min de pause gagnée en concentration ».
    static func earnedBreak(minutes: Int) -> String {
        "+\(minutes) min de pause \(minutes > 1 ? "gagnées" : "gagnée") en concentration"
    }

    static func minuteOfDay(_ minute: Int) -> String {
        let value = ((minute % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// « 1 h 24 », « 24 min », « moins d’une minute ».
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "moins d’une minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours >= 24 {
            // « 1 jour », « 1 jour 3 h », « 1 jour 3 h 40 », « 2 jours 40 min »: never « 0 h », never a lost minute.
            let days = hours / 24, left = minutes - days * 1_440
            let head = GoalongUIFormat.count(days, "jour")
            return left == 0 ? head : "\(head) \(duration(minutes: left))"
        }
        return DashboardFormatters.duration(minutes: minutes)
    }

    static func duration(minutes: Int) -> String {
        DashboardFormatters.duration(minutes: minutes)
    }

    /// « aujourd’hui à 14:00 », « demain à 9:00 », « lundi à 9:00 », « le 31 oct. à 9:00 ».
    static func moment(_ date: Date, now: Date = GoalongToday.now, calendar: Calendar = .current) -> String {
        "\(dayWord(date, now: now, calendar: calendar)) à \(time(date))"
    }

    /// The end of a block, with its day when it is not today: « 12:00 », « minuit », « demain à 2:00 »,
    /// « samedi à 12:00 », « vendredi à minuit », « le 31 oct. à 12:00 ». A 0:00 end belongs to the day before.
    static func deadline(_ date: Date, now: Date = GoalongToday.now, calendar: Calendar = .current) -> String {
        let (day, value) = endParts(date, calendar: calendar)
        if calendar.isDate(day, inSameDayAs: now) { return value }
        return "\(dayWord(day, now: now, calendar: calendar)) à \(value)"
    }

    /// « jusqu’à 12:00 », « jusqu’à demain à 2:00 », « jusqu’au 31 oct. à 12:00 ».
    static func until(_ date: Date, now: Date = GoalongToday.now, calendar: Calendar = .current) -> String {
        untilPhrase(deadline(date, now: now, calendar: calendar))
    }

    /// Puts « jusqu’à » before a moment, contracted to « jusqu’au » before « le 31 oct. ».
    static func untilPhrase(_ moment: String) -> String {
        moment.hasPrefix("le ") ? "jusqu’au \(moment.dropFirst(3))" : "jusqu’à \(moment)"
    }

    /// A block that starts later: « samedi de 10:00 à 12:00 », « le 31 oct. de 10:00 à 12:00 »,
    /// « d’aujourd’hui 22:00 à demain 2:00 », « du 31 oct. 22:00 au 1er nov. 2:00 ».
    static func period(from start: Date, to end: Date, now: Date = GoalongToday.now, calendar: Calendar = .current) -> String {
        let (endDay, endValue) = endParts(end, calendar: calendar)
        let first = dayWord(start, now: now, calendar: calendar)
        if calendar.isDate(start, inSameDayAs: endDay) { return "\(first) de \(time(start)) à \(endValue)" }
        let last = dayWord(endDay, now: now, calendar: calendar)
        let from = first == "aujourd’hui" ? "d’aujourd’hui" : (first.hasPrefix("le ") ? "du \(first.dropFirst(3))" : "de \(first)")
        let to = last.hasPrefix("le ") ? "au \(last.dropFirst(3))" : "à \(last)"
        return "\(from) \(time(start)) \(to) \(endValue)"
    }

    /// The day an end belongs to and its time: 0:00 reads « minuit » of the day before.
    private static func endParts(_ date: Date, calendar: Calendar) -> (Date, String) {
        calendar.startOfDay(for: date) == date ? (date.addingTimeInterval(-1), "minuit") : (date, time(date))
    }

    /// « aujourd’hui », « demain », « lundi » within a week, else « le 31 oct. », « le 1er nov. ».
    private static func dayWord(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd’hui" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "demain"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days < 7 {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        formatter.dateFormat = "MMM"
        let day = calendar.component(.day, from: date)
        return "le \(day == 1 ? "1er" : String(day)) \(formatter.string(from: date))"
    }

    /// The end of a week range: 1 440 reads « 24:00 », as in the range's tooltip.
    static func rangeEnd(_ minute: Int) -> String { minute == 1_440 ? "24:00" : minuteOfDay(minute) }

    /// VoiceOver label of a range in the week: « Vidéo, lundi, 22:00 à 24:00, verrouillé ».
    static func rangeLabel(name: String, weekday: Int, start: Int, end: Int, lock: BlockLock) -> String {
        let days = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
        let day = (1...7).contains(weekday) ? "\(days[weekday - 1]), " : ""
        let protection: String
        switch lock {
        case .free: protection = ""
        case .typing: protection = ", difficile à arrêter"
        case .password: protection = ", protégé par mot de passe"
        case .locked: protection = ", verrouillé"
        }
        return "\(name), \(day)\(minuteOfDay(start)) à \(rangeEnd(end))\(protection)"
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: date)
    }

    /// Two letters, so Tuesday and Wednesday no longer both read « M ».
    static let weekdayLetters = ["Lu", "Ma", "Me", "Je", "Ve", "Sa", "Di"]
    static let weekdayShort = ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"]

    /// « Tous les jours », « Lun–ven », « Sam, dim », « Lun, mer, ven ».
    static func weekdays(_ days: Set<Int>) -> String {
        let sorted = days.sorted()
        if sorted == Array(1...7) { return "Tous les jours" }
        if sorted == Array(1...5) { return "Lun–ven" }
        if sorted == [6, 7] { return "Sam, dim" }
        if sorted.count >= 3, sorted.last! - sorted.first! == sorted.count - 1 {
            return "\(weekdayShort[sorted.first! - 1])–\(weekdayShort[sorted.last! - 1].lowercased())"
        }
        return sorted.enumerated().map { index, day in
            index == 0 ? weekdayShort[day - 1] : weekdayShort[day - 1].lowercased()
        }.joined(separator: ", ")
    }

    static func range(_ range: BlockProgramRange) -> String {
        if range.startMinute == 0 && range.endMinute == 1_440 { return "toute la journée" }
        return "\(minuteOfDay(range.startMinute)) → \(rangeEnd(range.endMinute))\(range.crossesMidnight && range.endMinute != 0 ? " le lendemain" : "")"
    }

    /// One line for a list row: what it holds, when, how much.
    static func summary(_ list: BlockList) -> String {
        var parts: [String] = []
        let sites = list.sites.count, apps = list.apps.count
        let content = [sites > 0 ? (sites == 1 ? "1 site" : "\(sites) sites") : nil,
                       apps > 0 ? (apps == 1 ? "1 app" : "\(apps) apps") : nil].compactMap { $0 }
        if list.mode == .allowOnly {
            parts.append(content.isEmpty ? "Tout bloquer" : "Tout sauf " + content.joined(separator: " et "))
        } else {
            parts.append(content.isEmpty ? "Vide" : content.joined(separator: ", "))
        }
        if let first = list.program.ranges.first {
            let more = list.program.ranges.count > 1 ? " +\(list.program.ranges.count - 1)" : ""
            parts.append("\(weekdays(first.weekdays)) \(range(first))\(more)")
        }
        if list.effectiveAction == .slowDown { parts.append("ralentir \(list.delaySeconds) s") }
        if let quota = list.quotaMinutesPerDay { parts.append("\(duration(minutes: quota)) par jour") }
        if let breaks = list.breaks { parts.append("\(breaks.count) pause\(breaks.count > 1 ? "s" : "") de \(breaks.minutes) min") }
        return parts.joined(separator: " · ")
    }

    /// « Ralenti » when every list only slows down, else « Bloqué ».
    static func verb(_ lists: [BlockList]) -> String {
        !lists.isEmpty && lists.allSatisfy({ $0.effectiveAction == .slowDown }) ? "Ralenti" : "Bloqué"
    }

    /// « tant que Xcode est ouvert » for a trigger block; at most two app names.
    static func triggerPhrase(_ names: [String]) -> String {
        guard !names.isEmpty else { return "tant qu’une app de travail est ouverte" }
        return "tant que " + names.prefix(2).joined(separator: ", ") + (names.count > 1 ? " sont ouverts" : " est ouvert")
    }
}

extension BlockingRules {
    /// `https://www.YouTube.com/shorts/?x=1` → `youtube.com/shorts`. Nil when it is not a site.
    static func normalizeSite(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let at = text.firstIndex(of: "@"), at < (text.firstIndex(of: "/") ?? text.endIndex) {
            text = String(text[text.index(after: at)...])
        }
        text = String(text.prefix { $0 != "?" && $0 != "#" })
        var host = String(text.prefix { $0 != "/" })
        var path = String(text.dropFirst(host.count))
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        while host.hasSuffix(".") { host.removeLast() }
        while path.hasSuffix("/") { path.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let ascii = host.unicodeScalars.allSatisfy(\.isASCII) ? host : (URL(string: "https://\(host)")?.host ?? host)
        return ascii + path
    }
}

/// Wall-clock arithmetic for the page: calendar days, never fixed 86 400 s, so DST days stay right.
enum BlockingWallClock {
    /// The engine's freeze bounds: at least 5 min, at most 24 h from now.
    static func freezeEnd(_ end: Date, now: Date) -> Date {
        min(max(end, now.addingTimeInterval(5 * 60)), now.addingTimeInterval(24 * 3_600))
    }

    /// The next `hour:minute` after `begin`: a time not after the start means the next day.
    static func next(hour: Int, minute: Int, after begin: Date, calendar: Calendar = .current) -> Date {
        if let day = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: begin), day > begin { return day }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: begin)),
              let day = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow), day > begin
        else { return begin.addingTimeInterval(86_400) }
        return day
    }

    /// The last second of `date`'s calendar day (23:59:59 even on a 23 h or 25 h day).
    static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)).addingTimeInterval(-1)
    }

    /// `minute` of the day as a wall-clock time on `date`'s day.
    static func wallTime(_ minute: Int, on date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date)
            ?? calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(minute * 60))
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

extension BlockSession.Origin {
    /// Free blocks the page may stop: manual, trigger and program. A commitment belongs to Concentration,
    /// and so does a focus session.
    var stopsFromPage: Bool {
        switch self {
        case .manual, .trigger, .program: return true
        case .commitment, .focus: return false
        }
    }
}
#endif
