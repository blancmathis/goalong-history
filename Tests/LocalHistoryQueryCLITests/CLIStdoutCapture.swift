import Foundation

/// Captures what a CLI run writes to file descriptor 1. Stdout is pointed at a private temporary file
/// (no 64 KB pipe limit, no reader thread) and always restored, also when the body throws. The lock keeps
/// two runs from sharing the redirection.
enum CLIStdoutCapture {
    private static let lock = NSLock()

    static func capture(_ body: () throws -> Void) -> (out: Data, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-stdout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { return (Data(), CocoaError(.fileWriteUnknown)) }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(descriptor, STDOUT_FILENO)
        var failure: Error?
        do { try body() } catch { failure = error }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved); close(descriptor)
        return ((try? Data(contentsOf: url)) ?? Data(), failure)
    }

    /// Runs the body and returns the printed JSON object; a thrown error is rethrown after stdout is restored.
    static func json(_ body: () throws -> Void) throws -> [String: Any] {
        let result = capture(body)
        if let error = result.error { throw error }
        guard let object = try JSONSerialization.jsonObject(with: result.out) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return object
    }
}
