#if os(macOS)
import Foundation

/// French wording shared by the page, the veils and the shield.
enum BlockingFormat {
    private static let locale = Locale(identifier: "fr_FR")

    /// Blocks started by a trigger app have no end of their own.
    static func isOpenEnded(_ end: Date) -> Bool { end.timeIntervalSinceReferenceDate > Date().timeIntervalSinceReferenceDate + 400 * 86_400 }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date)
    }

    static func minuteOfDay(_ minute: Int) -> String {
        let value = ((minute % 1_440) + 1_440) % 1_440
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    /// « 1 h 24 », « 24 min », « moins d’une minute ».
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "moins d’une minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 24 {
            let days = hours / 24
            return days == 1 ? "1 jour \(hours % 24) h" : "\(days) jours \(hours % 24) h"
        }
        return rest == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, rest)
    }

    static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, rest)
    }

    /// « aujourd’hui à 14:00 », « demain à 9:00 », « lundi à 9:00 », « 31 oct. à 9:00 ».
    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let at = "à \(time(date))"
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd’hui \(at)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "demain \(at)"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        formatter.dateFormat = days < 7 ? "EEEE" : "d MMM"
        return "\(formatter.string(from: date)) \(at)"
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: date)
    }

    static let weekdayLetters = ["L", "M", "M", "J", "V", "S", "D"]
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
        let end = range.endMinute == 1_440 ? "24:00" : minuteOfDay(range.endMinute)
        return "\(minuteOfDay(range.startMinute)) → \(end)\(range.crossesMidnight && range.endMinute != 0 ? " le lendemain" : "")"
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
#endif
