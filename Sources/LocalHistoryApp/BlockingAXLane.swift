#if os(macOS)
import Foundation
import LocalHistoryCore

/// The reserved lane owns its reader and caches. It never queues behind history,
/// rich capture or disk, and publishes immutable observations by continuation.
final class BlockingAXLane {
    private let queue = DispatchQueue(label: "Goalong.BlockingAX", qos: .userInteractive)
    private let reader: ContextAXReader
    private let client: AXClient
    init(client: AXClient) { self.client = client; reader = ContextAXReader(clock: client.clock) }

    func rememberBrowser(_ application: AppSnapshot) {
        queue.async { self.reader.rememberBrowser(application) }
    }
    func request(_ input: ContextReadParameters, completion: @escaping (BlockingObservation?) -> Void) {
        let requestID = client.clock.identifier()
        let admittedAt = client.clock.uptime()
        queue.async {
            self.client.metric?(AXOperationMetric(requestID: requestID, stage: .waiting, operation: "blocking",
                duration: max(0, self.client.clock.uptime() - admittedAt), onMain: false, error: 0))
            let result = self.client.measure(.execution, requestID: requestID) {
                AXAccess.withBackgroundClient(self.client, requestID: requestID) {
                    self.reader.captureBlocking(parameters: input)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
#endif
