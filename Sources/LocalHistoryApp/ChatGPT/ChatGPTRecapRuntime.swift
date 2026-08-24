#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import LocalHistoryCore
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

    enum ChatGPTRecapPersistence {
        typealias Writer = (Data, URL) throws -> Void

        static let maximumMarkdownBytes = CodexAppServerLimits.production.maximumRecapMarkdownBytes
        static let maximumJSONBytes = 8 * 1_024 * 1_024

        static func write(
            _ recap: ChatGPTDailyRecap,
            to directory: URL,
            fileManager: FileManager = .default,
            writer: Writer? = nil
        ) throws {
            guard let redactedMarkdown = ActivitySemanticTextSanitizer.redact(recap.markdown),
                !redactedMarkdown.isEmpty
            else {
                throw CodexAppServerError.generationFailed("The recap contained no persistable text.")
            }
            let persistedRecap = ChatGPTDailyRecap(
                schemaVersion: recap.schemaVersion,
                day: recap.day,
                generatedAt: recap.generatedAt,
                provider: recap.provider,
                planType: recap.planType,
                contextDigest: recap.contextDigest,
                sourceCounts: recap.sourceCounts,
                markdown: redactedMarkdown
            )
            let markdownData = Data(redactedMarkdown.utf8)
            guard markdownData.count <= maximumMarkdownBytes else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "recap Markdown exceeded \(maximumMarkdownBytes) bytes before persistence"
                )
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let jsonData = try encoder.encode(persistedRecap)
            guard jsonData.count <= maximumJSONBytes else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "recap JSON exceeded \(maximumJSONBytes) bytes before persistence"
                )
            }

            try ChatGPTSecureStorage.prepareDirectory(directory)
            let jsonURL = jsonURL(for: persistedRecap.day, in: directory)
            let markdownURL = markdownURL(for: persistedRecap.day, in: directory)
            let previousRecap = load(for: persistedRecap.day, from: directory)
            let writeData =
                writer ?? { data, destination in
                    try secureWrite(data, to: destination, fileManager: fileManager)
                }

            // JSON is the sole canonical commit. Install the Markdown mirror first, then
            // atomically replace JSON. A failed JSON commit restores/removes the mirror so
            // readers never accept a partially advanced recap.
            try writeData(markdownData, markdownURL)
            do {
                try writeData(jsonData, jsonURL)
            } catch {
                if let previousRecap {
                    try? secureWrite(
                        Data(previousRecap.markdown.utf8),
                        to: markdownURL,
                        fileManager: fileManager
                    )
                } else {
                    try? ChatGPTSecureStorage.removeRegularFileIfPresent(at: markdownURL)
                }
                throw error
            }
        }

        static func load(
            for day: Date,
            from directory: URL,
            fileManager _: FileManager = .default
        ) -> ChatGPTDailyRecap? {
            let url = jsonURL(for: day, in: directory)
            guard
                let data = try? ChatGPTHistoryStore.readStableSource(
                    at: url,
                    maximumBytes: Int64(maximumJSONBytes)
                )
            else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let recap = try? decoder.decode(ChatGPTDailyRecap.self, from: data),
                recap.schemaVersion == 1,
                recap.markdown.utf8.count <= maximumMarkdownBytes
            else { return nil }
            return recap
        }

        static func revealFiles(
            for day: Date,
            in directory: URL,
            fileManager: FileManager = .default
        ) throws -> [URL] {
            let markdownURL = markdownURL(for: day, in: directory)
            guard let recap = load(for: day, from: directory) else {
                try ChatGPTSecureStorage.removeRegularFileIfPresent(at: markdownURL)
                return []
            }
            let jsonURL = jsonURL(for: day, in: directory)
            try secureWrite(
                Data(recap.markdown.utf8),
                to: markdownURL,
                fileManager: fileManager
            )
            return [markdownURL, jsonURL]
        }

        static func jsonURL(for day: Date, in directory: URL) -> URL {
            directory.appendingPathComponent(
                "\(AppPaths.localDayString(for: day)).chatgpt-recap.json",
                isDirectory: false
            )
        }

        static func markdownURL(for day: Date, in directory: URL) -> URL {
            directory.appendingPathComponent(
                "\(AppPaths.localDayString(for: day)).chatgpt-recap.md",
                isDirectory: false
            )
        }

        private static func secureWrite(
            _ data: Data,
            to destination: URL,
            fileManager _: FileManager
        ) throws {
            try ChatGPTSecureStorage.writeFileAtomically(data, to: destination)
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
        private let chatHistoryStore: ChatGPTHistoryStore
        private let fileManager: FileManager
        private let recapsDirectory: URL
        private let executableLocator: () -> URL?
        private let sessionFactory: (URL) throws -> CodexAppServerSession
        private let directoryOpener: (URL) -> Void
        private let fileRevealer: ([URL]) -> Void
        private let delayedAutomaticScheduler: (DispatchWorkItem) -> Void
        private let derivedWriteBarrier = DerivedHistoryWriteBarrier.shared
        private let sessionLock = NSLock()
        private let runStateLock = NSLock()
        private var activeSession: CodexAppServerSession?
        private var activeRecapRunID: UUID?
        private var deviceID = ""
        private var timer: Timer?
        private var delayedAutomaticWorkItem: DispatchWorkItem?
        private var started = false

        private static let automaticRecapsKey = "chatgptRecap.automaticEnabled"
        private static let automaticRefreshInterval: TimeInterval = 4 * 60 * 60

        init(
            chatHistoryStore: ChatGPTHistoryStore = ChatGPTHistoryStore(
                rootDirectory: AppPaths.chatGPTHistoryDirectory
            ),
            fileManager: FileManager = .default,
            recapsDirectory: URL = AppPaths.chatGPTRecapsDirectory,
            executableLocator: @escaping () -> URL? = { CodexExecutableLocator.locate() },
            sessionFactory: @escaping (URL) throws -> CodexAppServerSession = {
                try CodexAppServerSession(executableURL: $0)
            },
            directoryOpener: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
            fileRevealer: @escaping ([URL]) -> Void = {
                NSWorkspace.shared.activateFileViewerSelecting($0)
            },
            delayedAutomaticScheduler: @escaping (DispatchWorkItem) -> Void = {
                DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: $0)
            }
        ) {
            self.chatHistoryStore = chatHistoryStore
            self.fileManager = fileManager
            self.recapsDirectory = recapsDirectory
            self.executableLocator = executableLocator
            self.sessionFactory = sessionFactory
            self.directoryOpener = directoryOpener
            self.fileRevealer = fileRevealer
            self.delayedAutomaticScheduler = delayedAutomaticScheduler
            let today = Calendar.current.startOfDay(for: Date())
            selectedDay = today
            automaticRecapsEnabled = UserDefaults.standard.bool(forKey: Self.automaticRecapsKey)
            recap = ChatGPTRecapPersistence.load(for: today, from: recapsDirectory)
            importSummary = chatHistoryStore.summary()
        }

        deinit {
            timer?.invalidate()
            delayedAutomaticWorkItem?.cancel()
        }

        var codexExecutableURL: URL? { executableLocator() }

        func configure(deviceID: String) {
            let clean = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { self.deviceID = clean }
            recap = ChatGPTRecapPersistence.load(for: selectedDay, from: recapsDirectory)
            importSummary = chatHistoryStore.summary()
        }

        /// Page activation is the only passive account refresh trigger. App startup,
        /// `configure`, and `start` retain cached state without launching Codex.
        func activate() {
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
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.started else { return }
                self.maybeGenerateAutomaticRecap()
            }
            delayedAutomaticWorkItem = workItem
            delayedAutomaticScheduler(workItem)
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            delayedAutomaticWorkItem?.cancel()
            delayedAutomaticWorkItem = nil
            started = false
            invalidateActiveRun(closeSession: true)
        }

        /// Invalidates UI callbacks and interrupts any active recap session before the
        /// clear-history path waits for the shared derived-write barrier to drain.
        func prepareForHistoryClear() {
            invalidateActiveRun(closeSession: true)
        }

        func selectDay(_ date: Date) {
            let normalized = Calendar.current.startOfDay(for: date)
            guard normalized != selectedDay else { return }
            invalidateActiveRun(closeSession: true)
            selectedDay = normalized
            streamedMarkdown = ""
            recap = ChatGPTRecapPersistence.load(for: normalized, from: recapsDirectory)
        }

        func refreshAccount() {
            guard !isCheckingAccount, !isConnecting else { return }
            guard let executable = executableLocator() else {
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
            guard let executable = executableLocator() else {
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
            guard let executable = executableLocator() else {
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
                            message:
                                "Codex removed the managed ChatGPT credentials from Goalong's isolated account directory. Your normal Codex CLI login was not changed."
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
                try ChatGPTSecureStorage.prepareDirectory(recapsDirectory)
                let files = try ChatGPTRecapPersistence.revealFiles(
                    for: selectedDay,
                    in: recapsDirectory,
                    fileManager: fileManager
                )
                if files.isEmpty {
                    directoryOpener(recapsDirectory)
                } else {
                    fileRevealer(files)
                }
            } catch {
                alert = ChatGPTRecapAlert(
                    title: "Recap folder could not be opened", message: error.localizedDescription)
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
            guard let executable = executableLocator() else {
                connectionState = .codexUnavailable
                if !automatic {
                    alert = ChatGPTRecapAlert(
                        title: "Codex is required",
                        message: CodexAppServerError.executableUnavailable.localizedDescription
                    )
                }
                return
            }
            guard let admission = derivedWriteBarrier.admission() else { return }

            let normalizedDay = Calendar.current.startOfDay(for: day)
            let runID = UUID()
            activateRun(runID)
            isGenerating = true
            streamedMarkdown = ""

            workQueue.async { [weak self] in
                guard let self else { return }
                guard self.isRunActive(runID) else { return }
                guard let permit = self.derivedWriteBarrier.beginJob(admission: admission) else {
                    DispatchQueue.main.async {
                        guard self.finishRun(runID) else { return }
                        self.isGenerating = false
                        self.streamedMarkdown = ""
                    }
                    return
                }
                defer { self.derivedWriteBarrier.endJob(permit) }
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
                    guard self.derivedWriteBarrier.isCurrent(permit), self.isRunActive(runID) else {
                        throw RecapGenerationInterruption.historyCleared
                    }

                    let directory = try Self.makeRunDirectory()
                    runDirectory = directory
                    let session = try self.makeSession(executableURL: executable)
                    defer { self.closeSession(session) }
                    guard self.derivedWriteBarrier.isCurrent(permit), self.isRunActive(runID) else {
                        throw RecapGenerationInterruption.historyCleared
                    }
                    guard let account = try session.readAccount(refreshToken: true) else {
                        throw CodexAppServerError.accountNotChatGPT("signed-out")
                    }
                    guard account.isManagedChatGPT else {
                        throw CodexAppServerError.accountNotChatGPT(account.type)
                    }

                    let prompt = try ChatGPTRecapContextBuilder.prompt(
                        for: context,
                        outputLanguage: Self.outputLanguage
                    )
                    let markdown = try session.generateRecap(
                        prompt: prompt,
                        workingDirectory: directory,
                        onDelta: { [weak self] delta in
                            DispatchQueue.main.async {
                                guard let self,
                                    self.isRunActive(runID),
                                    Calendar.current.isDate(self.selectedDay, inSameDayAs: normalizedDay),
                                    self.derivedWriteBarrier.isCurrent(permit)
                                else { return }
                                self.streamedMarkdown.append(delta)
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
                    guard self.derivedWriteBarrier.isCurrent(permit), self.isRunActive(runID) else {
                        throw RecapGenerationInterruption.historyCleared
                    }
                    try ChatGPTRecapPersistence.write(result, to: self.recapsDirectory)
                    if let runDirectory { try? self.fileManager.removeItem(at: runDirectory) }

                    DispatchQueue.main.async {
                        guard self.derivedWriteBarrier.isCurrent(permit),
                            self.finishRun(runID)
                        else { return }
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
                    if !(error is RecapGenerationInterruption) {
                        let detail = CodexAppServerLimits.boundedUTF8(
                            ActivitySemanticTextSanitizer.redact(error.localizedDescription) ?? "",
                            maximumBytes: CodexAppServerLimits.production.maximumErrorBytes
                        )
                        Diagnostics.write("ChatGPT recap generation failed: \(detail)")
                    }
                    DispatchQueue.main.async {
                        guard self.finishRun(runID) else { return }
                        self.isGenerating = false
                        self.streamedMarkdown = ""
                        if let codexError = error as? CodexAppServerError {
                            switch codexError {
                            case .accountNotChatGPT(let mode):
                                self.connectionState =
                                    mode == "signed-out"
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
            let session = try sessionFactory(executableURL)
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

        private func activateRun(_ runID: UUID) {
            runStateLock.lock()
            activeRecapRunID = runID
            runStateLock.unlock()
        }

        private func isRunActive(_ runID: UUID) -> Bool {
            runStateLock.lock()
            let active = activeRecapRunID == runID
            runStateLock.unlock()
            return active
        }

        @discardableResult
        private func finishRun(_ runID: UUID) -> Bool {
            runStateLock.lock()
            guard activeRecapRunID == runID else {
                runStateLock.unlock()
                return false
            }
            activeRecapRunID = nil
            runStateLock.unlock()
            return true
        }

        private func invalidateActiveRun(closeSession: Bool) {
            runStateLock.lock()
            activeRecapRunID = nil
            runStateLock.unlock()
            isGenerating = false
            streamedMarkdown = ""
            if closeSession { closeActiveSession() }
        }

        #if DEBUG
            func beginRunForTesting(streamed: String = "preview") {
                activateRun(UUID())
                isGenerating = true
                streamedMarkdown = streamed
            }

            var hasActiveRunForTesting: Bool {
                runStateLock.lock()
                let active = activeRecapRunID != nil
                runStateLock.unlock()
                return active
            }

            func setConnectionStateForTesting(_ state: ChatGPTConnectionState) {
                connectionState = state
            }
        #endif

        private func maybeGenerateAutomaticRecap() {
            guard started, automaticRecapsEnabled, !isGenerating else { return }
            guard case .connected = connectionState else { return }
            let today = Calendar.current.startOfDay(for: Date())
            if let stored = ChatGPTRecapPersistence.load(for: today, from: recapsDirectory),
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
                try ChatGPTSecureStorage.prepareDirectory(directory)
            }
        }

        private static func makeRunDirectory() throws -> URL {
            try prepareDirectories()
            let directory = AppPaths.chatGPTRunsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try ChatGPTSecureStorage.prepareDirectory(directory)
            return directory
        }

        private static var outputLanguage: String {
            if #available(macOS 13, *), Locale.current.language.languageCode?.identifier == "fr" {
                return "French"
            }
            return "English"
        }

        private enum RecapGenerationInterruption: Error {
            case historyCleared
        }
    }
#endif
