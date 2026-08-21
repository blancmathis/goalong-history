#if os(macOS)
    import AppKit
    import Darwin
    import Foundation

    enum CodexAppServerError: LocalizedError {
        case executableUnavailable
        case launchFailed(String)
        case processExited(String)
        case timeout(String)
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
                return "Codex app-server could not start: \(message)"
            case .processExited(let message):
                return message.isEmpty
                    ? "Codex app-server stopped unexpectedly."
                    : "Codex app-server stopped unexpectedly: \(message)"
            case .timeout(let operation):
                return "Codex timed out while \(operation)."
            case .malformedResponse(let message):
                return "Codex returned an invalid response: \(message)"
            case .server(let message):
                return "Codex reported an error: \(message)"
            case .loginFailed(let message):
                return message.isEmpty ? "ChatGPT sign-in did not complete." : "ChatGPT sign-in failed: \(message)"
            case .accountNotChatGPT(let mode):
                return "Goalong will not use the active \(mode) credentials because they may be billed as API usage. Connect with ChatGPT instead."
            case .generationFailed(let message):
                return message.isEmpty ? "The recap agent failed." : "The recap agent failed: \(message)"
            }
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
                candidates.append(contentsOf: path.split(separator: ":").map {
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
                candidates.append(contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map {
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
        private var outputBuffer = Data()
        private var deferredMessages: [[String: Any]] = []
        private var nextRequestID = 1
        private let stderrLock = NSLock()
        private var stderrData = Data()
        private let closeLock = NSLock()
        private var closed = false

        init(
            executableURL: URL,
            codexHomeURL: URL = AppPaths.chatGPTCodexHomeDirectory
        ) throws {
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw CodexAppServerError.executableUnavailable
            }
            try Self.prepareCodexHome(at: codexHomeURL)

            process.executableURL = executableURL
            process.arguments = ["app-server"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.environment = Self.codexEnvironment(
                inheriting: ProcessInfo.processInfo.environment,
                codexHomeURL: codexHomeURL
            )

            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let self else { return }
                self.stderrLock.lock()
                defer { self.stderrLock.unlock() }
                let remaining = max(0, 65_536 - self.stderrData.count)
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
                try send(["method": "initialized", "params": [:] as [String: Any]])
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
            var streamed = ""
            var finalText: String?
            var failureMessage: String?

            while Date() < deadline {
                let message = try nextDeferredOrMessage(
                    deadline: deadline,
                    operation: "generating the recap"
                )
                guard let method = message["method"] as? String else {
                    deferredMessages.append(message)
                    continue
                }
                let params = message["params"] as? [String: Any] ?? [:]

                switch method {
                case "item/agentMessage/delta":
                    if let delta = params["delta"] as? String, !delta.isEmpty {
                        streamed += delta
                        onDelta?(delta)
                    }
                case "item/completed":
                    if let item = params["item"] as? [String: Any],
                        item["type"] as? String == "agentMessage",
                        let text = item["text"] as? String,
                        !text.isEmpty
                    {
                        let phase = item["phase"] as? String
                        if phase == nil || phase == "final_answer" {
                            finalText = text
                        }
                    }
                case "error":
                    if let error = params["error"] as? [String: Any] {
                        failureMessage = error["message"] as? String
                    }
                case "turn/completed":
                    guard let turn = params["turn"] as? [String: Any] else {
                        throw CodexAppServerError.malformedResponse("turn completion is missing")
                    }
                    let status = turn["status"] as? String ?? "unknown"
                    if status == "completed" {
                        let candidate = finalText ?? streamed
                        return try Self.extractMarkdown(from: candidate)
                    }
                    let error = turn["error"] as? [String: Any]
                    let message = error?["message"] as? String ?? failureMessage ?? status
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
            try send(["method": method, "id": id, "params": params])
            let deadline = Date().addingTimeInterval(timeout)

            while Date() < deadline {
                let message = try nextMessage(deadline: deadline, operation: operation)
                if Self.integerID(from: message["id"]) == id {
                    if let error = message["error"] as? [String: Any] {
                        throw CodexAppServerError.server(error["message"] as? String ?? "Unknown JSON-RPC error")
                    }
                    guard let result = message["result"] as? [String: Any] else {
                        if message["result"] is NSNull { return [:] }
                        throw CodexAppServerError.malformedResponse("result for \(method) is missing")
                    }
                    return result
                }
                deferredMessages.append(message)
            }
            throw CodexAppServerError.timeout(operation)
        }

        private func waitForMessage(
            timeout: TimeInterval,
            operation: String,
            predicate: ([String: Any]) -> Bool
        ) throws -> [String: Any] {
            if let index = deferredMessages.firstIndex(where: predicate) {
                return deferredMessages.remove(at: index)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let message = try nextMessage(deadline: deadline, operation: operation)
                if predicate(message) { return message }
                deferredMessages.append(message)
            }
            throw CodexAppServerError.timeout(operation)
        }

        private func send(_ object: [String: Any]) throws {
            guard JSONSerialization.isValidJSONObject(object) else {
                throw CodexAppServerError.malformedResponse("client attempted to send invalid JSON")
            }
            var data = try JSONSerialization.data(withJSONObject: object, options: [])
            data.append(0x0A)
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw CodexAppServerError.processExited(stderrText())
            }
        }

        private func nextDeferredOrMessage(
            deadline: Date,
            operation: String
        ) throws -> [String: Any] {
            if !deferredMessages.isEmpty {
                return deferredMessages.removeFirst()
            }
            return try nextMessage(deadline: deadline, operation: operation)
        }

        private func nextMessage(deadline: Date, operation: String) throws -> [String: Any] {
            while true {
                if let line = popBufferedLine() {
                    guard !line.isEmpty else { continue }
                    do {
                        let value = try JSONSerialization.jsonObject(with: line, options: [])
                        guard let dictionary = value as? [String: Any] else {
                            throw CodexAppServerError.malformedResponse("a JSON line was not an object")
                        }
                        return dictionary
                    } catch let error as CodexAppServerError {
                        throw error
                    } catch {
                        let preview = String(data: line.prefix(512), encoding: .utf8) ?? "<binary>"
                        throw CodexAppServerError.malformedResponse("\(error.localizedDescription): \(preview)")
                    }
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
                    throw CodexAppServerError.processExited(stderrText())
                }
                outputBuffer.append(data)
            }
        }

        private func popBufferedLine() -> Data? {
            guard let newline = outputBuffer.firstIndex(of: 0x0A) else { return nil }
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            return line
        }

        private func stderrText() -> String {
            stderrLock.lock()
            let data = stderrData
            stderrLock.unlock()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        private static func integerID(from value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            if let integer = value as? Int { return integer }
            return nil
        }

        static func prepareCodexHome(at directory: URL) throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

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
            try config.write(to: configURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
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

        private static func extractMarkdown(from raw: String) throws -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CodexAppServerError.generationFailed("Codex returned an empty answer.")
            }

            if let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data, options: []),
                let dictionary = object as? [String: Any],
                let markdown = dictionary["markdown"] as? String,
                !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }

        private static var applicationVersion: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        }
    }
#endif
