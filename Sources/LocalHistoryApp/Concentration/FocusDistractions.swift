#if os(macOS)
import Foundation
import LocalHistoryCore

struct FocusDistractionCount: Codable, Equatable, Identifiable {
    enum State: String, Codable { case pending, accepted, ignored }
    var target: JevDistractionTarget
    var confirmedSeconds: Int
    var state: State = .pending
    var acceptedListID: UUID?
    var id: String { target.id }
    var valid: Bool {
        target.isValid && confirmedSeconds >= 15 && confirmedSeconds % 15 == 0
            && ((state == .accepted) == (acceptedListID != nil))
    }
}

struct FocusDistractionSuggestion: Equatable, Identifiable {
    var target: JevDistractionTarget
    var confirmedSeconds: Int
    var id: String { target.id }
}

/// Only bounded identities and confirmed-window totals; no titles, URLs or remote payloads.
struct FocusDistractionRecord: Codable, Equatable {
    var schema = 1
    var counts: [FocusDistractionCount] = []
    var lastWindowEnd: Date?
    /// Frozen at the end: accepting/ignoring a card never introduces a fourth suggestion.
    var suggestedTargetIDs: [String]?
    var valid: Bool {
        schema == 1 && counts.count <= 200 && counts.allSatisfy(\.valid)
            && Set(counts.map(\.id)).count == counts.count
            && (lastWindowEnd.map { $0.timeIntervalSince1970.isFinite } ?? true)
            && (suggestedTargetIDs.map { $0.count <= 3 && Set($0).count == $0.count
                && Set($0).isSubset(of: Set(counts.filter { $0.confirmedSeconds >= 120 }.map(\.id))) } ?? true)
    }
    mutating func record(_ window: JevWindow, verdict: JevVerdict, sessionStart: Date, now: Date) -> Bool {
        guard suggestedTargetIDs == nil, verdict == .procrastination, window.hasActivity,
              window.start.timeIntervalSince1970.isFinite, window.end.timeIntervalSince1970.isFinite,
              abs(window.end.timeIntervalSince(window.start) - 15) < 0.01,
              window.start >= sessionStart, window.end <= now, now.timeIntervalSince(window.end) < 15,
              lastWindowEnd.map({ window.start >= $0 }) ?? true,
              !window.samples.isEmpty, window.samples.allSatisfy({ $0.distractionTarget?.isValid == true }) else { return false }
        // A window verdict does not identify the distracting row in a mixed window.
        let targets = Dictionary(grouping: window.samples.compactMap(\.distractionTarget), by: \.id)
        guard targets.count == 1, let target = targets.values.first?.first else { return false }
        if let i = counts.firstIndex(where: { $0.id == target.id }) {
            guard counts[i].confirmedSeconds <= Int.max - 15 else { return false }
            counts[i].confirmedSeconds += 15
        } else {
            guard counts.count < 200 else { return false }
            counts.append(.init(target: target, confirmedSeconds: 15))
        }
        lastWindowEnd = window.end
        return true
    }
    mutating func finish(lists: [BlockList], ignored: Set<String>) {
        guard suggestedTargetIDs == nil else { return }
        suggestedTargetIDs = counts.filter {
            $0.confirmedSeconds >= 120 && $0.state == .pending && !ignored.contains($0.id)
                && !FocusDistractionRules.contains($0.target, lists: lists)
        }.sorted {
            $0.confirmedSeconds == $1.confirmedSeconds ? $0.id < $1.id : $0.confirmedSeconds > $1.confirmedSeconds
        }.prefix(3).map(\.id)
    }
    func suggestions(lists: [BlockList], ignored: Set<String>) -> [FocusDistractionSuggestion] {
        (suggestedTargetIDs ?? []).compactMap { id in
            guard let count = counts.first(where: { $0.id == id }), count.state == .pending,
                  !ignored.contains(id), !FocusDistractionRules.contains(count.target, lists: lists) else { return nil }
            return .init(target: count.target, confirmedSeconds: count.confirmedSeconds)
        }
    }
}

enum FocusDistractionRules {
    static func contains(_ target: JevDistractionTarget, lists: [BlockList]) -> Bool {
        lists.contains { list in
            switch target.kind {
            case .site: return list.sites.contains { JevRegistrableDomain.domain($0.host) == target.value }
            case .app: return list.apps.contains { $0.bundleIdentifier == target.value }
            }
        }
    }
}
#endif
