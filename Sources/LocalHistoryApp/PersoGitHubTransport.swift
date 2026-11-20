import Foundation

/// The one network read of a `make perso` build: anonymous GETs to GitHub's public API for this
/// repository (compare a commit with a release tag, list the pull requests of a commit), to decide
/// whether a release contains the perso commit (`PersoReleaseGate`). Compiled only with GOALONG_PERSO,
/// which `scripts/build_app_core.sh` sets for `make perso` alone: public releases contain no such code
/// and keep their reviewed network destinations. It sends two public commit identifiers and a release
/// tag, no activity data, account, cookie or Mac identifier.
enum PersoGitHubTransport {
    static let maximumBytes = 16 * 1024 * 1024

    #if GOALONG_PERSO
        static let fetch: PersoFetch = { url in
            guard url.scheme == "https", url.host == "api.github.com",
                  url.absoluteString.hasPrefix(PersoReleaseGate.apiRepository) else { return nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.url?.host == "api.github.com",
                  data.count <= maximumBytes else { return nil }
            return (http.statusCode, data)
        }
    #else
        /// Public releases: no transport. The gate is inert there anyway (no perso commit in Info.plist).
        static let fetch: PersoFetch = { _ in nil }
    #endif
}
