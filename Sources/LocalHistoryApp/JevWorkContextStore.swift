#if os(macOS)
import Combine
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let jevWorkContextDidChange = Notification.Name("goalong.jev.work-context.changed")
}
@MainActor final class JevWorkContextStore: ObservableObject {
    static let shared = JevWorkContextStore()
    @Published private(set) var context: JevWorkContext = .empty
    @Published private(set) var error: String?
    private(set) var revision = UUID()
    private let root: URL
    init(root: URL = AppPaths.applicationSupportDirectory) {
        self.root = root
        do {
            if let data = try JevLocalFiles.read("work-context.json", root: root) {
                let value = try JSONDecoder().decode(JevWorkContext.self, from: data)
                guard value.isValid else { throw JevWorkContextError.tooLong }
                context = value
            }
        } catch { self.error = "Critères illisibles : surveillance suspendue. Enregistrez à nouveau vos repères de surveillance." }
    }
    static func reviewedVerdict(_ verdict: JevVerdict, work: JevWorkContext, window: JevWindow) -> JevVerdict {
        JevEvidencePolicy.reviewed(verdict, work: work, window: window)
    }
    /// Called only by the explicit Save action; editing a draft does not authorize new context.
    func save(_ summary: String, applications: String = "", content: String = "", procrastination: String = "") throws {
        let value = try JevWorkContext(summary: summary, applications: applications, content: content, procrastination: procrastination)
        try JevLocalFiles.write(try JSONEncoder().encode(value), name: "work-context.json", root: root)
        context = value; error = nil; revision = UUID()
        NotificationCenter.default.post(name: .jevWorkContextDidChange, object: self)
    }
}
#endif
