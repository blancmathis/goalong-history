import Darwin
import CoreFoundation
import Foundation
import LocalHistoryCore

public struct GoalongSiteTokenFileReview: Sendable {
    public let requiresProtection: Bool
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    fileprivate let bytes: off_t
    fileprivate let modifiedSeconds: Int
    fileprivate let modifiedNanoseconds: Int
}

public enum GoalongSiteSubmission {
    /// Resolve only a user-entered local path; never search for or discover token files.
    public static func tokenFileURL(path raw: String) throws -> URL {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.utf8.count <= 4096 else {
            throw GoalongSiteExportError.invalid("Enter the full local path of the downloaded token file.")
        }
        if path.hasPrefix("file:") {
            guard let parts = URLComponents(string: path), parts.scheme == "file",
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.host == nil || parts.host == "" || parts.host == "localhost",
                  let url = parts.url, url.isFileURL, url.path.hasPrefix("/") else {
                throw GoalongSiteExportError.invalid("The token must be a local file path, without a remote host, query or fragment.")
            }
            return url.standardizedFileURL
        }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else {
            throw GoalongSiteExportError.invalid("Use an absolute local path or a path beginning with ~/; no website URL or token value is accepted here.")
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    }

    public static func endpoint(origin raw: String) throws -> URL {
        guard var parts = URLComponents(string: raw), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host.lowercased()))
        else { throw GoalongSiteExportError.invalid("--url must be an HTTPS origin without credentials, query or path. HTTP is permitted only for localhost development.") }
        parts.path = "/api/goalong/v1/import"
        guard let url = parts.url else { throw GoalongSiteExportError.invalid("Invalid website origin.") }
        return url
    }

    /// Review the specifically chosen file before offering to restrict its permissions.
    /// This neither reads the credential nor changes anything on disk.
    public static func reviewTokenFile(file: URL) throws -> GoalongSiteTokenFileReview {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw GoalongSiteExportError.invalid("The upload-token file cannot be opened safely.") }
        defer { close(fd) }
        let metadata = try ownedRegularTokenMetadata(fd)
        return GoalongSiteTokenFileReview(requiresProtection: metadata.st_mode & 0o777 != 0o600,
            device: metadata.st_dev, inode: metadata.st_ino, bytes: metadata.st_size,
            modifiedSeconds: metadata.st_mtimespec.tv_sec, modifiedNanoseconds: metadata.st_mtimespec.tv_nsec)
    }

    /// Call only after the user explicitly accepts the native "Protéger ce fichier" action.
    /// The descriptor must still refer to the reviewed inode; a renamed replacement cannot
    /// cause this operation to chmod a different path target between review and confirmation.
    public static func protectTokenFile(file: URL, reviewed: GoalongSiteTokenFileReview) throws {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw GoalongSiteExportError.invalid("The chosen token file is no longer available safely.") }
        defer { close(fd) }
        let metadata = try ownedRegularTokenMetadata(fd)
        guard metadata.st_dev == reviewed.device, metadata.st_ino == reviewed.inode,
              metadata.st_size == reviewed.bytes,
              metadata.st_mtimespec.tv_sec == reviewed.modifiedSeconds,
              metadata.st_mtimespec.tv_nsec == reviewed.modifiedNanoseconds else {
            throw GoalongSiteExportError.invalid("The chosen file changed after review. Choose it again before changing its permissions.")
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw GoalongSiteExportError.invalid("Goalong could not protect the chosen token file.")
        }
        let protected = try ownedRegularTokenMetadata(fd)
        guard protected.st_mode & 0o777 == 0o600 else {
            throw GoalongSiteExportError.invalid("The token file permissions could not be confirmed as 0600.")
        }
    }

    private static func ownedRegularTokenMetadata(_ fd: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_size > 0, metadata.st_size <= 4096 else {
            throw GoalongSiteExportError.invalid("Choose a regular token file owned by your account, between 1 and 4096 bytes. Symbolic links and other owners are not accepted.")
        }
        return metadata
    }

    /// Read by descriptor so replacement/symlink races cannot switch the authorized file.
    /// The token is never included in process arguments, returned JSON, or error text.
    public static func readToken(file: URL) throws -> String {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw GoalongSiteExportError.invalid("The upload-token file cannot be opened safely.") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0, metadata.st_size <= 4096 else {
            throw GoalongSiteExportError.invalid("The upload-token file must be owned by you, regular, mode 0600, and at most 4096 bytes.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { pointer in
                read(fd, pointer.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GoalongSiteExportError.invalid("The upload-token file changed or could not be read.") }
            offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, metadata.st_size == after.st_size,
              metadata.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              metadata.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              after.st_mode & 0o777 == 0o600 else {
            throw GoalongSiteExportError.invalid("The upload-token file changed during the read.")
        }
        guard let raw = String(bytes: bytes, encoding: .utf8) else { throw GoalongSiteExportError.invalid("Invalid upload-token encoding.") }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...4096).contains(token.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw GoalongSiteExportError.invalid("The upload-token file must contain one nonempty token without embedded whitespace.")
        }
        return token
    }

    public static func request(payload: Data, endpoint: URL, token: String,
                               idempotencyKey: String? = nil) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey ?? "goalong-history-" + SHA256Digest.hashHex(payload), forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    public static func send(payload: Data, origin: String, tokenFile: URL, expectedTokenFingerprint: String? = nil) throws -> Data {
        guard !payload.isEmpty, payload.count <= 2 * 1024 * 1024 else {
            throw GoalongSiteExportError.invalid("The website import must be nonempty and at most 2 MiB.")
        }
        // Validate destination and token before any network operation. No cookies, cache,
        // ambient credentials, redirects or retries can expand the destination or action.
        let destination = try endpoint(origin: origin)
        let token = try readToken(file: tokenFile)
        if let expectedTokenFingerprint, SHA256Digest.hashHex(Data(token.utf8)) != expectedTokenFingerprint {
            throw GoalongSiteExportError.invalid("L’accès au compte a changé depuis votre confirmation. Aucun envoi n’a été effectué.")
        }
        let delegate = SubmissionResponse()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request(payload: payload, endpoint: destination, token: token)).resume()
        guard delegate.finished.wait(timeout: .now() + 35) == .success else {
            throw GoalongSiteExportError.invalid("Upload timed out. Check the site's import history before retrying; receipt status is unknown.")
        }
        return try delegate.result()
    }

    static func validatedResponse(_ data: Data, status: Int) throws -> Data {
        guard (200...299).contains(status) else {
            let reason: String
            switch status {
            case 301...399: reason = "Upload redirects are refused. Use the final website HTTPS origin."
            case 401, 403: reason = "The upload token was refused or revoked. Create a new upload-only token in Goalong."
            case 409: reason = "The import conflicts with another operation. Inspect the site's import history."
            case 413: reason = "The website refused the size of this import."
            case 429: reason = "The website import rate limit was reached. Try again later."
            default: reason = "The website refused the import (HTTP \(status))."
            }
            throw GoalongSiteExportError.invalid(reason)
        }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["verification"] as? String == "unverified" else {
            throw GoalongSiteExportError.invalid("The website returned an unexpected receipt; inspect import history before retrying.")
        }
        var result: [String: Any] = ["verification": "unverified", "sharing": "managed-on-site"]
        for key in ["imported", "updated", "skipped"] {
            guard let value = response[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue >= 0, value.doubleValue.rounded() == value.doubleValue,
                  value.doubleValue <= 366 else {
                throw GoalongSiteExportError.invalid("The website returned an invalid import receipt.")
            }
            result[key] = value
        }
        var encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        encoded.append(0x0A)
        return encoded
    }
}

private final class SubmissionResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private var data = Data()
    private var status = 0
    private var failure: String?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        failure = "Upload redirects are refused. Use the final website HTTPS origin."
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > 65_536 {
            failure = "The website receipt exceeds the 64 KiB response limit."
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= 65_536 else {
            failure = "The website receipt exceeds the 64 KiB response limit."
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil && failure == nil { failure = "Upload failed. Check import history before retrying; receipt status may be unknown." }
        finished.signal()
    }

    func result() throws -> Data {
        if let failure { throw GoalongSiteExportError.invalid(failure) }
        return try GoalongSiteSubmission.validatedResponse(data, status: status)
    }
}
