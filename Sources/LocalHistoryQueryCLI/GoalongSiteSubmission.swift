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

/// Failures the app treats apart from the others. Every other failure may mean the
/// site received the import, so it never triggers an automatic retry.
public enum GoalongSiteSubmissionError: Error, LocalizedError, CustomStringConvertible, Equatable {
    /// The request never left this Mac or never reached the site (no network, unknown host,
    /// connection refused). The site cannot have received it, so a later retry is safe.
    case unreachable
    /// The site refused the access (HTTP 401 or 403): the access was revoked or replaced.
    case accessRefused

    /// URL errors raised before any byte of the request can reach the site.
    static let unsentURLErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed,
    ]

    /// The error for a finished task, or nil when the receipt status is unknown.
    static func classify(_ error: Error) -> GoalongSiteSubmissionError? {
        let value = error as NSError
        return value.domain == NSURLErrorDomain && unsentURLErrorCodes.contains(value.code) ? .unreachable : nil
    }

    public var description: String {
        switch self {
        case .unreachable: return "The website could not be reached; the upload was not sent."
        case .accessRefused: return "The upload token was refused or revoked. Create a new upload-only token in Goalong."
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unreachable: return "Le site n’a pas pu être joint ; rien n’a été envoyé."
        case .accessRefused: return "Ce Mac n’est plus connecté au site. Reconnectez-le de nouveau avec « Relier mon Mac »."
        }
    }
}

public enum GoalongSiteSubmission {
    /// Resolve only a user-entered local path; never search for or discover token files.
    public static func tokenFileURL(path raw: String) throws -> URL {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.utf8.count <= 4096 else {
            throw GoalongSiteExportError.localized("Enter the full local path of the downloaded token file.", french: "Saisissez le chemin complet du fichier d’accès téléchargé.")
        }
        if path.hasPrefix("file:") {
            guard let parts = URLComponents(string: path), parts.scheme == "file",
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.host == nil || parts.host == "" || parts.host == "localhost",
                  let url = parts.url, url.isFileURL, url.path.hasPrefix("/") else {
                throw GoalongSiteExportError.localized("The token must be a local file path, without a remote host, query or fragment.", french: "Le jeton doit être un chemin de fichier local, sans hôte distant, requête ni fragment.")
            }
            return url.standardizedFileURL
        }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else {
            throw GoalongSiteExportError.localized("Use an absolute local path or a path beginning with ~/; no website URL or token value is accepted here.", french: "Utilisez un chemin local absolu ou commençant par ~/ ; aucune adresse de site ni valeur de jeton n’est acceptée ici.")
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    }

    public static func endpoint(origin raw: String) throws -> URL {
        guard var parts = URLComponents(string: raw), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host.lowercased()))
        else { throw GoalongSiteExportError.localized("--url must be an HTTPS origin without credentials, query or path. HTTP is permitted only for localhost development.", french: "L’adresse du site doit être une origine HTTPS sans identifiants, requête ni chemin. HTTP n’est permis que pour le développement local.") }
        parts.path = "/api/goalong/v1/import"
        guard let url = parts.url else { throw GoalongSiteExportError.localized("Invalid website origin.", french: "Adresse du site invalide.") }
        return url
    }

    /// Review the specifically chosen file before offering to restrict its permissions.
    /// This neither reads the credential nor changes anything on disk.
    public static func reviewTokenFile(file: URL) throws -> GoalongSiteTokenFileReview {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw GoalongSiteExportError.localized("The upload-token file cannot be opened safely.", french: "Le fichier d’accès ne peut pas être ouvert en toute sécurité.") }
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
        guard fd >= 0 else { throw GoalongSiteExportError.localized("The chosen token file is no longer available safely.", french: "Le fichier d’accès choisi n’est plus disponible en toute sécurité.") }
        defer { close(fd) }
        let metadata = try ownedRegularTokenMetadata(fd)
        guard metadata.st_dev == reviewed.device, metadata.st_ino == reviewed.inode,
              metadata.st_size == reviewed.bytes,
              metadata.st_mtimespec.tv_sec == reviewed.modifiedSeconds,
              metadata.st_mtimespec.tv_nsec == reviewed.modifiedNanoseconds else {
            throw GoalongSiteExportError.localized("The chosen file changed after review. Choose it again before changing its permissions.", french: "Le fichier choisi a changé après la vérification. Choisissez-le de nouveau avant de modifier ses droits.")
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw GoalongSiteExportError.localized("Goalong could not protect the chosen token file.", french: "Goalong n’a pas pu protéger le fichier d’accès choisi.")
        }
        let protected = try ownedRegularTokenMetadata(fd)
        guard protected.st_mode & 0o777 == 0o600 else {
            throw GoalongSiteExportError.localized("The token file permissions could not be confirmed as 0600.", french: "Les droits du fichier d’accès n’ont pas pu être confirmés (0600).")
        }
    }

    private static func ownedRegularTokenMetadata(_ fd: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_size > 0, metadata.st_size <= 4096 else {
            throw GoalongSiteExportError.localized("Choose a regular token file owned by your account, between 1 and 4096 bytes. Symbolic links and other owners are not accepted.", french: "Choisissez un fichier de jeton ordinaire appartenant à votre compte, de 1 à 4096 octets. Les liens symboliques et les autres propriétaires ne sont pas acceptés.")
        }
        return metadata
    }

    /// Read by descriptor so replacement/symlink races cannot switch the authorized file.
    /// The token is never included in process arguments, returned JSON, or error text.
    public static func readToken(file: URL) throws -> String {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw GoalongSiteExportError.localized("The upload-token file cannot be opened safely.", french: "Le fichier d’accès ne peut pas être ouvert en toute sécurité.") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0, metadata.st_size <= 4096 else {
            throw GoalongSiteExportError.localized("The upload-token file must be owned by you, regular, mode 0600, and at most 4096 bytes.", french: "Le fichier d’accès doit vous appartenir, être ordinaire, en mode 0600 et faire 4096 octets au plus.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { pointer in
                read(fd, pointer.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GoalongSiteExportError.localized("The upload-token file changed or could not be read.", french: "Le fichier d’accès a changé ou n’a pas pu être lu.") }
            offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, metadata.st_size == after.st_size,
              metadata.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              metadata.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              after.st_mode & 0o777 == 0o600 else {
            throw GoalongSiteExportError.localized("The upload-token file changed during the read.", french: "Le fichier d’accès a changé pendant la lecture.")
        }
        guard let raw = String(bytes: bytes, encoding: .utf8) else { throw GoalongSiteExportError.localized("Invalid upload-token encoding.", french: "Encodage du fichier d’accès invalide.") }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...4096).contains(token.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw GoalongSiteExportError.localized("The upload-token file must contain one nonempty token without embedded whitespace.", french: "Le fichier d’accès doit contenir un seul jeton non vide, sans espace.")
        }
        return token
    }

    /// Low-level request builder. Reuse an explicit key only when retrying the same
    /// operation. New user-approved writes must use requestForNewSubmission below.
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

    /// A content hash alone is not an operation identity: approving A, then B,
    /// then A again must reapply A, not replay the first A's historical receipt.
    /// Each explicit submission has a fresh identity bound to its exact bytes.
    /// The server still treats an unchanged source snapshot as a no-op.
    public static func requestForNewSubmission(payload: Data, endpoint: URL, token: String) -> URLRequest {
        let key = "goalong-history-" + UUID().uuidString + "-" + SHA256Digest.hashHex(payload)
        return request(payload: payload, endpoint: endpoint, token: token, idempotencyKey: key)
    }

    public static func send(payload: Data, origin: String, tokenFile: URL, expectedTokenFingerprint: String? = nil,
                            privacyRoot: URL = GoalongOutgoingPrivacy.defaultRoot, expectedPrivacyRevision: String? = nil) throws -> Data {
        try GoalongDevServerDisabledError.check()
        let pauseTicket = try GoalongGlobalPause.admit(in: privacyRoot)
        guard !payload.isEmpty, payload.count <= 2 * 1024 * 1024 else {
            throw GoalongSiteExportError.localized("The website import must be nonempty and at most 2 MiB.", french: "L’envoi au site ne doit pas être vide et doit faire 2 Mio au plus.")
        }
        // Validate destination and token before any network operation. No cookies, cache,
        // ambient credentials, redirects or retries can expand the destination or action.
        let privacy = try GoalongOutgoingPrivacy.validate(payload, root: privacyRoot, expectedRevision: expectedPrivacyRevision)
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
        let pauseObserver = NotificationCenter.default.addObserver(forName: .goalongGlobalPauseDidChange,
            object: nil, queue: nil) { notification in
            if notification.object as? String == privacyRoot.standardizedFileURL.path,
               GoalongGlobalPause.isPaused(in: privacyRoot) { session.invalidateAndCancel() }
        }
        defer { NotificationCenter.default.removeObserver(pauseObserver); session.invalidateAndCancel() }
        guard GoalongPrivacyPolicy.load(in: privacyRoot).revision == privacy.revision else {
            throw GoalongSiteExportError.invalid("Les exclusions ont changé juste avant l’envoi. Refaites l’aperçu.")
        }
        try GoalongGlobalPause.revalidate(pauseTicket, in: privacyRoot)
        session.dataTask(with: requestForNewSubmission(payload: payload, endpoint: destination, token: token)).resume()
        guard delegate.finished.wait(timeout: .now() + 35) == .success else {
            throw GoalongSiteExportError.localized("Upload timed out. Check the site's import history before retrying; receipt status is unknown.", french: "L’envoi a expiré. Vérifiez l’historique d’import du site avant de réessayer ; on ne sait pas s’il a été reçu.")
        }
        return try delegate.result()
    }

    static func validatedResponse(_ data: Data, status: Int) throws -> Data {
        guard (200...299).contains(status) else {
            let reason: GoalongSiteExportError
            switch status {
            case 301...399: reason = .localized("Upload redirects are refused. Use the final website HTTPS origin.", french: "Le site a redirigé l’envoi, ce qui est refusé. Utilisez l’adresse HTTPS finale du site.")
            case 401, 403: throw GoalongSiteSubmissionError.accessRefused
            case 409: reason = .localized("The import conflicts with another operation. Inspect the site's import history.", french: "L’envoi est en conflit avec une autre opération. Consultez l’historique d’import du site.")
            case 413: reason = .localized("The website refused the size of this import.", french: "Le site a refusé la taille de cet envoi.")
            case 429: reason = .localized("The website import rate limit was reached. Try again later.", french: "Trop d’envois en peu de temps. Réessayez plus tard.")
            default: reason = .localized("The website refused the import (HTTP \(status)).", french: "Le site a refusé l’envoi (HTTP \(status)).")
            }
            throw reason
        }
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              response["verification"] as? String == "unverified" else {
            throw GoalongSiteExportError.localized("The website returned an unexpected receipt; inspect import history before retrying.", french: "Le site a renvoyé un reçu inattendu ; consultez l’historique d’import avant de réessayer.")
        }
        var result: [String: Any] = ["verification": "unverified", "sharing": "managed-on-site"]
        for key in ["imported", "updated", "skipped"] {
            guard let value = response[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue >= 0, value.doubleValue.rounded() == value.doubleValue,
                  value.doubleValue <= 366 else {
                throw GoalongSiteExportError.localized("The website returned an invalid import receipt.", french: "Le site a renvoyé un reçu d’import invalide.")
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
    private var failure: GoalongSiteExportError?
    private var unsent: GoalongSiteSubmissionError?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        failure = .localized("Upload redirects are refused. Use the final website HTTPS origin.", french: "Le site a redirigé l’envoi, ce qui est refusé. Utilisez l’adresse HTTPS finale du site.")
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > 65_536 {
            failure = .localized("The website receipt exceeds the 64 KiB response limit.", french: "Le reçu du site dépasse la limite de 64 Kio ; consultez l’historique d’import avant de réessayer.")
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= 65_536 else {
            failure = .localized("The website receipt exceeds the 64 KiB response limit.", french: "Le reçu du site dépasse la limite de 64 Kio ; consultez l’historique d’import avant de réessayer.")
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil, let known = GoalongSiteSubmissionError.classify(error) {
            unsent = known
        } else if error != nil && failure == nil { failure = .localized("Upload failed. Check import history before retrying; receipt status may be unknown.", french: "L’envoi a échoué. Vérifiez l’historique d’import avant de réessayer ; on ne sait pas s’il a été reçu.") }
        finished.signal()
    }

    func result() throws -> Data {
        if let failure { throw failure }
        if let unsent { throw unsent }
        return try GoalongSiteSubmission.validatedResponse(data, status: status)
    }
}
