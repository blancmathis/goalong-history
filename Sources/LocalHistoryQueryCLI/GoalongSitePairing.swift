import Foundation
import Darwin

public struct GoalongSitePairing: Sendable {
    public let origin: String
    private let code: String

    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "goalong-history", parts.host == "connect",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.queryItems?.count == 1, parts.queryItems?.first?.name == "site",
              let site = parts.queryItems?.first?.value,
              let code = parts.fragment, code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw GoalongSiteExportError.invalid("Le lien de connexion Goalong est invalide.")
        }
        let endpoint = try GoalongSiteSubmission.endpoint(origin: site)
        var destination = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        destination.path = ""
        guard let origin = destination.string else { throw GoalongSiteExportError.invalid("Adresse Goalong invalide.") }
        self.origin = origin
        self.code = code
    }

    public func request() throws -> URLRequest {
        let endpoint = URL(string: origin + "/api/goalong/v1/native/pairing/claim")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        return request
    }

    public func exchange() throws -> Data {
        let delegate = PairingResponse()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: try request()).resume()
        guard delegate.finished.wait(timeout: .now() + 35) == .success else {
            throw GoalongSiteExportError.invalid("La connexion a expiré. Relancez-la depuis le site.")
        }
        return try delegate.result()
    }

    public func save(response: Data, directory: URL) throws -> URL {
        guard response.count <= 8192,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              object["origin"] as? String == origin,
              object["scope"] as? String == "upload:private",
              let token = object["token"] as? String,
              token.range(of: "^gl_up_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw GoalongSiteExportError.invalid("Le site a renvoyé un accès inattendu. Relancez la connexion.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw GoalongSiteExportError.invalid("Le dossier de connexion n’est pas accessible.") }
        defer { close(dir) }
        var metadata = stat()
        guard fstat(dir, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw GoalongSiteExportError.invalid("Le dossier de connexion doit être privé et appartenir à votre compte.")
        }
        let name = UUID().uuidString + ".token"
        let descriptor = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GoalongSiteExportError.invalid("L’accès n’a pas pu être enregistré sur ce Mac.") }
        defer { close(descriptor) }
        let bytes = Array((token + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                unlinkat(dir, name, 0)
                throw GoalongSiteExportError.invalid("L’accès n’a pas pu être enregistré. Relancez la connexion.")
            }
            offset += count
        }
        guard fsync(descriptor) == 0 else {
            unlinkat(dir, name, 0)
            throw GoalongSiteExportError.invalid("L’enregistrement de l’accès n’a pas été confirmé.")
        }
        return directory.appendingPathComponent(name)
    }
}

private final class PairingResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private var data = Data()
    private var status = 0
    private var failed = false
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        failed = true
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > 8192 { failed = true; completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= 8192 else { failed = true; dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { failed = true }
        finished.signal()
    }
    func result() throws -> Data {
        guard !failed, (200...299).contains(status) else {
            throw GoalongSiteExportError.invalid("La liaison n’a pas été confirmée. Le lien peut avoir expiré ou déjà été utilisé. Relancez la connexion depuis Goalong.")
        }
        return data
    }
}
