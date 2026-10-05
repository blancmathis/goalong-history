#if os(macOS)
import ApplicationServices
import Foundation

/// Wall time is retained for journal dates; monotonic time is only for durations.
struct AXCaptureClock {
    var date: () -> Date = Date.init
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var identifier: () -> String = { UUID().uuidString }
}

struct AXReadResult {
    let error: AXError
    let value: CFTypeRef?
}

struct AXOperationMetric {
    enum Stage: String { case rpc, waiting, execution, publication, commit }
    let requestID: String
    let stage: Stage
    let operation: String
    let duration: TimeInterval
    let onMain: Bool
    let error: Int32
}

/// Injectable C boundary. Handles never escape a reader in published snapshots.
/// Tests supply local AX handles and scripted attribute/error responses, without TCC.
final class AXClient {
    static let system = AXClient()
    let clock: AXCaptureClock
    let metric: ((AXOperationMetric) -> Void)?
    let requiresBackgroundThread: Bool
    var read: (AXUIElement, CFString) -> AXReadResult
    var application: (pid_t) -> AXUIElement = AXUIElementCreateApplication
    var systemWide: () -> AXUIElement = AXUIElementCreateSystemWide
    var getPID: (AXUIElement, UnsafeMutablePointer<pid_t>) -> AXError = AXUIElementGetPid
    var hitTest: (AXUIElement, Float, Float, UnsafeMutablePointer<AXUIElement?>) -> AXError = AXUIElementCopyElementAtPosition
    var setTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout
    var perform: (AXUIElement, CFString) -> AXError = AXUIElementPerformAction
    var createObserver: (pid_t, AXObserverCallback, UnsafeMutablePointer<AXObserver?>) -> AXError = AXObserverCreate
    var addNotification: (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> AXError = AXObserverAddNotification
    var removeNotification: (AXObserver, AXUIElement, CFString) -> AXError = AXObserverRemoveNotification

    init(clock: AXCaptureClock = AXCaptureClock(), requiresBackgroundThread: Bool = false,
         metric: ((AXOperationMetric) -> Void)? = nil,
         read: @escaping (AXUIElement, CFString) -> AXReadResult = { element, attribute in
             var value: CFTypeRef?
             let error = AXUIElementCopyAttributeValue(element, attribute, &value)
             return AXReadResult(error: error, value: value)
         }) {
        self.clock = clock
        self.requiresBackgroundThread = requiresBackgroundThread
        self.metric = metric
        self.read = read
    }

    fileprivate func call(_ operation: String, _ body: () -> AXError) -> AXError {
        if requiresBackgroundThread || AXAccess.backgroundRequired {
            precondition(!Thread.isMainThread, "Outbound AX RPC on main: \(operation)")
        }
        guard let metric else { return body() }
        let start = clock.uptime()
        let result = body()
        metric(AXOperationMetric(requestID: AXAccess.requestID, stage: .rpc, operation: operation,
                                 duration: max(0, clock.uptime() - start), onMain: Thread.isMainThread,
                                 error: result.rawValue))
        return result
    }

    func measure<T>(_ stage: AXOperationMetric.Stage, requestID: String, _ body: () -> T) -> T {
        guard let metric else { return body() }
        let start = clock.uptime()
        let value = body()
        metric(AXOperationMetric(requestID: requestID, stage: stage, operation: stage.rawValue,
                                 duration: max(0, clock.uptime() - start), onMain: Thread.isMainThread, error: 0))
        return value
    }
}

/// A dynamically scoped client follows synchronous AX traversal on its owning
/// thread. There is no process-wide test override and no lock held during IPC.
enum AXAccess {
    private final class Scope: NSObject {
        let client: AXClient
        let requestID: String
        var backgroundRequired = false
        init(_ client: AXClient, _ requestID: String) { self.client = client; self.requestID = requestID }
    }
    private static let key = "ai.goalong.ax-client-scope"
    private static var scope: Scope? { Thread.current.threadDictionary[key] as? Scope }
    static var backgroundRequired: Bool { scope?.backgroundRequired == true }
    static var client: AXClient { scope?.client ?? .system }
    static var requestID: String { scope?.requestID ?? "unscoped" }

    static func withClient<T>(_ client: AXClient, requestID: String = "fixture", _ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = Scope(client, requestID)
        defer { Thread.current.threadDictionary[key] = previous }
        return try body()
    }

    static func withBackgroundClient<T>(_ client: AXClient, requestID: String = "fixture", _ body: () throws -> T) rethrows -> T {
        try withClient(client, requestID: requestID) {
            scope?.backgroundRequired = true
            return try body()
        }
    }

    static func application(_ pid: pid_t) -> AXUIElement { client.application(pid) }
    static func systemWide() -> AXUIElement { client.systemWide() }
    @discardableResult static func copyAttributeValue(_ element: AXUIElement, _ attribute: CFString,
                                                     _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
        let client = client
        return client.call("attribute") {
            let result = client.read(element, attribute)
            value.pointee = result.value
            return result.error
        }
    }
    @discardableResult static func getPID(_ element: AXUIElement, _ pid: UnsafeMutablePointer<pid_t>) -> AXError {
        let client = client
        return client.call("pid") { client.getPID(element, pid) }
    }
    @discardableResult static func copyElementAtPosition(_ element: AXUIElement, _ x: Float, _ y: Float,
                                                        _ result: UnsafeMutablePointer<AXUIElement?>) -> AXError {
        let client = client
        return client.call("hit_test") { client.hitTest(element, x, y, result) }
    }
    @discardableResult static func setMessagingTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError {
        let client = client
        return client.call("timeout") { client.setTimeout(element, timeout) }
    }
    @discardableResult static func performAction(_ element: AXUIElement, _ action: CFString) -> AXError {
        let client = client
        return client.call("action") { client.perform(element, action) }
    }
    static func createObserver(_ pid: pid_t, _ callback: AXObserverCallback,
                               _ observer: UnsafeMutablePointer<AXObserver?>) -> AXError {
        let client = client
        return client.call("observer_create") { client.createObserver(pid, callback, observer) }
    }
    static func addNotification(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) -> AXError {
        let client = client
        return client.call("observer_add") { client.addNotification(observer, element, notification, refcon) }
    }
    static func removeNotification(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString) -> AXError {
        let client = client
        return client.call("observer_remove") { client.removeNotification(observer, element, notification) }
    }
}
#endif
