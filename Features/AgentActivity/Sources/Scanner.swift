import Foundation

public final class AgentActivityScanner: @unchecked Sendable {
    private let store: AgentActivityStore
    private let fileManager: FileManager

    public init(store: AgentActivityStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    public func scan(configuration: AgentActivityConfiguration) -> AgentScanResult {
        let validated = configuration.validated()
        var result = AgentScanResult()
        for folder in validated.watchedFolders where folder.isEnabled {
            scan(folder: folder, configuration: validated, result: &result)
        }
        return result
    }

    private func scan(
        folder: AgentWatchedFolder,
        configuration: AgentActivityConfiguration,
        result: inout AgentScanResult
    ) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        var candidates: [URL] = []
        var enumerationFailures: [String] = []

        if folder.includeSubdirectories {
            guard
                let enumerator = fileManager.enumerator(
                    at: folder.url,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsPackageDescendants],
                    errorHandler: { url, error in
                        if enumerationFailures.count < 50 {
                            enumerationFailures.append("\(url.path): \(error.localizedDescription)")
                        }
                        return true
                    }
                )
            else { return }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
                    result.skippedFileCount += 1
                    continue
                }
                if values.isDirectory == true {
                    if AgentScannerPolicy.shouldSkipDirectory(url) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    result.skippedFileCount += 1
                    continue
                }
                if AgentScannerPolicy.shouldCapture(
                    url,
                    mode: folder.captureMode,
                    storeRoot: store.rootDirectory,
                    hookInbox: store.hookInboxDirectory
                ) {
                    candidates.append(url)
                } else {
                    result.skippedFileCount += 1
                }
            }
        } else if let files = try? fileManager.contentsOfDirectory(
            at: folder.url,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) {
            candidates = files.filter {
                AgentScannerPolicy.shouldCapture(
                    $0,
                    mode: folder.captureMode,
                    storeRoot: store.rootDirectory,
                    hookInbox: store.hookInboxDirectory
                )
            }
        }

        if !enumerationFailures.isEmpty {
            result.failures.append(contentsOf: enumerationFailures.prefix(max(0, 50 - result.failures.count)))
        }

        candidates.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for file in candidates {
            result.scannedFileCount += 1
            let relativePath = Self.relativePath(file, beneath: folder.url)
            do {
                if let capture = try store.capture(
                    fileURL: file,
                    relativePath: relativePath,
                    folder: folder,
                    configuration: configuration
                ) {
                    result.newCaptureCount += 1
                    result.captures.append(capture)
                }
            } catch AgentActivityStoreError.fileTooLarge {
                result.skippedFileCount += 1
            } catch {
                if result.failures.count < 50 {
                    result.failures.append("\(file.path): \(error.localizedDescription)")
                }
            }
        }
    }

    private static func relativePath(_ file: URL, beneath root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}

public enum AgentScannerPolicy {
    private static let allowedTranscriptExtensions: Set<String> = [
        "json", "jsonl", "ndjson", "md", "markdown", "txt", "log", "trace", "csv",
        "yaml", "yml", "toml", "db", "sqlite", "sqlite3", "vscdb", "session",
    ]

    private static let transcriptNameHints = [
        "agent", "chat", "conversation", "event", "history", "message", "prompt", "response",
        "session", "state", "thread", "tool", "trace", "transcript", "workspace",
    ]

    private static let skippedDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".build", "build", "deriveddata", "node_modules", "vendor",
        "cache", "caches", "code cache", "gpucache", "service worker", "crashpad", "tmp", "temp",
        "cacheddata", "cachedextensions", "extensions", "backups", "logs/archive",
    ]

    private static let sensitiveNames: Set<String> = [
        ".env", ".env.local", ".env.production", "auth.json", "credentials", "credentials.json",
        "cookies", "cookies-journal", "login data", "login data-journal", "local state",
        "network persistent state", "oauth.json", "secrets.json", "token.json", "tokens.json",
        "api_keys.json", "keychain.json", "master.key", "id_rsa", "id_ed25519",
    ]

    private static let sensitiveExtensions: Set<String> = ["pem", "key", "p12", "pfx", "cer", "crt"]

    public static func shouldSkipDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if skippedDirectories.contains(name) { return true }
        if name.hasSuffix(".app") || name.hasSuffix(".framework") || name.hasSuffix(".bundle") { return true }
        return false
    }

    public static func shouldCapture(
        _ url: URL,
        mode: AgentCaptureMode,
        storeRoot: URL,
        hookInbox: URL
    ) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let storePath = storeRoot.standardizedFileURL.path
        let hookPath = hookInbox.standardizedFileURL.path

        if path.hasPrefix(storePath + "/"), !path.hasPrefix(hookPath + "/") {
            return false
        }

        let name = standardized.lastPathComponent.lowercased()
        if name == ".ds_store" || name.hasPrefix("._") { return false }
        if name == ".env" || name.hasPrefix(".env.") { return false }
        if sensitiveNames.contains(name) || sensitiveExtensions.contains(standardized.pathExtension.lowercased()) {
            return false
        }
        if path.lowercased().split(separator: "/").contains(where: {
            [".ssh", ".aws", ".gnupg", "keychains"].contains(String($0))
        }) {
            return false
        }

        guard let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else { return false }

        if mode == .everyFile { return true }
        let ext = standardized.pathExtension.lowercased()
        if allowedTranscriptExtensions.contains(ext) { return true }
        return transcriptNameHints.contains { name.contains($0) }
    }
}
