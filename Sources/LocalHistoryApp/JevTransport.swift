#if os(macOS)
import Foundation
import LocalHistoryCore

/// Sole Jev network boundary: fixed HTTPS endpoint, no cookies, redirects, disk
/// cache, credentials storage, tools, retries or history backlog.
final class JevTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private let configurationFactory: () -> URLSessionConfiguration
    init(configurationFactory: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.configurationFactory = configurationFactory
        super.init()
    }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var finished = false
    private var cancelled = false
    private var startedAt = ProcessInfo.processInfo.systemUptime

    func classify(body: Data, key: String) async throws -> JevDecision {
        startedAt = ProcessInfo.processInfo.systemUptime
        guard body.count <= JevPayload.maximumRequestBytes else { throw JevError.budget }
        let data: Data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = configurationFactory() // URLSessionConfiguration.ephemeral in production
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 10
                configuration.timeoutIntervalForResource = 12
                configuration.waitsForConnectivity = false
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: Self.endpoint)
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
        try Task.checkCancellation()
        return try JevDecision.decode(data)
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        let session = self.session; self.session = nil
        let task = self.task; self.task = nil
        buffer.removeAll()
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        switch result {
        case .success(let data):
            SupportDiagnostics.shared.record(.requestFinished, component: .monitoring, values: [
                .success: .flag(true), .byteCount: .count(data.count),
                .durationMS: .number((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)])
        case .failure(let error): SupportDiagnostics.shared.failure(error, component: .monitoring)
        }
        continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(JevError.invalidResponse))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == Self.endpoint else {
            completionHandler(.cancel); finish(.failure(JevError.invalidResponse)); return
        }
        SupportDiagnostics.shared.record(.requestFinished, component: .monitoring,
            values: [.httpStatus: .count(response.statusCode)])
        guard response.statusCode == 200 else {
            completionHandler(.cancel)
            switch response.statusCode {
            case 401, 403: finish(.failure(JevError.authentication))
            case 429:
                let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                let parsed = Double(value) ?? formatter.date(from: value)?.timeIntervalSinceNow ?? 60
                let seconds = parsed.isFinite ? parsed : 60
                finish(.failure(JevError.rateLimited(Int(min(86400, max(15, seconds.rounded(.up)))))))
            default: finish(.failure(JevError.http(response.statusCode)))
            }
            return
        }
        guard response.expectedContentLength <= 65_536,
              response.mimeType?.lowercased() == "application/json" else {
            completionHandler(.cancel); finish(.failure(JevError.invalidResponse)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard buffer.count + data.count <= 65_536 else {
            lock.unlock(); finish(.failure(JevError.invalidResponse)); return
        }
        buffer.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let data = buffer; lock.unlock()
        finish(.success(data))
    }
}
#endif
