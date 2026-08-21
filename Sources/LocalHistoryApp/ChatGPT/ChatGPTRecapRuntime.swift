#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import UniformTypeIdentifiers

    enum ChatGPTConnectionState: Equatable {
        case checking
        case codexUnavailable
        case signedOut
        case connected(email: String?, plan: String?)
        case unsupportedCredentialMode(String)
        case failed(String)
    }

    struct ChatGPTDailyRecap: Codable, Equatable {
        let schemaVersion: Int
        let day: Date
        let generatedAt: Date
        let provider: String
        let planType: String?
        let contextDigest: String
        let sourceCounts: ChatGPTRecapSourceCounts
        let markdown: String

        init(
            schemaVersion: Int = 1,
            day: Date,
            generatedAt: Date = Date(),
            provider: String = "codex_app_server_chatgpt",
            planType: String?,
            contextDigest: String,
            sourceCounts: ChatGPTRecapSourceCounts,
            markdown: String
        ) {
            self.schemaVersion = schemaVersion
            self.day = Calendar.current.startOfDay(for: day)
            self.generatedAt = generatedAt
            self.provider = provider
            self.planType = planType
            self.contextDigest = contextDigest
            self.sourceCounts = sourceCounts
            self.markdown = markdown
        }
    }

    struct ChatGPTRecapAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    final class ChatGPTRecapRuntime: ObservableObject {
        static let shared = ChatGPTRecapRuntime()

        @Published private(set) var connectionState: ChatGPTConnectionState = .checking
        @Published private(set) var recap: ChatGPTDailyRecap?
        @Published private(set) var importSummary: ChatGPTImportSummary?
        @Published private(set) var isCheckingAccount = false
        @Published private(set) var isConnecting = false
        @Published private(set) var isGenerating = false
        @Published private(set) var isImporting = false
        @Published private(set) var streamedMarkdown = ""
        @Published var selectedDay: Date
        @Published var automaticRecapsEnabled: Bool {
            didSet {
                UserDefaults.standard.set(automaticRecapsEnabled, forKey: Self.automaticRecapsKey)
                if automaticRecapsEnabled { maybeGenerateAutomaticRecap() }
            }
        }
        @Published var alert: ChatGPTRecapAlert?

        private let workQueue = DispatchQueue(
            label: "ai.goalong.localhistory.chatgpt-recap",
            qos: .userInitiated
        )
        private let chatHistoryStore = ChatGPTHistoryStore(rootDirectory: AppPaths.chatGPTHistoryDirectory)
        private let fileManager = FileManager.default
        private let sessionLock = NSLock()
        private var activeSession: CodexAppServerSession?
        private var deviceID = ""
        private var timer: Timer?
        private var started = false

        private static let automaticRecapsKey = "chatgptRecap.automaticEnabled"
        private static let automaticRefreshInterval: TimeInterval = 4 * 60 * 60

        private init() {
            let today = Calendar.current.startOfDay(for: Date())
            selectedDay = today
            automaticRecapsEnabled = UserDefaults.standard.bool(forKey: Self.automaticRecapsKey)
            recap = Self.loadStoredRecap(for: today)
            importSummary = chatHistoryStore.summary()
        }

        deinit {
            timer?.invalidate()
        }

        var codexExecutableURL: URL? { CodexExecutableLocator.locate() }

        func configure(deviceID: String) {
            let clean = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { self.deviceID = clean }
            recap = Self.loadStoredRecap(for: selectedDay)
            importSummary = chatHistoryStore.summary()
            refreshAccount()
        }

        func start() {
            guard !started else { return }
            started = true
            let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
                self?.maybeGenerateAutomaticRecap()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                self?.maybeGenerateAutomaticRecap()
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            started = false
            closeActiveSession()
        }

        func selectDay(_ date: Date) {
            let normalized = Calendar.current.startOfDay(for: date)
            guard normalized != selectedDay else { return }
            selectedDay = normalized
            streamedMarkdown = ""
            recap = Self.loadStoredRecap(for: normalized)
        }

        func refreshAccount() {
            guard !isCheckingAccount, !isConnecting else { return }
            guard let executable = CodexExecutableLocator.locate() else {
                connectionState = .codexUnavailable
                return
            }
            isCheckingAccount = true
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let session = try self.makeSession(executableURL: executable)
                    defer { self.closeSession(session) }
                    let account = try session.readAccount(refreshToken: false)
                    DispatchQueue.main.async {
                        self.isCheckingAccount = false
                        self.publishAccount(account)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isCheckingAccount = false
                        self.connectionState = .failed(error.localizedDescription)
                    }
                }
            }
        }

        func connectChatGPT() {
            guard !isConnecting else { return }
            guard let executable = CodexExecutableLocator.locate() else {
                connectionState = .codexUnavailable
                return
            }
            isConnecting = true
            connectionState = .checking

            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let session = try self.makeSession(executableURL: executable)
                    defer { self.closeSession(session) }
                    let login = try session.beginChatGPTLogin()
                    DispatchQueue.main.async {
                        _ = NSWorkspace.shared.open(login.authorizationURL)
                    }
                    let account = try session.waitForChatGPTLogin(loginID: login.loginID)
                    DispatchQueue.main.async {
                        self.isConnecting = false
                        self.publishAccount(account)
                        self.alert = ChatGPTRecapAlert(
                            title: "ChatGPT connected",
                            message:
                                "Goalong can now launch recap agents with the usage included in this ChatGPT plan. Codex keeps the managed credentials in Goalong's private, isolated Codex directory; Goalong never reads or copies the token values."
                        )
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isConnecting = false
                        self.connectionState = .failed(error.localizedDescription)
                        self.alert = ChatGPTRecapAlert(
                            title: "ChatGPT could not be connected",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }

        func disconnectChatGPT() {
            guard let executable = CodexExecutableLocator.locate() else {
                connectionState = .codexUnavailable
                return
            }
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let session = try self.makeSession(executableURL: executable)
                    defer { self.closeSession(session) }
                    try session.logout()
                    DispatchQueue.main.async {
                        self.connectionState = .signedOut
                        self.alert = ChatGPTRecapAlert(
                            title: "ChatGPT disconnected",
                            message: "Codex removed the managed ChatGPT credentials from Goalong's isolated account directory. Your normal Codex CLI login was not changed."
                        )
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.alert = ChatGPTRecapAlert(
                            title: "ChatGPT could not be disconnected",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }

        func generateRecap() {
            generateRecap(for: selectedDay, automatic: false)
        }

        func importChatGPTHistory() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]
            panel.message = "Choose conversations.json from an extracted ChatGPT data export."
            panel.prompt = "Import conversations"
            guard panel.runModal() == .OK, let source = panel.url else { return }
            importChatGPTHistory(from: source)
        }

        func importChatGPTHistory(from sourceURL: URL) {
            guard !isImporting else { return }
            isImporting = true
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let summary = try self.chatHistoryStore.importConversations(from: sourceURL)
                    DispatchQueue.main.async {
                        self.isImporting = false
                        self.importSummary = summary
                        self.alert = ChatGPTRecapAlert(
                            title: "ChatGPT history imported",
                            message:
                                "Imported \(summary.messageCount) sanitized user/assistant messages from \(summary.conversationCount) conversations. The normalized copy stays on this Mac."
                        )
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isImporting = false
                        self.alert = ChatGPTRecapAlert(
                            title: "ChatGPT history could not be imported",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }

        func clearImportedChatGPTHistory() {
            do {
                try chatHistoryStore.removeImport()
                importSummary = nil
                alert = ChatGPTRecapAlert(
                    title: "Imported ChatGPT history deleted",
                    message: "The normalized local import was removed. Existing generated recaps were not deleted."
                )
            } catch {
                alert = ChatGPTRecapAlert(
                    title: "Imported history could not be deleted",
                    message: error.localizedDescription
                )
            }
        }

        func openCodexInstallGuide() {
            guard let url = URL(string: "https://developers.openai.com/codex/cli") else { return }
            NSWorkspace.shared.open(url)
        }

        func revealRecapFiles() {
            do {
                try Self.prepareDirectories()
                let files = [Self.markdownURL(for: selectedDay), Self.JSONURL(for: selectedDay)]
                    .filter { fileManager.fileExists(atPath: $0.path) }
                if files.isEmpty {
                    NSWorkspace.shared.open(AppPaths.chatGPTRecapsDirectory)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting(files)
                }
            } catch {
                alert = ChatGPTRecapAlert(title: "Recap folder could not be opened", message: error.localizedDescription)
            }
        }

        private func generateRecap(for day: Date, automatic: Bool) {
            guard !isGenerating else { return }
            guard !deviceID.isEmpty else {
                if !automatic {
                    alert = ChatGPTRecapAlert(
                        title: "Goalong is still starting",
                        message: "The local device identity is not available yet."
                    )
                }
                return
            }
            guard let executable = CodexExecutableLocator.locate() else {
                connectionState = .codexUnavailable
                if !automatic {
                    alert = ChatGPTRecapAlert(
                        title: "Codex is required",
                        message: CodexAppServerError.executableUnavailable.localizedDescription
                    )
                }
                return
            }

            let normalizedDay = Calendar.current.startOfDay(for: day)
            isGenerating = true
            streamedMarkdown = ""

            workQueue.async { [weak self] in
                guard let self else { return }
                var runDirectory: URL?
                do {
                    let context = try ChatGPTRecapContextBuilder.build(
                        for: normalizedDay,
                        deviceID: self.deviceID,
                        chatHistoryStore: self.chatHistoryStore
                    )
                    guard context.hasMeaningfulData else {
                        throw CodexAppServerError.generationFailed("There is no captured context for this day yet.")
                    }

                    let directory = try Self.makeRunDirectory()
                    runDirectory = directory
                    let session = try self.makeSession(executableURL: executable)
                    defer { self.closeSession(session) }
                    guard let account = try session.readAccount(refreshToken: true) else {
                        throw CodexAppServerError.accountNotChatGPT("signed-out")
                    }
                    guard account.isManagedChatGPT else {
                        throw CodexAppServerError.accountNotChatGPT(account.type)
                    }

                    let prompt = ChatGPTRecapContextBuilder.prompt(
                        for: context,
                        outputLanguage: Self.outputLanguage
                    )
                    var accumulated = ""
                    let markdown = try session.generateRecap(
                        prompt: prompt,
                        workingDirectory: directory,
                        onDelta: { [weak self] delta in
                            accumulated += delta
                            let snapshot = accumulated
                            DispatchQueue.main.async {
                                guard let self, self.isGenerating else { return }
                                self.streamedMarkdown = snapshot
                            }
                        }
                    )
                    let result = ChatGPTDailyRecap(
                        day: normalizedDay,
                        planType: account.planType,
                        contextDigest: context.digest,
                        sourceCounts: context.sourceCounts,
                        markdown: markdown
                    )
                    try Self.write(result)
                    if let runDirectory { try? self.fileManager.removeItem(at: runDirectory) }

                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.streamedMarkdown = ""
                        self.publishAccount(account)
                        if Calendar.current.isDate(self.selectedDay, inSameDayAs: normalizedDay) {
                            self.recap = result
                        }
                        if !automatic {
                            self.alert = ChatGPTRecapAlert(
                                title: "Daily recap generated",
                                message:
                                    "The recap is stored locally. Only the bounded, sanitized context assembled for this run was sent through Codex."
                            )
                        }
                    }
                } catch {
                    if let runDirectory { try? self.fileManager.removeItem(at: runDirectory) }
                    Diagnostics.write("ChatGPT recap generation failed: \(error)")
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.streamedMarkdown = ""
                        if let codexError = error as? CodexAppServerError {
                            switch codexError {
                            case .accountNotChatGPT(let mode):
                                self.connectionState = mode == "signed-out"
                                    ? .signedOut
                                    : .unsupportedCredentialMode(mode)
                            case .executableUnavailable:
                                self.connectionState = .codexUnavailable
                            default:
                                break
                            }
                        }
                        if !automatic {
                            self.alert = ChatGPTRecapAlert(
                                title: "The recap could not be generated",
                                message: error.localizedDescription
                            )
                        }
                    }
                }
            }
        }

        private func makeSession(executableURL: URL) throws -> CodexAppServerSession {
            let session = try CodexAppServerSession(executableURL: executableURL)
            sessionLock.lock()
            activeSession = session
            sessionLock.unlock()
            return session
        }

        private func closeSession(_ session: CodexAppServerSession) {
            session.close()
            sessionLock.lock()
            if activeSession === session {
                activeSession = nil
            }
            sessionLock.unlock()
        }

        private func closeActiveSession() {
            sessionLock.lock()
            let session = activeSession
            activeSession = nil
            sessionLock.unlock()
            session?.close()
        }

        private func maybeGenerateAutomaticRecap() {
            guard automaticRecapsEnabled, !isGenerating else { return }
            guard case .connected = connectionState else { return }
            let today = Calendar.current.startOfDay(for: Date())
            if let stored = Self.loadStoredRecap(for: today),
                Date().timeIntervalSince(stored.generatedAt) < Self.automaticRefreshInterval
            {
                return
            }
            generateRecap(for: today, automatic: true)
        }

        private func publishAccount(_ account: CodexAccount?) {
            guard let account else {
                connectionState = .signedOut
                return
            }
            if account.isManagedChatGPT {
                connectionState = .connected(email: account.email, plan: account.displayPlan)
            } else {
                connectionState = .unsupportedCredentialMode(account.type)
            }
        }

        private static func prepareDirectories() throws {
            for directory in [
                AppPaths.chatGPTDirectory,
                AppPaths.chatGPTHistoryDirectory,
                AppPaths.chatGPTRecapsDirectory,
                AppPaths.chatGPTRunsDirectory,
                AppPaths.chatGPTCodexHomeDirectory,
            ] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        }

        private static func makeRunDirectory() throws -> URL {
            try prepareDirectories()
            let directory = AppPaths.chatGPTRunsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return directory
        }

        private static func write(_ recap: ChatGPTDailyRecap) throws {
            try prepareDirectories()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try secureWrite(try encoder.encode(recap), to: JSONURL(for: recap.day))
            try secureWrite(Data(recap.markdown.utf8), to: markdownURL(for: recap.day))
        }

        private static func loadStoredRecap(for day: Date) -> ChatGPTDailyRecap? {
            guard let data = try? Data(contentsOf: JSONURL(for: day)) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ChatGPTDailyRecap.self, from: data)
        }

        private static func secureWrite(_ data: Data, to destination: URL) throws {
            try data.write(to: destination, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }

        private static func JSONURL(for day: Date) -> URL {
            AppPaths.chatGPTRecapsDirectory.appendingPathComponent(
                "\(AppPaths.localDayString(for: day)).chatgpt-recap.json", isDirectory: false)
        }

        private static func markdownURL(for day: Date) -> URL {
            AppPaths.chatGPTRecapsDirectory.appendingPathComponent(
                "\(AppPaths.localDayString(for: day)).chatgpt-recap.md", isDirectory: false)
        }

        private static var outputLanguage: String {
            if #available(macOS 13, *), Locale.current.language.languageCode?.identifier == "fr" {
                return "French"
            }
            return "English"
        }
    }
#endif
