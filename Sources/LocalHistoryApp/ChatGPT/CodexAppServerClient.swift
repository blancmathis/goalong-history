#if os(macOS)
    import AppKit
    import CoreFoundation
    import Darwin
    import Foundation
    import LocalHistoryCore

    enum CodexAppServerError: LocalizedError {
        case executableUnavailable
        case launchFailed(String)
        case processExited(String)
        case timeout(String)
        case protocolLimitExceeded(String)
        case malformedResponse(String)
        case server(String)
        case loginFailed(String)
        case accountNotChatGPT(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .executableUnavailable:
                return "Codex is not installed. Install the Codex CLI, then return here to connect ChatGPT."
            case .launchFailed(let message):
                return "Codex app-server could not start: \(Self.boundedDetail(message))"
            case .processExited(let message):
                return message.isEmpty
                    ? "Codex app-server stopped unexpectedly."
                    : "Codex app-server stopped unexpectedly: \(Self.boundedDetail(message))"
            case .timeout(let operation):
                return "Codex timed out while \(Self.boundedDetail(operation))."
            case .protocolLimitExceeded(let message):
                return "Codex app-server exceeded Goalong's output safety limit: \(Self.boundedDetail(message))"
            case .malformedResponse(let message):
                return "Codex returned an invalid response: \(Self.boundedDetail(message))"
            case .server(let message):
                return "Codex reported an error: \(Self.boundedDetail(message))"
            case .loginFailed(let message):
                return message.isEmpty
                    ? "ChatGPT sign-in did not complete."
                    : "ChatGPT sign-in failed: \(Self.boundedDetail(message))"
            case .accountNotChatGPT(let mode):
                return
                    "Goalong will not use the active \(Self.boundedDetail(mode)) credentials because they may be billed as API usage. Connect with ChatGPT instead."
            case .generationFailed(let message):
                return message.isEmpty
                    ? "The recap agent failed."
                    : "The recap agent failed: \(Self.boundedDetail(message))"
            }
        }

        private static func boundedDetail(_ value: String) -> String {
            CodexAppServerLimits.boundedUTF8(
                ActivitySemanticTextSanitizer.redact(value) ?? "",
                maximumBytes: 4_096
            )
        }
    }

    struct CodexAppServerLimits {
        var maximumProtocolLineBytes = 8 * 1_024 * 1_024
        var maximumBufferedStdoutBytes = 8 * 1_024 * 1_024 + 65_536
        var maximumDeferredMessages = 512
        var maximumDeferredBytes = 16 * 1_024 * 1_024
        var maximumMessages = 20_000
        var maximumBlankLines = 4_096
        var maximumBlankLineBytes = 65_536
        var maximumRecapCandidateBytes = 2 * 1_024 * 1_024
        var maximumRecapMarkdownBytes = 1 * 1_024 * 1_024
        var maximumStderrBytes = 65_536
        var maximumErrorBytes = 4_096

        static let production = CodexAppServerLimits()

        static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
            guard maximumBytes > 0, value.utf8.count > maximumBytes else {
                return maximumBytes > 0 ? value : ""
            }
            let marker = Data("…".utf8)
            let prefixLimit =
                maximumBytes >= marker.count
                ? maximumBytes - marker.count
                : maximumBytes
            var prefix = Data(value.utf8.prefix(prefixLimit))
            while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
                prefix.removeLast()
            }
            let suffix = maximumBytes >= marker.count ? "…" : ""
            return (String(data: prefix, encoding: .utf8) ?? "") + suffix
        }
    }

    enum CodexAppServerWireEncoder {
        static func encode(
            _ object: [String: Any],
            limits: CodexAppServerLimits = .production
        ) throws -> Data {
            guard JSONSerialization.isValidJSONObject(object) else {
                throw CodexAppServerError.malformedResponse("client attempted to send invalid JSON")
            }
            var data = try JSONSerialization.data(withJSONObject: object, options: [])
            guard data.count <= limits.maximumProtocolLineBytes else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "an outgoing JSON line exceeded \(limits.maximumProtocolLineBytes) bytes"
                )
            }
            data.append(0x0A)
            return data
        }
    }

    enum CodexAppServerTimedWriter {
        static func prepareNonBlocking(_ descriptor: Int32) throws {
            let flags = Darwin.fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0
            else {
                throw CodexAppServerError.launchFailed(String(cString: strerror(errno)))
            }
        }

        static func write(
            _ data: Data,
            to descriptor: Int32,
            deadline: Date,
            operation: String,
            errorDetail: () -> String = { "" }
        ) throws {
            var offset = 0
            try data.withUnsafeBytes { bytes in
                while offset < bytes.count {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else {
                        throw CodexAppServerError.timeout(operation)
                    }
                    var pollDescriptor = pollfd(
                        fd: descriptor,
                        events: Int16(POLLOUT | POLLHUP | POLLERR),
                        revents: 0
                    )
                    let timeoutMilliseconds = Int32(
                        min(max(remaining * 1_000, 0), Double(Int32.max))
                    )
                    let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
                    if pollResult == 0 {
                        throw CodexAppServerError.timeout(operation)
                    }
                    if pollResult < 0 {
                        if errno == EINTR { continue }
                        throw CodexAppServerError.processExited(errorDetail())
                    }
                    if pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                        throw CodexAppServerError.processExited(errorDetail())
                    }

                    let written = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    guard written > 0 else {
                        throw CodexAppServerError.processExited(errorDetail())
                    }
                    offset += written
                }
            }
        }
    }

    enum CodexAppServerMessageRouter {
        static func strictIntegerID(from value: Any?) -> Int? {
            guard let number = value as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return nil }
            let integerEncodings: Set<String> = ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]
            guard integerEncodings.contains(String(cString: number.objCType)) else { return nil }
            return Int(number.stringValue)
        }

        static func responseID(in message: [String: Any]) throws -> Int? {
            guard message.keys.contains("id") else { return nil }
            guard let id = strictIntegerID(from: message["id"]) else {
                throw CodexAppServerError.malformedResponse(
                    "a JSON-RPC response id was not a strict integer"
                )
            }
            return id
        }

        static func notificationMethod(in message: [String: Any]) throws -> String {
            guard try responseID(in: message) == nil else {
                throw CodexAppServerError.malformedResponse(
                    "an unmatched JSON-RPC response was received"
                )
            }
            guard let method = message["method"] as? String, !method.isEmpty else {
                throw CodexAppServerError.malformedResponse(
                    "a JSON-RPC notification method was missing"
                )
            }
            return method
        }
    }

    struct CodexStreamingRedactor {
        private var pending = ""

        mutating func append(_ delta: String) -> String {
            guard !delta.isEmpty else { return "" }
            pending.append(delta)
            guard let newline = pending.lastIndex(of: "\n") else { return "" }
            let boundary = pending.index(after: newline)
            let completeLines = String(pending[..<boundary])
            pending = String(pending[boundary...])
            guard let redacted = ActivitySemanticTextSanitizer.redact(completeLines) else {
                return ""
            }
            return redacted + "\n"
        }

        mutating func finish() -> String {
            defer { pending = "" }
            return ActivitySemanticTextSanitizer.redact(pending) ?? ""
        }
    }

    struct CodexAppServerMessageDecoder {
        private(set) var outputBuffer = Data()
        private(set) var messageCount = 0
        private(set) var blankLineCount = 0
        private(set) var blankLineBytes = 0

        let limits: CodexAppServerLimits

        init(limits: CodexAppServerLimits = .production) {
            self.limits = limits
        }

        mutating func append(_ data: Data) throws {
            guard !data.isEmpty else { return }
            guard data.count <= limits.maximumBufferedStdoutBytes - outputBuffer.count else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "stdout buffered more than \(limits.maximumBufferedStdoutBytes) bytes"
                )
            }
            outputBuffer.append(data)
            try validateLineLengths()
        }

        mutating func popMessage() throws -> [String: Any]? {
            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                let line = Data(outputBuffer[..<newline])
                outputBuffer.removeSubrange(...newline)
                guard !line.isEmpty else {
                    try recordBlankLine(byteCount: 1)
                    continue
                }
                return try decode(line)
            }
            return nil
        }

        mutating func finish() throws -> [String: Any]? {
            guard !outputBuffer.isEmpty else { return nil }
            let line = outputBuffer
            outputBuffer.removeAll(keepingCapacity: false)
            return try decode(line)
        }

        private func validateLineLengths() throws {
            var lineStart = outputBuffer.startIndex
            while lineStart < outputBuffer.endIndex,
                let newline = outputBuffer[lineStart...].firstIndex(of: 0x0A)
            {
                guard outputBuffer.distance(from: lineStart, to: newline) <= limits.maximumProtocolLineBytes else {
                    throw CodexAppServerError.protocolLimitExceeded(
                        "a JSON line exceeded \(limits.maximumProtocolLineBytes) bytes"
                    )
                }
                lineStart = outputBuffer.index(after: newline)
            }
            guard
                outputBuffer.distance(from: lineStart, to: outputBuffer.endIndex)
                    <= limits.maximumProtocolLineBytes
            else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "a JSON line exceeded \(limits.maximumProtocolLineBytes) bytes without a newline"
                )
            }
        }

        private mutating func decode(_ line: Data) throws -> [String: Any] {
            guard messageCount < limits.maximumMessages else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "more than \(limits.maximumMessages) JSON messages were received"
                )
            }
            messageCount += 1
            do {
                let value = try JSONSerialization.jsonObject(with: line, options: [])
                guard let dictionary = value as? [String: Any] else {
                    throw CodexAppServerError.malformedResponse("a JSON line was not an object")
                }
                return dictionary
            } catch let error as CodexAppServerError {
                throw error
            } catch {
                let preview = CodexAppServerLimits.boundedUTF8(
                    String(decoding: line, as: UTF8.self),
                    maximumBytes: limits.maximumErrorBytes
                )
                throw CodexAppServerError.malformedResponse(
                    "\(error.localizedDescription): \(preview)"
                )
            }
        }

        private mutating func recordBlankLine(byteCount: Int) throws {
            guard blankLineCount < limits.maximumBlankLines,
                byteCount <= limits.maximumBlankLineBytes - blankLineBytes
            else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "blank JSONL records exceeded their configured work budget"
                )
            }
            blankLineCount += 1
            blankLineBytes += byteCount
        }
    }

    struct CodexAppServerDeferredMessageQueue {
        private struct Entry {
            let message: [String: Any]
            let byteCount: Int
        }

        private var entries: [Entry] = []
        private(set) var byteCount = 0
        let limits: CodexAppServerLimits

        init(limits: CodexAppServerLimits = .production) {
            self.limits = limits
        }

        var count: Int { entries.count }

        mutating func append(_ message: [String: Any]) throws {
            let encoded = try JSONSerialization.data(withJSONObject: message, options: [])
            guard entries.count < limits.maximumDeferredMessages else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "more than \(limits.maximumDeferredMessages) unmatched messages were deferred"
                )
            }
            guard encoded.count <= limits.maximumDeferredBytes - byteCount else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "deferred messages exceeded \(limits.maximumDeferredBytes) bytes"
                )
            }
            entries.append(Entry(message: message, byteCount: encoded.count))
            byteCount += encoded.count
        }

        mutating func removeFirst() -> [String: Any]? {
            guard !entries.isEmpty else { return nil }
            let entry = entries.removeFirst()
            byteCount -= entry.byteCount
            return entry.message
        }

        mutating func removeFirst(where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
            guard let index = entries.firstIndex(where: { predicate($0.message) }) else { return nil }
            let entry = entries.remove(at: index)
            byteCount -= entry.byteCount
            return entry.message
        }
    }

    struct CodexRecapOutputCollector {
        private var streamed = ""
        private var streamedBytes = 0
        private var finalText: String?
        let limits: CodexAppServerLimits

        init(limits: CodexAppServerLimits = .production) {
            self.limits = limits
        }

        mutating func append(delta: String) throws {
            let deltaBytes = delta.utf8.count
            guard deltaBytes <= limits.maximumRecapCandidateBytes - streamedBytes else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "streamed recap output exceeded \(limits.maximumRecapCandidateBytes) bytes"
                )
            }
            streamed.append(delta)
            streamedBytes += deltaBytes
        }

        mutating func setFinalText(_ text: String) throws {
            guard text.utf8.count <= limits.maximumRecapCandidateBytes else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "final recap output exceeded \(limits.maximumRecapCandidateBytes) bytes"
                )
            }
            finalText = text
        }

        func completedMarkdown() throws -> String {
            let trimmed = (finalText ?? streamed).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CodexAppServerError.generationFailed("Codex returned an empty answer.")
            }

            let markdown: String
            if let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data, options: []),
                let dictionary = object as? [String: Any],
                let structuredMarkdown = dictionary["markdown"] as? String,
                !structuredMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                markdown = structuredMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                markdown = trimmed
            }
            guard let redactedMarkdown = ActivitySemanticTextSanitizer.redact(markdown),
                !redactedMarkdown.isEmpty
            else {
                throw CodexAppServerError.generationFailed("Codex returned an empty answer.")
            }
            guard redactedMarkdown.utf8.count <= limits.maximumRecapMarkdownBytes else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "recap Markdown exceeded \(limits.maximumRecapMarkdownBytes) bytes"
                )
            }
            return redactedMarkdown
        }
    }

    struct CodexAccount: Equatable {
        let type: String
        let email: String?
        let planType: String?

        var isManagedChatGPT: Bool { type.lowercased() == "chatgpt" }

        var displayPlan: String? {
            guard let planType, !planType.isEmpty else { return nil }
            return planType.prefix(1).uppercased() + planType.dropFirst()
        }
    }

    struct CodexLoginStart {
        let loginID: String
        let authorizationURL: URL
    }

    enum CodexExecutableLocator {
        static func locate(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            fileManager: FileManager = .default,
            bundle: Bundle = .main
        ) -> URL? {
            var candidates: [URL] = []

            if let override = environment["GOALONG_CODEX_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !override.isEmpty
            {
                candidates.append(URL(fileURLWithPath: override))
            }

            if let executableDirectory = bundle.executableURL?.deletingLastPathComponent() {
                candidates.append(executableDirectory.appendingPathComponent("codex", isDirectory: false))
                candidates.append(
                    executableDirectory
                        .deletingLastPathComponent()
                        .appendingPathComponent("Helpers/codex", isDirectory: false)
                )
            }
            if let sharedSupport = bundle.sharedSupportURL {
                candidates.append(sharedSupport.appendingPathComponent("codex", isDirectory: false))
            }

            let home = fileManager.homeDirectoryForCurrentUser
            candidates.append(contentsOf: [
                home.appendingPathComponent(".local/bin/codex", isDirectory: false),
                home.appendingPathComponent(".volta/bin/codex", isDirectory: false),
                home.appendingPathComponent(".bun/bin/codex", isDirectory: false),
                home.appendingPathComponent(".npm-global/bin/codex", isDirectory: false),
                home.appendingPathComponent("Library/pnpm/codex", isDirectory: false),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
                URL(fileURLWithPath: "/usr/bin/codex"),
            ])

            if let path = environment["PATH"] {
                candidates.append(
                    contentsOf: path.split(separator: ":").map {
                        URL(fileURLWithPath: String($0), isDirectory: true)
                            .appendingPathComponent("codex", isDirectory: false)
                    })
            }

            let nodeVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
            if let versions = try? fileManager.contentsOfDirectory(
                at: nodeVersions,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                candidates.append(
                    contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map {
                        $0.appendingPathComponent("bin/codex", isDirectory: false)
                    })
            }

            var seen = Set<String>()
            for candidate in candidates {
                let normalized = candidate.standardizedFileURL.path
                guard seen.insert(normalized).inserted else { continue }
                if fileManager.isExecutableFile(atPath: normalized) {
                    return URL(fileURLWithPath: normalized, isDirectory: false)
                }
            }
            return nil
        }
    }

    /// Minimal, reviewed stdio bridge to `codex app-server`.
    ///
    /// The bridge never invokes a shell and never accepts an arbitrary executable or argument list.
    /// Codex owns and refreshes ChatGPT credentials; Goalong only receives account metadata and
    /// streamed agent output. Each operation gets a fresh process and closes it afterwards.
    final class CodexAppServerSession {
        static let recapPermissionProfile = "goalong-recap"

        private let process = Process()
        private let inputPipe = Pipe()
        private let outputPipe = Pipe()
        private let errorPipe = Pipe()
        private let limits: CodexAppServerLimits
        private var stdoutDecoder: CodexAppServerMessageDecoder
        private var deferredMessages: CodexAppServerDeferredMessageQueue
        private var nextRequestID = 1
        private let stderrLock = NSLock()
        private var stderrData = Data()
        private let closeLock = NSLock()
        private var closed = false

        init(
            executableURL: URL,
            codexHomeURL: URL = AppPaths.chatGPTCodexHomeDirectory,
            limits: CodexAppServerLimits = .production
        ) throws {
            self.limits = limits
            stdoutDecoder = CodexAppServerMessageDecoder(limits: limits)
            deferredMessages = CodexAppServerDeferredMessageQueue(limits: limits)
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw CodexAppServerError.executableUnavailable
            }
            try Self.prepareCodexHome(at: codexHomeURL)

            process.executableURL = executableURL
            process.arguments = ["app-server"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try CodexAppServerTimedWriter.prepareNonBlocking(
                inputPipe.fileHandleForWriting.fileDescriptor
            )

            process.environment = Self.codexEnvironment(
                inheriting: ProcessInfo.processInfo.environment,
                codexHomeURL: codexHomeURL
            )

            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let self else { return }
                self.stderrLock.lock()
                defer { self.stderrLock.unlock() }
                let remaining = max(0, self.limits.maximumStderrBytes - self.stderrData.count)
                if remaining > 0 {
                    self.stderrData.append(data.prefix(remaining))
                }
            }

            do {
                try process.run()
            } catch {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                throw CodexAppServerError.launchFailed(error.localizedDescription)
            }

            do {
                let initialization = try request(
                    method: "initialize",
                    params: [
                        "clientInfo": [
                            "name": "goalong_history",
                            "title": "Goalong History",
                            "version": Self.applicationVersion,
                        ],
                        "capabilities": [
                            "experimentalApi": true
                        ],
                    ],
                    timeout: 15,
                    operation: "initializing the local agent"
                )
                guard let reportedHome = initialization["codexHome"] as? String else {
                    throw CodexAppServerError.malformedResponse(
                        "this Codex version does not report codexHome; update the Codex CLI"
                    )
                }
                let expectedHome = codexHomeURL.standardizedFileURL.resolvingSymlinksInPath()
                let actualHome = URL(fileURLWithPath: reportedHome, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard expectedHome == actualHome else {
                    throw CodexAppServerError.launchFailed(
                        "Codex ignored Goalong's isolated CODEX_HOME directory."
                    )
                }
                try send(
                    ["method": "initialized", "params": [:] as [String: Any]],
                    deadline: Date().addingTimeInterval(15),
                    operation: "acknowledging app-server initialization"
                )
            } catch {
                close()
                throw error
            }
        }

        deinit {
            close()
        }

        func readAccount(refreshToken: Bool = false) throws -> CodexAccount? {
            let result = try request(
                method: "account/read",
                params: ["refreshToken": refreshToken],
                timeout: 20,
                operation: "checking the ChatGPT account"
            )
            guard let rawAccount = result["account"] else { return nil }
            guard !(rawAccount is NSNull), let account = rawAccount as? [String: Any] else { return nil }
            guard let type = account["type"] as? String else {
                throw CodexAppServerError.malformedResponse("account.type is missing")
            }
            return CodexAccount(
                type: type,
                email: account["email"] as? String,
                planType: account["planType"] as? String
            )
        }

        func beginChatGPTLogin() throws -> CodexLoginStart {
            let result = try request(
                method: "account/login/start",
                params: [
                    "type": "chatgpt",
                    "useHostedLoginSuccessPage": true,
                    "appBrand": "chatgpt",
                ],
                timeout: 20,
                operation: "starting ChatGPT sign-in"
            )
            guard let loginID = result["loginId"] as? String, !loginID.isEmpty,
                let rawURL = result["authUrl"] as? String,
                let authorizationURL = URL(string: rawURL)
            else {
                throw CodexAppServerError.malformedResponse("the ChatGPT login URL is missing")
            }
            return CodexLoginStart(loginID: loginID, authorizationURL: authorizationURL)
        }

        func waitForChatGPTLogin(loginID: String, timeout: TimeInterval = 600) throws -> CodexAccount {
            let message = try waitForMessage(
                timeout: timeout,
                operation: "waiting for ChatGPT sign-in"
            ) { message in
                guard message["method"] as? String == "account/login/completed",
                    let params = message["params"] as? [String: Any]
                else { return false }
                return params["loginId"] as? String == loginID
            }

            guard let params = message["params"] as? [String: Any] else {
                throw CodexAppServerError.malformedResponse("login completion parameters are missing")
            }
            guard params["success"] as? Bool == true else {
                throw CodexAppServerError.loginFailed(params["error"] as? String ?? "")
            }
            guard let account = try readAccount(refreshToken: false), account.isManagedChatGPT else {
                throw CodexAppServerError.loginFailed("Codex did not report a managed ChatGPT account after login.")
            }
            return account
        }

        func logout() throws {
            _ = try request(
                method: "account/logout",
                params: [:],
                timeout: 20,
                operation: "disconnecting ChatGPT"
            )
        }

        func generateRecap(
            prompt: String,
            workingDirectory: URL,
            onDelta: ((String) -> Void)? = nil
        ) throws -> String {
            guard let account = try readAccount(refreshToken: true) else {
                throw CodexAppServerError.accountNotChatGPT("signed-out")
            }
            guard account.isManagedChatGPT else {
                throw CodexAppServerError.accountNotChatGPT(account.type)
            }

            let started = try request(
                method: "thread/start",
                params: [
                    "cwd": workingDirectory.path,
                    "runtimeWorkspaceRoots": [workingDirectory.path],
                    "approvalPolicy": "never",
                    "permissions": Self.recapPermissionProfile,
                    "ephemeral": true,
                    "environments": [] as [Any],
                    "personality": "pragmatic",
                    "serviceName": "goalong_history",
                ],
                timeout: 30,
                operation: "starting the recap agent"
            )
            guard let thread = started["thread"] as? [String: Any],
                let threadID = thread["id"] as? String,
                !threadID.isEmpty
            else {
                throw CodexAppServerError.malformedResponse("thread.id is missing")
            }
            guard thread["ephemeral"] as? Bool == true else {
                _ = try? request(
                    method: "thread/delete",
                    params: ["threadId": threadID],
                    timeout: 15,
                    operation: "removing the unexpected persistent recap thread"
                )
                throw CodexAppServerError.malformedResponse(
                    "Codex did not create an ephemeral thread; update the Codex CLI"
                )
            }
            guard let activeProfile = started["activePermissionProfile"] as? [String: Any],
                activeProfile["id"] as? String == Self.recapPermissionProfile
            else {
                throw CodexAppServerError.malformedResponse(
                    "Codex did not activate Goalong's restricted recap permission profile; update the Codex CLI"
                )
            }
            guard let roots = started["runtimeWorkspaceRoots"] as? [String],
                Self.pathsMatchExactly(roots, expected: [workingDirectory])
            else {
                throw CodexAppServerError.malformedResponse(
                    "Codex did not confine the recap to Goalong's temporary workspace"
                )
            }

            let schema: [String: Any] = [
                "type": "object",
                "properties": [
                    "markdown": ["type": "string"]
                ],
                "required": ["markdown"],
                "additionalProperties": false,
            ]
            _ = try request(
                method: "turn/start",
                params: [
                    "threadId": threadID,
                    "input": [["type": "text", "text": prompt]],
                    "cwd": workingDirectory.path,
                    "runtimeWorkspaceRoots": [workingDirectory.path],
                    "approvalPolicy": "never",
                    "permissions": Self.recapPermissionProfile,
                    "environments": [] as [Any],
                    "effort": "medium",
                    "summary": "concise",
                    "outputSchema": schema,
                ],
                timeout: 30,
                operation: "starting the recap turn"
            )

            let deadline = Date().addingTimeInterval(900)
            var output = CodexRecapOutputCollector(limits: limits)
            var streamingRedactor = CodexStreamingRedactor()
            var failureMessage: String?

            while Date() < deadline {
                let message = try nextDeferredOrMessage(
                    deadline: deadline,
                    operation: "generating the recap"
                )
                let method = try CodexAppServerMessageRouter.notificationMethod(in: message)
                let params = message["params"] as? [String: Any] ?? [:]

                switch method {
                case "item/agentMessage/delta":
                    if let delta = params["delta"] as? String, !delta.isEmpty {
                        try output.append(delta: delta)
                        let safeDelta = streamingRedactor.append(delta)
                        if !safeDelta.isEmpty { onDelta?(safeDelta) }
                    }
                case "item/completed":
                    if let item = params["item"] as? [String: Any],
                        item["type"] as? String == "agentMessage",
                        let text = item["text"] as? String,
                        !text.isEmpty
                    {
                        let phase = item["phase"] as? String
                        if phase == nil || phase == "final_answer" {
                            try output.setFinalText(text)
                        }
                    }
                case "error":
                    if let error = params["error"] as? [String: Any] {
                        failureMessage = (error["message"] as? String).map {
                            CodexAppServerLimits.boundedUTF8(
                                $0,
                                maximumBytes: limits.maximumErrorBytes
                            )
                        }
                    }
                case "turn/completed":
                    guard let turn = params["turn"] as? [String: Any] else {
                        throw CodexAppServerError.malformedResponse("turn completion is missing")
                    }
                    let status = turn["status"] as? String ?? "unknown"
                    if status == "completed" {
                        let safeTail = streamingRedactor.finish()
                        if !safeTail.isEmpty { onDelta?(safeTail) }
                        return try output.completedMarkdown()
                    }
                    let error = turn["error"] as? [String: Any]
                    let message = CodexAppServerLimits.boundedUTF8(
                        error?["message"] as? String ?? failureMessage ?? status,
                        maximumBytes: limits.maximumErrorBytes
                    )
                    throw CodexAppServerError.generationFailed(message)
                default:
                    break
                }
            }
            throw CodexAppServerError.timeout("generating the recap")
        }

        func close() {
            closeLock.lock()
            guard !closed else {
                closeLock.unlock()
                return
            }
            closed = true
            closeLock.unlock()

            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
            }
        }

        private func request(
            method: String,
            params: [String: Any],
            timeout: TimeInterval,
            operation: String
        ) throws -> [String: Any] {
            let id = nextRequestID
            nextRequestID += 1
            let deadline = Date().addingTimeInterval(timeout)
            try send(
                ["method": method, "id": id, "params": params],
                deadline: deadline,
                operation: operation
            )

            while Date() < deadline {
                let message = try nextMessage(deadline: deadline, operation: operation)
                if let responseID = try CodexAppServerMessageRouter.responseID(in: message) {
                    guard responseID == id else {
                        throw CodexAppServerError.malformedResponse(
                            "an unmatched JSON-RPC response was received"
                        )
                    }
                    return try responseResult(message, method: method)
                }
                _ = try CodexAppServerMessageRouter.notificationMethod(in: message)
                try deferredMessages.append(message)
            }
            throw CodexAppServerError.timeout(operation)
        }

        private func waitForMessage(
            timeout: TimeInterval,
            operation: String,
            predicate: ([String: Any]) -> Bool
        ) throws -> [String: Any] {
            if let message = deferredMessages.removeFirst(where: predicate) {
                return message
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let message = try nextMessage(deadline: deadline, operation: operation)
                _ = try CodexAppServerMessageRouter.notificationMethod(in: message)
                if predicate(message) { return message }
                try deferredMessages.append(message)
            }
            throw CodexAppServerError.timeout(operation)
        }

        private func send(
            _ object: [String: Any],
            deadline: Date,
            operation: String
        ) throws {
            let data = try CodexAppServerWireEncoder.encode(object, limits: limits)
            try CodexAppServerTimedWriter.write(
                data,
                to: inputPipe.fileHandleForWriting.fileDescriptor,
                deadline: deadline,
                operation: operation,
                errorDetail: { [weak self] in self?.stderrText() ?? "" }
            )
        }

        private func nextDeferredOrMessage(
            deadline: Date,
            operation: String
        ) throws -> [String: Any] {
            if let message = deferredMessages.removeFirst(where: { $0["method"] is String }) {
                return message
            }
            let message = try nextMessage(deadline: deadline, operation: operation)
            _ = try CodexAppServerMessageRouter.notificationMethod(in: message)
            return message
        }

        private func nextMessage(deadline: Date, operation: String) throws -> [String: Any] {
            while true {
                if let message = try stdoutDecoder.popMessage() {
                    return message
                }

                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw CodexAppServerError.timeout(operation) }
                let timeoutMilliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
                var descriptor = pollfd(
                    fd: outputPipe.fileHandleForReading.fileDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollResult = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
                if pollResult == 0 {
                    throw CodexAppServerError.timeout(operation)
                }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw CodexAppServerError.processExited(stderrText())
                }

                let data: Data
                do {
                    data = try outputPipe.fileHandleForReading.read(upToCount: 65_536) ?? Data()
                } catch {
                    throw CodexAppServerError.processExited(stderrText())
                }
                if data.isEmpty {
                    if let message = try stdoutDecoder.finish() {
                        return message
                    }
                    throw CodexAppServerError.processExited(stderrText())
                }
                try stdoutDecoder.append(data)
            }
        }

        private func stderrText() -> String {
            stderrLock.lock()
            let data = stderrData
            stderrLock.unlock()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexAppServerLimits.boundedUTF8(
                text,
                maximumBytes: limits.maximumErrorBytes
            )
        }

        private func responseResult(
            _ message: [String: Any],
            method: String
        ) throws -> [String: Any] {
            if let error = message["error"] as? [String: Any] {
                let detail = CodexAppServerLimits.boundedUTF8(
                    error["message"] as? String ?? "Unknown JSON-RPC error",
                    maximumBytes: limits.maximumErrorBytes
                )
                throw CodexAppServerError.server(detail)
            }
            guard let result = message["result"] as? [String: Any] else {
                if message["result"] is NSNull { return [:] }
                throw CodexAppServerError.malformedResponse("result for \(method) is missing")
            }
            return result
        }

        static func prepareCodexHome(at directory: URL) throws {
            try ChatGPTSecureStorage.prepareDirectory(directory)

            // This file is app-managed and intentionally rewritten at every launch. Authentication
            // remains in Codex-owned files inside this isolated directory; stale or user-modified
            // permissions must never silently broaden a recap agent's access.
            let configURL = directory.appendingPathComponent("config.toml", isDirectory: false)
            let config = Data(
                """
                # Goalong History owns this isolated Codex home.
                # Evidence is provided inline. Tools may read only platform-minimal files and
                # Goalong's empty per-run workspace; they cannot write or use network access.
                web_search = "disabled"
                default_permissions = "\(Self.recapPermissionProfile)"
                approval_policy = "never"
                allow_login_shell = false
                include_environment_context = false
                include_permissions_instructions = false
                include_apps_instructions = false
                include_collaboration_mode_instructions = false
                cli_auth_credentials_store = "file"

                [orchestrator.skills]
                enabled = false

                [orchestrator.mcp]
                enabled = false

                [permissions.goalong-recap]
                description = "Goalong recap: minimal runtime plus read-only access to the isolated run workspace"

                [permissions.goalong-recap.filesystem]
                ":minimal" = "read"
                ":workspace_roots" = "read"

                [permissions.goalong-recap.network]
                enabled = false
                """.utf8
            )
            try ChatGPTSecureStorage.writeFileAtomically(config, to: configURL)
        }

        static func codexEnvironment(
            inheriting inherited: [String: String],
            codexHomeURL: URL
        ) -> [String: String] {
            // Do not expose API keys, cloud credentials, proxy passwords, SSH agent sockets or
            // arbitrary app secrets to a tool-capable model. The allow-list contains only values
            // required to launch a user-installed Codex binary and basic locale/process metadata.
            let allowedKeys = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE"]
            var environment: [String: String] = [:]
            for key in allowedKeys {
                if let value = inherited[key], !value.isEmpty {
                    environment[key] = value
                }
            }
            if environment["PATH"] == nil {
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            }
            environment["NO_COLOR"] = "1"
            environment["TERM"] = "dumb"
            environment["SHELL"] = "/bin/zsh"
            environment["CODEX_HOME"] = codexHomeURL.path
            return environment
        }

        private static func pathsMatchExactly(_ rawPaths: [String], expected: [URL]) -> Bool {
            guard rawPaths.count == expected.count else { return false }
            let actual = rawPaths.map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            }
            let wanted = expected.map {
                $0.standardizedFileURL.resolvingSymlinksInPath()
            }
            return actual == wanted
        }

        private static var applicationVersion: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        }
    }
#endif
