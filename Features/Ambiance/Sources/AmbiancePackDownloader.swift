import Foundation

/// A single, foreground, explicit download. No retained session between actions.
enum AmbiancePackDownloader {
    static let assetHost = "release-assets.githubusercontent.com"
    static let releasePath = "/blancmathis/goalong-history/releases/download/ambiance-packs-v1/"

    static func download(_ pack: AmbiancePack, progress: @escaping (Double) -> Void) async throws -> URL {
        let url = try requestURL(pack)
        let job = Download(pack: pack, url: url, progress: progress)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { job.start($0) }
        }, onCancel: { job.cancel() })
    }

    static func requestURL(_ pack: AmbiancePack) throws -> URL {
        guard AmbiancePackCatalog.packs.contains(pack), allows(pack.url, pack: pack, redirect: false) else {
            throw AmbianceError.invalidPack("URL hors catalogue")
        }
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_PACK_TEST_URL"] {
            guard let base = URL(string: value), let parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
                  parts.scheme == "http", parts.host == "127.0.0.1", parts.path == "/",
                  parts.port != nil, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil else {
                throw AmbianceError.invalidPack("serveur de test non local")
            }
            return base.appendingPathComponent(pack.id + ".tar")
        }
        #endif
        return pack.url
    }

    static func allows(_ url: URL, pack: AmbiancePack, redirect: Bool) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return false }
        if redirect { return parts.host == assetHost && !parts.path.isEmpty }
        return parts.host == "github.com" && parts.query == nil
            && parts.percentEncodedPath == releasePath + pack.id + ".tar" && url == pack.url
    }

    /// Checks the HTTP status before the size, so an error body (404 with a short
    /// Content-Length) is never reported as a corrupt pack.
    /// No byte for 60 s fails fast; a whole pack (77-83 MB) may take up to an hour on a slow link (~200 kbit/s).
    static let requestTimeout: TimeInterval = 60
    static let resourceTimeout: TimeInterval = 3_600

    /// A timeout after some pack bytes means the link is too slow. A timeout before the first byte
    /// (blocked or silent server) is a connection failure. Other transport errors are never exposed:
    /// they may contain the signed failing URL.
    static func transportFailure(_ error: Error, bytesReceived: Int64) -> AmbianceError {
        switch (error as? URLError)?.code {
        case .cannotWriteToFile, .cannotCreateFile: return .diskFull
        case .timedOut where bytesReceived > 0: return .tooSlow
        default: return .network
        }
    }

    static func progressFailure(status: Int?, written: Int64, expected: Int64, packBytes: Int64) -> AmbianceError? {
        if let status, status != 200 { return .serverUnavailable }
        guard written <= packBytes, expected < 0 || expected == packBytes else {
            return .invalidPack("taille incorrecte")
        }
        return nil
    }
    static func redirectRequest(_ request: URLRequest, responseURL: URL?, initialURL: URL,
                                pack: AmbiancePack, redirectCount: Int) -> URLRequest? {
        guard redirectCount == 1, allows(initialURL, pack: pack, redirect: false),
              responseURL == initialURL, request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              let next = request.url, allows(next, pack: pack, redirect: true) else { return nil }
        // Reuse GitHub's URL verbatim: parsing validates it, never rebuilds its query.
        // A fresh request drops any forwarded headers, cookies or credentials.
        var clean = URLRequest(url: next, cachePolicy: .reloadIgnoringLocalCacheData)
        clean.httpMethod = "GET"; clean.httpShouldHandleCookies = false
        return clean
    }

    private final class Download: NSObject, URLSessionDownloadDelegate {
        private let pack: AmbiancePack
        private let url: URL
        private let progress: (Double) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var session: URLSession?
        private var cancelled = false
        private var failure: Error?
        private var redirects = 0
        /// Pack bytes received so far. Written and read only on the session's serial delegate queue.
        private var bytesReceived: Int64 = 0
        init(pack: AmbiancePack, url: URL, progress: @escaping (Double) -> Void) {
            self.pack = pack; self.url = url; self.progress = progress
        }
        func start(_ continuation: CheckedContinuation<URL, Error>) {
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: AmbianceError.cancelled); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.httpAdditionalHeaders = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = AmbiancePackDownloader.requestTimeout
            configuration.timeoutIntervalForResource = AmbiancePackDownloader.resourceTimeout
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            self.session = session
            let task = session.downloadTask(with: request)
            task.resume(); lock.unlock()
        }
        func cancel() {
            lock.lock(); cancelled = true; let session = self.session; lock.unlock()
            session?.invalidateAndCancel()
        }
        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            let continuation = self.continuation, session = self.session, cancelled = self.cancelled
            self.continuation = nil; self.session = nil
            lock.unlock()
            session?.invalidateAndCancel()
            if case .success(let file) = result, cancelled || continuation == nil { try? FileManager.default.removeItem(at: file) }
            if cancelled { continuation?.resume(throwing: AmbianceError.cancelled) }
            else { continuation?.resume(with: result) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            redirects += 1
            guard let clean = AmbiancePackDownloader.redirectRequest(request, responseURL: response.url,
                    initialURL: url, pack: pack, redirectCount: redirects) else {
                failure = AmbianceError.invalidPack("redirection refusée"); completionHandler(nil); return
            }
            completionHandler(clean)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if let failed = AmbiancePackDownloader.progressFailure(
                status: (downloadTask.response as? HTTPURLResponse)?.statusCode,
                written: totalBytesWritten, expected: totalBytesExpectedToWrite, packBytes: pack.bytes) {
                failure = failed; downloadTask.cancel(); return
            }
            bytesReceived = totalBytesWritten
            progress(min(1, Double(totalBytesWritten) / Double(pack.bytes)))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                if let failure { throw failure }
                guard let response = downloadTask.response as? HTTPURLResponse else { throw AmbianceError.network }
                guard response.statusCode == 200 else { throw AmbianceError.serverUnavailable }
                guard (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(pack.bytes) else {
                    throw AmbianceError.invalidPack("réponse ou taille incorrecte")
                }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("ambiance-download-\(UUID().uuidString).tar")
                try FileManager.default.moveItem(at: location, to: file)
                finish(.success(file))
            } catch { finish(.failure(error)) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // Foundation transport errors may contain the signed failing URL.
            // Never retain or expose them through the controller's public error.
            if let error {
                finish(.failure(failure ?? AmbiancePackDownloader.transportFailure(error, bytesReceived: bytesReceived)))
            }
        }
    }
}
