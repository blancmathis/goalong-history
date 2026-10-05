#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// Main advances rule authority; workers only consult this short epoch check
/// and the immutable deadline. No rule structures or AX handles enter the lock.
final class BlockingTabRuleAuthority {
    private let lock = NSLock()
    private var epoch = UUID()
    func invalidate() { lock.lock(); epoch = UUID(); lock.unlock() }
    func permit(until deadline: Date, clock: @escaping () -> Date = Date.init) -> BlockingTabRulePermit {
        lock.lock(); let admittedEpoch = epoch; lock.unlock()
        return BlockingTabRulePermit(epoch: admittedEpoch, deadline: deadline, authority: self, clock: clock)
    }
    fileprivate func isCurrent(_ admittedEpoch: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == admittedEpoch
    }
}

struct BlockingTabRulePermit {
    let epoch: UUID
    let deadline: Date
    fileprivate let authority: BlockingTabRuleAuthority
    fileprivate let clock: () -> Date
    var isValid: Bool { authority.isCurrent(epoch) && clock() < deadline }
}

/// Separate action owner. A slow menu/action RPC cannot occupy observation,
/// history or main. An ambiguous action failure never retries with Cmd-W.
final class BlockingTabAXLane {
    enum Result: Equatable { case closed, unavailable, uncertain, revoked }
    private let queue = DispatchQueue(label: "Goalong.BlockingTabAX", qos: .userInteractive)
    private let client: AXClient
    init(client: AXClient = .system) { self.client = client }

    func request(_ target: BlockingObservation, permit: AXRequestPermit, rulePermit: BlockingTabRulePermit,
                 stillCurrent: @escaping () -> Bool,
                 revalidate: @escaping (@escaping (Bool) -> Void) -> Void,
                 fallback: @escaping () -> Void,
                 completion: @escaping (Result) -> Void = { _ in }) {
        let finish: (Result) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        queue.async {
            AXAccess.withBackgroundClient(self.client, permit: permit) {
                guard permit.isValid, rulePermit.isValid, stillCurrent(), self.matches(target) else { finish(.revoked); return }
                let app = AXAccess.application(target.pid)
                AXAccess.setMessagingTimeout(app, 0.15)
                var candidates: [AXUIElement] = AXReader.element(app, attribute: kAXMenuBarAttribute as CFString).map { [$0] } ?? []
                var visited = 0, closeItem: AXUIElement?
                while !candidates.isEmpty, visited < 160, permit.isValid, rulePermit.isValid {
                    let item = candidates.removeFirst(); visited += 1
                    let title = AXReader.string(item, attribute: kAXTitleAttribute as CFString)
                    let command = AXReader.string(item, attribute: kAXMenuItemCmdCharAttribute as CFString)
                    if let title, ["Fermer l’onglet", "Fermer l'onglet", "Close Tab"].contains(title), command?.lowercased() == "w" {
                        closeItem = item; break
                    }
                    candidates.append(contentsOf: AXReader.elements(item).prefix(160 - visited))
                }
                // The handle stays in the action owner; main receives only a continuation.
                let item = closeItem
                DispatchQueue.main.async {
                    revalidate { allowed in
                        guard allowed, permit.isValid, rulePermit.isValid else { completion(.revoked); return }
                        self.queue.async {
                            AXAccess.withBackgroundClient(self.client, permit: permit) {
                                guard permit.isValid, rulePermit.isValid, stillCurrent(), self.matches(target) else { finish(.revoked); return }
                                // matches() performs RPCs: expiry/epoch must be
                                // checked again after its final read, at the action.
                                guard permit.isValid, rulePermit.isValid else { finish(.revoked); return }
                                if let item {
                                    let error = AXAccess.performAction(item, kAXPressAction as CFString)
                                    if error == .success { finish(.closed); return }
                                    guard error == .actionUnsupported || error == .notImplemented else {
                                        finish(.uncertain); return
                                    }
                                }
                                guard permit.isValid, rulePermit.isValid, stillCurrent() else { finish(.revoked); return }
                                fallback()
                                finish(.closed)
                            }
                        }
                    }
                }
            }
        }
    }

    private func matches(_ target: BlockingObservation) -> Bool {
        guard target.windowBoundary?.matchesFocusedWindow(allowMainWindow: true) == true else { return false }
        guard !target.privateWindow else { return true }
        let app = AXAccess.application(target.pid)
        guard let window = AXReader.focusedWindow(for: app) ?? AXReader.element(app, attribute: kAXMainWindowAttribute as CFString) else { return false }
        let raw = AXReader.browserURL(from: window, addressFieldMarkers: target.addressFieldMarkers ?? []).map {
            target.isInternalPage ? $0.lowercased().components(separatedBy: "?")[0].components(separatedBy: "#")[0] : BlockingRules.normalize($0)
        }
        return raw == target.url
    }
}
#endif
