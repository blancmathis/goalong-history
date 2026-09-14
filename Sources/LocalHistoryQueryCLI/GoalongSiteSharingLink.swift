import Foundation

/// A link may only reveal the picker for the account already paired on this Mac.
/// It cannot provide an upload action, authorization, data scope, date or schedule.
public enum GoalongSiteSharingLink {
    public struct Destination: Equatable, Sendable {
        public let origin: String
        public let accountID: String
    }
    public static func destination(url: URL) throws -> Destination {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "goalong-history", parts.host == "share",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/", parts.fragment == nil,
              let items = parts.queryItems, items.count == 2,
              Set(items.map(\.name)) == ["site", "account"],
              let site = items.first(where: { $0.name == "site" })?.value,
              let account = items.first(where: { $0.name == "account" })?.value,
              let accountID = UUID(uuidString: account)?.uuidString.lowercased() else {
            throw GoalongSiteExportError.invalid("Ce lien de partage n’est pas valide. Ouvrez les réglages du site pour relier le bon compte.")
        }
        let endpoint = try GoalongSiteSubmission.endpoint(origin: site)
        var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        origin.path = ""
        guard let value = origin.string else { throw GoalongSiteExportError.invalid("Adresse de partage invalide.") }
        return Destination(origin: value, accountID: accountID)
    }
    public static func origin(url: URL) throws -> String { try destination(url: url).origin }
}
