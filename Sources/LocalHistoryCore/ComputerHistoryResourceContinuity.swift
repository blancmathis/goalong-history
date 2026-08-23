import Foundation

extension ComputerHistorySupport {
    /// A delayed semantic callback may still carry the original interaction ID after the
    /// foreground document or page has changed. Application identity alone is therefore
    /// insufficient. When either event exposes a concrete locator, continuity requires the
    /// same canonical locator; otherwise stable resolved-resource IDs or document titles are
    /// used. Only contexts with no resource evidence on either side remain eligible.
    static func sameResourceContext(
        _ left: HistoryEvent,
        _ right: HistoryEvent,
        eventResourceIDs: [String: [String]]
    ) -> Bool {
        let leftURL = left.url?.value.flatMap(canonicalURL)
        let rightURL = right.url?.value.flatMap(canonicalURL)
        if leftURL != nil || rightURL != nil {
            guard let leftURL, let rightURL else { return false }
            return leftURL == rightURL
        }

        let leftIDs = Set(eventResourceIDs[left.id] ?? [])
        let rightIDs = Set(eventResourceIDs[right.id] ?? [])
        if !leftIDs.isEmpty || !rightIDs.isEmpty {
            guard !leftIDs.isEmpty, !rightIDs.isEmpty else { return false }
            return !leftIDs.isDisjoint(with: rightIDs)
        }

        let leftTitle = cleanTitle(left.window?.title, application: left.app?.name)
        let rightTitle = cleanTitle(right.window?.title, application: right.app?.name)
        if leftTitle != nil || rightTitle != nil {
            guard let leftTitle, let rightTitle else { return false }
            return normalized(leftTitle) == normalized(rightTitle)
        }

        return true
    }
}
