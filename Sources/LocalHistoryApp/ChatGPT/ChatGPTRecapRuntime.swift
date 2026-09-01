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

    protocol AnalysisRunSigningIdentity: AnyObject {
        var info: DeviceIdentityInfo { get }
        func sign(_ message: Data) throws -> Data
    }

    extension DeviceIdentity: AnalysisRunSigningIdentity {}

    enum AnalysisRunAttestationSigner {
        static func sign(
            runID: UUID,
            day: Date,
            generatedAt: Date,
            trigger: String,
            prompt: Data,
            recap: ChatGPTDailyRecap,
            identity: AnalysisRunSigningIdentity
        ) throws -> AnalysisRunAttestation {
            guard let response = recap.signedResultCanonicalData() else {
                throw CodexAppServerError.malformedResponse(
                    "the saved analysis result could not be canonicalized"
                )
            }
            let sourceCounts = try recap.sourceCounts.canonicalData()
            // JSONEncoder's ISO-8601 strategy persists whole seconds. Sign the
            // same normalized value that survives a write/read round trip.
            let generatedAtMilliseconds =
                Int64(generatedAt.timeIntervalSince1970.rounded(.down)) * 1_000
            let values = (
                runID: runID.uuidString.lowercased(),
                day: AppPaths.localDayString(for: day),
                generatedAtMilliseconds: generatedAtMilliseconds,
                trigger: trigger,
                definitionID: CodexDailyAssessmentContract.definitionID,
                definitionRevision: CodexDailyAssessmentContract.definitionRevision,
                provider: recap.provider,
                planType: recap.planType,
                model: recap.model ?? "",
                reasoningEffort: recap.reasoningEffort ?? "",
                promptSHA256: SHA256Digest.hashHex(prompt),
                promptByteCount: prompt.count,
                responseSHA256: SHA256Digest.hashHex(response),
                responseByteCount: response.count,
                contextDigest: recap.contextDigest,
                sourceCountsSHA256: SHA256Digest.hashHex(sourceCounts),
                signerDeviceID: identity.info.deviceID
            )
            guard let message = AnalysisRunAttestation.signingMessage(
                runID: values.runID,
                day: values.day,
                generatedAtMilliseconds: values.generatedAtMilliseconds,
                trigger: values.trigger,
                definitionID: values.definitionID,
                definitionRevision: values.definitionRevision,
                provider: values.provider,
                planType: values.planType,
                model: values.model,
                reasoningEffort: values.reasoningEffort,
                promptSHA256: values.promptSHA256,
                promptByteCount: values.promptByteCount,
                responseSHA256: values.responseSHA256,
                responseByteCount: values.responseByteCount,
                contextDigest: values.contextDigest,
                sourceCountsSHA256: values.sourceCountsSHA256,
                signerDeviceID: values.signerDeviceID
            ) else {
                throw CodexAppServerError.malformedResponse(
                    "the local analysis attestation fields were invalid"
                )
            }
            let signature = try identity.sign(message)
            return AnalysisRunAttestation(
                runID: values.runID,
                day: values.day,
                generatedAtMilliseconds: values.generatedAtMilliseconds,
                trigger: values.trigger,
                definitionID: values.definitionID,
                definitionRevision: values.definitionRevision,
                provider: values.provider,
                planType: values.planType,
                model: values.model,
                reasoningEffort: values.reasoningEffort,
                promptSHA256: values.promptSHA256,
                promptByteCount: values.promptByteCount,
                responseSHA256: values.responseSHA256,
                responseByteCount: values.responseByteCount,
                contextDigest: values.contextDigest,
                sourceCountsSHA256: values.sourceCountsSHA256,
                signerDeviceID: values.signerDeviceID,
                publicKeyBase64: identity.info.publicKeyBase64,
                signatureBase64: signature.base64EncodedString(),
                signatureAlgorithm: identity.info.algorithm
            )
        }
    }

    extension ChatGPTRecapSourceCounts {
        fileprivate func canonicalData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
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
        let model: String?
        let reasoningEffort: String?
        let productivityScore: Int?
        let confidenceScore: Int?
        let summaryLines: [String]?
        let attestation: AnalysisRunAttestation?
        let proof: AnalysisProofReference?

        init(
            schemaVersion: Int = 2,
            day: Date,
            generatedAt: Date = Date(),
            provider: String = "codex_app_server_chatgpt",
            planType: String?,
            contextDigest: String,
            sourceCounts: ChatGPTRecapSourceCounts,
            markdown: String,
            model: String? = nil,
            reasoningEffort: String? = nil,
            productivityScore: Int? = nil,
            confidenceScore: Int? = nil,
            summaryLines: [String]? = nil,
            attestation: AnalysisRunAttestation? = nil,
            proof: AnalysisProofReference? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.day = Calendar.current.startOfDay(for: day)
            self.generatedAt = generatedAt
            self.provider = provider
            self.planType = planType
            self.contextDigest = contextDigest
            self.sourceCounts = sourceCounts
            self.markdown = markdown
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.productivityScore = productivityScore
            self.confidenceScore = confidenceScore
            self.summaryLines = summaryLines
            self.attestation = attestation
            self.proof = proof
        }

        var isValidCurrentAssessment: Bool {
            guard [2, 3, 4].contains(schemaVersion),
                model == CodexDailyAssessmentContract.model,
                reasoningEffort == CodexDailyAssessmentContract.reasoningEffort,
                let productivityScore,
                let confidenceScore,
                let summaryLines,
                (0...100).contains(productivityScore),
                (0...100).contains(confidenceScore),
                summaryLines.count == ChatGPTDailyAssessment.requiredSummaryLineCount
            else { return false }
            let validContent = markdown == summaryLines.joined(separator: "\n")
                && summaryLines.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.utf8.count <= ChatGPTDailyAssessment.maximumSummaryLineBytes
            }
            guard validContent else { return false }
            if schemaVersion == 2 { return attestation == nil }
            if schemaVersion == 3 { return verifiesLocalAttestation }
            return verifiesLocalAttestation
                && proof?.executionID == attestation?.runID
                && proof?.localSignatureStatus == "valid"
                && proof?.retentionMode == "hash_only_no_transcript_copy"
                && (proof.map { GoalongProofDigest.isValid($0.runJWSSHA256) } ?? false)
        }

        var verifiesLocalAttestation: Bool {
            guard [3, 4].contains(schemaVersion),
                let attestation,
                attestation.day == AppPaths.localDayString(for: day),
                attestation.generatedAtMilliseconds
                    == Int64((generatedAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
                attestation.definitionID == CodexDailyAssessmentContract.definitionID,
                attestation.definitionRevision == CodexDailyAssessmentContract.definitionRevision,
                attestation.provider == provider,
                attestation.planType == planType,
                attestation.model == model,
                attestation.reasoningEffort == reasoningEffort,
                attestation.verifiesDeviceSignature(),
                let sourceCountsData = try? sourceCounts.canonicalData(),
                let savedResultData = signedResultCanonicalData()
            else { return false }
            return attestation.matches(
                response: savedResultData,
                contextDigest: contextDigest,
                sourceCountsCanonicalData: sourceCountsData
            )
        }

        fileprivate func signedResultCanonicalData() -> Data? {
            guard let productivityScore, let confidenceScore, let summaryLines else {
                return nil
            }
            return AnalysisRunSavedResult(
                markdown: markdown,
                productivityScore: productivityScore,
                confidenceScore: confidenceScore,
                summaryLines: summaryLines
            ).canonicalData()
        }
    }

    enum ChatGPTRecapPersistence {
        typealias Writer = (Data, URL) throws -> Void

        static let maximumMarkdownBytes = 8 * 1_024
        static let maximumLegacyMarkdownBytes = CodexAppServerLimits.production.maximumRecapMarkdownBytes
        static let maximumJSONBytes = 64 * 1_024
        static let maximumLegacyJSONBytes = 8 * 1_024 * 1_024

        static func preparedForPersistence(_ recap: ChatGPTDailyRecap) throws -> ChatGPTDailyRecap {
            guard let redactedMarkdown = ActivitySemanticTextSanitizer.redact(recap.markdown),
                !redactedMarkdown.isEmpty
            else {
                throw CodexAppServerError.generationFailed("The recap contained no persistable text.")
            }
            let normalizedGeneratedAt = Date(
                timeIntervalSince1970: recap.generatedAt.timeIntervalSince1970.rounded(.down)
            )
            return ChatGPTDailyRecap(
                schemaVersion: recap.schemaVersion,
                day: recap.day,
                generatedAt: normalizedGeneratedAt,
                provider: recap.provider,
                planType: recap.planType,
                contextDigest: recap.contextDigest,
                sourceCounts: recap.sourceCounts,
                markdown: redactedMarkdown,
                model: recap.model,
                reasoningEffort: recap.reasoningEffort,
                productivityScore: recap.productivityScore,
                confidenceScore: recap.confidenceScore,
                summaryLines: recap.summaryLines?.compactMap {
                    ActivitySemanticTextSanitizer.redact($0)?.trimmingCharacters(in: .whitespacesAndNewlines)
                },
                attestation: recap.attestation,
                proof: recap.proof
            )
        }

        static func write(
            _ recap: ChatGPTDailyRecap,
            to directory: URL,
            fileManager: FileManager = .default,
            writer: Writer? = nil
        ) throws {
            let persistedRecap = try preparedForPersistence(recap)
            let markdownData = Data(persistedRecap.markdown.utf8)
            guard persistedRecap.isValidCurrentAssessment,
                markdownData.count <= maximumMarkdownBytes
            else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "daily assessment failed its bounded five-line persistence contract"
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
                    maximumBytes: Int64(maximumLegacyJSONBytes)
                )
            else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let recap = try? decoder.decode(ChatGPTDailyRecap.self, from: data) else { return nil }
            if recap.schemaVersion == 1 {
                guard recap.markdown.utf8.count <= maximumLegacyMarkdownBytes else { return nil }
            } else {
                guard recap.isValidCurrentAssessment,
                    recap.markdown.utf8.count <= maximumMarkdownBytes,
                    data.count <= maximumJSONBytes
                else { return nil }
            }
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

    enum ChatGPTDailyRecapSchedule {
        static let boundaryMinute = 5

        static func completedDay(at date: Date, calendar: Calendar = .current) -> Date? {
            let today = calendar.startOfDay(for: date)
            return calendar.date(byAdding: .day, value: -1, to: today)
        }

        static func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
            let today = calendar.startOfDay(for: date)
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return calendar.date(byAdding: .minute, value: boundaryMinute, to: tomorrow)
        }
    }

    final class ChatGPTRecapRuntime: ObservableObject {
        static let shared = ChatGPTRecapRuntime(
            analysisSigningIdentityProvider: { try DeviceIdentity() }
        )

        @Published private(set) var connectionState: ChatGPTConnectionState = .checking
        @Published private(set) var recap: ChatGPTDailyRecap?
        @Published private(set) var dayOverview: ChatGPTRecapDayOverview?
        @Published private(set) var proofReport: AnalysisProofVerificationReport?
        @Published private(set) var isCheckingAccount = false
        @Published private(set) var isConnecting = false
        @Published private(set) var isGenerating = false
        @Published private(set) var isLoadingDayOverview = false
        @Published private(set) var dayOverviewError: String?
        @Published private(set) var streamedMarkdown = ""
        @Published var selectedDay: Date
        @Published var automaticRecapsEnabled: Bool {
            didSet {
                UserDefaults.standard.set(automaticRecapsEnabled, forKey: Self.automaticRecapsKey)
                scheduleNextAutomaticRecap()
                scheduleAutomaticBoundaryFallback()
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
        private let proofStore: AnalysisProofStore
        private let executableLocator: () -> URL?
        private let sessionFactory: (URL) throws -> CodexAppServerSession
        private let directoryOpener: (URL) -> Void
        private let fileRevealer: ([URL]) -> Void
        private let delayedAutomaticScheduler: (DispatchWorkItem) -> Void
        private let automaticRetryScheduler: (TimeInterval, DispatchWorkItem) -> Void
        private let automaticBoundaryFallbackScheduler: (Date, DispatchWorkItem) -> Void
        private let analysisConsentProvider: () -> Bool
        private let analysisSigningIdentityProvider: (() throws -> AnalysisRunSigningIdentity)?
        private let derivedWriteBarrier = DerivedHistoryWriteBarrier.shared
        private let sessionLock = NSLock()
        private let runStateLock = NSLock()
        private var activeSession: CodexAppServerSession?
        private var activeRecapRunID: UUID?
        private var deviceID = ""
        private var timer: Timer?
        private var delayedAutomaticWorkItem: DispatchWorkItem?
        private var automaticRetryWorkItem: DispatchWorkItem?
        private var automaticBoundaryFallbackWorkItem: DispatchWorkItem?
        private var automaticRetryDay: Date?
        private var automaticRetryAttempt = 0
        private var started = false

        private static let automaticRecapsKey = "chatgptRecap.automaticEnabled"
        private static let automaticRetryDelays: [TimeInterval] = [15 * 60, 60 * 60, 3 * 60 * 60]
        private static let automaticBoundaryFallbackDelay: TimeInterval = 5 * 60

        init(
            chatHistoryStore: ChatGPTHistoryStore = ChatGPTHistoryStore(
                rootDirectory: AppPaths.chatGPTHistoryDirectory
            ),
            fileManager: FileManager = .default,
            recapsDirectory: URL = AppPaths.chatGPTRecapsDirectory,
            proofsDirectory: URL? = nil,
            executableLocator: @escaping () -> URL? = { CodexExecutableLocator.locate() },
            sessionFactory: @escaping (URL) throws -> CodexAppServerSession = {
                try CodexAppServerSession(executableURL: $0)
            },
            directoryOpener: @escaping (URL) -> Void = {
                _ = GoalongWorkspaceOpenPolicy.open($0, purpose: .localFile)
            },
            fileRevealer: @escaping ([URL]) -> Void = {
                NSWorkspace.shared.activateFileViewerSelecting($0)
            },
            delayedAutomaticScheduler: @escaping (DispatchWorkItem) -> Void = {
                DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: $0)
            },
            automaticRetryScheduler: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
                delay, workItem in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            },
            automaticBoundaryFallbackScheduler: @escaping (Date, DispatchWorkItem) -> Void = {
                fireDate, workItem in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + max(fireDate.timeIntervalSinceNow, 0),
                    execute: workItem
                )
            },
            analysisConsentProvider: @escaping () -> Bool = {
                GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis)
            },
            analysisSigningIdentityProvider: (() throws -> AnalysisRunSigningIdentity)? = nil
        ) {
            self.chatHistoryStore = chatHistoryStore
            self.fileManager = fileManager
            self.recapsDirectory = recapsDirectory
            proofStore = AnalysisProofStore(
                rootDirectory: proofsDirectory
                    ?? recapsDirectory.deletingLastPathComponent()
                        .appendingPathComponent("proofs", isDirectory: true),
                fileManager: fileManager
            )
            self.executableLocator = executableLocator
            self.sessionFactory = sessionFactory
            self.directoryOpener = directoryOpener
            self.fileRevealer = fileRevealer
            self.delayedAutomaticScheduler = delayedAutomaticScheduler
            self.automaticRetryScheduler = automaticRetryScheduler
            self.automaticBoundaryFallbackScheduler = automaticBoundaryFallbackScheduler
            self.analysisConsentProvider = analysisConsentProvider
            self.analysisSigningIdentityProvider = analysisSigningIdentityProvider
            let today = Calendar.current.startOfDay(for: Date())
            selectedDay = today
            automaticRecapsEnabled =
                UserDefaults.standard.object(forKey: Self.automaticRecapsKey) == nil
                ? false
                : UserDefaults.standard.bool(forKey: Self.automaticRecapsKey)
            recap = ChatGPTRecapPersistence.load(for: today, from: recapsDirectory)
            proofReport = nil
        }

        deinit {
            timer?.invalidate()
            delayedAutomaticWorkItem?.cancel()
            automaticRetryWorkItem?.cancel()
            automaticBoundaryFallbackWorkItem?.cancel()
        }

        var codexExecutableURL: URL? { executableLocator() }

        func configure(deviceID: String) {
            let clean = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { self.deviceID = clean }
            recap = ChatGPTRecapPersistence.load(for: selectedDay, from: recapsDirectory)
            refreshProofReport()
        }

        /// Page activation is the only passive account refresh trigger. App startup,
        /// `configure`, and `start` retain cached state without launching Codex.
        func activate() {
            guard analysisConsentProvider() else {
                connectionState = .signedOut
                dayOverview = nil
                dayOverviewError = nil
                return
            }
            if GoalongBuildCapabilities.permitsRemoteAnalysis {
                refreshAccount()
            } else {
                connectionState = .codexUnavailable
            }
            refreshDayOverview()
        }

        func start() {
            guard GoalongBuildCapabilities.permitsRemoteAnalysis else { return }
            guard analysisConsentProvider() else { return }
            guard !started else { return }
            started = true
            scheduleNextAutomaticRecap()
            scheduleAutomaticBoundaryFallback()
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
            clearAutomaticRetry()
            automaticBoundaryFallbackWorkItem?.cancel()
            automaticBoundaryFallbackWorkItem = nil
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
            proofReport = nil
            dayOverview = nil
            dayOverviewError = nil
            isLoadingDayOverview = false
            refreshDayOverview()
            refreshProofReport()
        }

        private func refreshProofReport() {
            guard let reference = recap?.proof else {
                proofReport = nil
                return
            }
            let requestedExecutionID = reference.executionID
            workQueue.async { [weak self] in
                guard let self else { return }
                let report = try? self.proofStore.verify(reference: reference)
                DispatchQueue.main.async {
                    guard self.recap?.proof?.executionID == requestedExecutionID else { return }
                    self.proofReport = report
                }
            }
        }

        func refreshDayOverview() {
            guard analysisConsentProvider() else {
                dayOverview = nil
                dayOverviewError = nil
                isLoadingDayOverview = false
                return
            }
            guard !deviceID.isEmpty, !isLoadingDayOverview else { return }
            let requestedDay = selectedDay
            let storedSourceCounts = recap?.sourceCounts
            let includeScreenTime = GoalongCapabilityConsentStore.shared.isEnabled(.appleScreenTime)
            let includeAgentActivity = GoalongCapabilityConsentStore.shared.isEnabled(.aiConversations)
            isLoadingDayOverview = true
            dayOverviewError = nil
            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let context = try ChatGPTRecapContextBuilder.build(
                        for: requestedDay,
                        deviceID: self.deviceID,
                        chatHistoryStore: self.chatHistoryStore,
                        includeScreenTime: includeScreenTime,
                        includeAgentActivity: includeAgentActivity,
                        analyzeAgentContent: false
                    )
                    let measuredOverview = ChatGPTRecapContextBuilder.dayOverview(from: context)
                    let overview = storedSourceCounts.map {
                        measuredOverview.replacingAgentMetrics(with: $0)
                    } ?? measuredOverview
                    DispatchQueue.main.async {
                        guard Calendar.current.isDate(self.selectedDay, inSameDayAs: requestedDay) else {
                            return
                        }
                        self.dayOverview = overview
                        self.isLoadingDayOverview = false
                    }
                } catch {
                    let message = ActivitySemanticTextSanitizer.redact(error.localizedDescription)
                        ?? "The selected day could not be loaded."
                    DispatchQueue.main.async {
                        guard Calendar.current.isDate(self.selectedDay, inSameDayAs: requestedDay) else {
                            return
                        }
                        self.dayOverview = nil
                        self.dayOverviewError = message
                        self.isLoadingDayOverview = false
                    }
                }
            }
        }

        func refreshAccount() {
            guard analysisConsentProvider() else {
                connectionState = .signedOut
                return
            }
            guard GoalongBuildCapabilities.permitsRemoteAnalysis else {
                connectionState = .codexUnavailable
                return
            }
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
            guard analysisConsentProvider() else {
                alert = ChatGPTRecapAlert(
                    title: "AI analysis is off",
                    message: "Enable ChatGPT analysis first. Goalong will then show exactly what can be sent before a run."
                )
                return
            }
            guard GoalongBuildCapabilities.permitsRemoteAnalysis else {
                connectionState = .codexUnavailable
                alert = ChatGPTRecapAlert(
                    title: "Not included in this edition",
                    message:
                        "ChatGPT analysis is not available in this build."
                )
                return
            }
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
                        _ = GoalongWorkspaceOpenPolicy.open(
                            login.authorizationURL,
                            purpose: .accountAuthorization
                        )
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

        func openCodexInstallGuide() {
            guard let url = URL(string: "https://developers.openai.com/codex/cli") else { return }
            GoalongWorkspaceOpenPolicy.open(url, purpose: .documentation)
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

        func exportProofPackage() {
            guard let proof = recap?.proof else {
                alert = ChatGPTRecapAlert(
                    title: "No standalone proof",
                    message: "Regenerate this day with the current Goalong build first."
                )
                return
            }
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.allowedContentTypes = [
                UTType(filenameExtension: "goalong-proof") ?? .zip
            ]
            panel.nameFieldStringValue =
                "\(AppPaths.localDayString(for: selectedDay))-\(String(proof.executionID.prefix(8))).goalong-proof"
            panel.message =
                "Exports signed hashes, source commitments and the five-line result. Conversation bodies, the complete prompt and the private encrypted response capsule are excluded."
            panel.prompt = "Export proof"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                let report = try proofStore.export(reference: proof, to: destination)
                alert = ChatGPTRecapAlert(
                    title: "Standalone proof exported",
                    message: report.isLocallyValid
                        ? "The .goalong-proof package passed offline verification after it was written."
                        : "The package was written but did not pass local verification."
                )
            } catch {
                alert = ChatGPTRecapAlert(
                    title: "Proof could not be exported",
                    message: error.localizedDescription
                )
            }
        }

        private func generateRecap(for day: Date, automatic: Bool) {
            guard analysisConsentProvider() else {
                if !automatic {
                    alert = ChatGPTRecapAlert(
                        title: "AI analysis is off",
                        message: "Enable ChatGPT analysis in Settings before starting a run."
                    )
                }
                return
            }
            guard GoalongBuildCapabilities.permitsRemoteAnalysis else {
                if !automatic {
                    alert = ChatGPTRecapAlert(
                        title: "Remote analysis is absent",
                        message:
                            "This Local binary contains no Codex process bridge. Existing reports remain readable and verifiable."
                    )
                }
                return
            }
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
            let includeScreenTime = GoalongCapabilityConsentStore.shared.isEnabled(.appleScreenTime)
            let includeAgentActivity = GoalongCapabilityConsentStore.shared.isEnabled(.aiConversations)
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
                        chatHistoryStore: self.chatHistoryStore,
                        includeScreenTime: includeScreenTime,
                        includeAgentActivity: includeAgentActivity,
                        analyzeAgentContent: includeAgentActivity
                    )
                    guard context.hasMeaningfulData else {
                        throw CodexAppServerError.generationFailed("There is no captured context for this day yet.")
                    }
                    let overview = ChatGPTRecapContextBuilder.dayOverview(from: context)
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
                    let assessment = try session.generateRecap(
                        prompt: prompt,
                        workingDirectory: directory
                    )
                    let generatedAtMilliseconds =
                        Int64(Date().timeIntervalSince1970.rounded(.down)) * 1_000
                    let generatedAt = Date(
                        timeIntervalSince1970: Double(generatedAtMilliseconds) / 1_000
                    )
                    let draft = ChatGPTDailyRecap(
                        day: normalizedDay,
                        generatedAt: generatedAt,
                        planType: account.planType,
                        contextDigest: context.digest,
                        sourceCounts: context.sourceCounts,
                        markdown: assessment.markdown,
                        model: CodexDailyAssessmentContract.model,
                        reasoningEffort: CodexDailyAssessmentContract.reasoningEffort,
                        productivityScore: assessment.productivityScore,
                        confidenceScore: assessment.confidenceScore,
                        summaryLines: assessment.summaryLines
                    )
                    let normalizedDraft = try ChatGPTRecapPersistence.preparedForPersistence(draft)
                    let result: ChatGPTDailyRecap
                    if let analysisSigningIdentityProvider = self.analysisSigningIdentityProvider {
                        let identity = try analysisSigningIdentityProvider()
                        let attestation = try AnalysisRunAttestationSigner.sign(
                            runID: runID,
                            day: normalizedDay,
                            generatedAt: generatedAt,
                            trigger: automatic ? "automatic" : "manual",
                            prompt: Data(prompt.utf8),
                            recap: normalizedDraft,
                            identity: identity
                        )
                        let signedDraft = ChatGPTDailyRecap(
                            schemaVersion: 3,
                            day: normalizedDraft.day,
                            generatedAt: normalizedDraft.generatedAt,
                            provider: normalizedDraft.provider,
                            planType: normalizedDraft.planType,
                            contextDigest: normalizedDraft.contextDigest,
                            sourceCounts: normalizedDraft.sourceCounts,
                            markdown: normalizedDraft.markdown,
                            model: normalizedDraft.model,
                            reasoningEffort: normalizedDraft.reasoningEffort,
                            productivityScore: normalizedDraft.productivityScore,
                            confidenceScore: normalizedDraft.confidenceScore,
                            summaryLines: normalizedDraft.summaryLines,
                            attestation: attestation
                        )
                        let proof = try self.proofStore.create(
                            runID: runID,
                            day: normalizedDay,
                            generatedAt: generatedAt,
                            trigger: automatic ? "automatic" : "manual",
                            prompt: prompt,
                            context: context,
                            assessment: assessment,
                            recap: signedDraft,
                            identity: identity
                        )
                        result = ChatGPTDailyRecap(
                            schemaVersion: 4,
                            day: signedDraft.day,
                            generatedAt: signedDraft.generatedAt,
                            provider: signedDraft.provider,
                            planType: signedDraft.planType,
                            contextDigest: signedDraft.contextDigest,
                            sourceCounts: signedDraft.sourceCounts,
                            markdown: signedDraft.markdown,
                            model: signedDraft.model,
                            reasoningEffort: signedDraft.reasoningEffort,
                            productivityScore: signedDraft.productivityScore,
                            confidenceScore: signedDraft.confidenceScore,
                            summaryLines: signedDraft.summaryLines,
                            attestation: signedDraft.attestation,
                            proof: proof.reference
                        )
                    } else {
                        result = normalizedDraft
                    }
                    guard self.derivedWriteBarrier.isCurrent(permit), self.isRunActive(runID) else {
                        throw RecapGenerationInterruption.historyCleared
                    }
                    try ChatGPTRecapPersistence.write(result, to: self.recapsDirectory)
                    let proofReport = result.proof.flatMap {
                        try? self.proofStore.verify(reference: $0)
                    }
                    if let runDirectory { try? self.fileManager.removeItem(at: runDirectory) }

                    DispatchQueue.main.async {
                        guard self.derivedWriteBarrier.isCurrent(permit),
                            self.finishRun(runID)
                        else { return }
                        self.isGenerating = false
                        self.streamedMarkdown = ""
                        self.clearAutomaticRetry(for: normalizedDay)
                        self.publishAccount(account)
                        if Calendar.current.isDate(self.selectedDay, inSameDayAs: normalizedDay) {
                            self.recap = result
                            self.proofReport = proofReport
                            self.dayOverview = overview
                            self.dayOverviewError = nil
                            self.isLoadingDayOverview = false
                        }
                        if !automatic {
                            self.alert = ChatGPTRecapAlert(
                                title: "Daily activity report generated",
                                message:
                                    "The five-line report is stored with a chained local ES256 proof, source commitments and an encrypted copy of the bounded generated response. The complete prompt remains hash-only; Goalong did not create another transcript copy."
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
                        } else {
                            self.scheduleAutomaticRetry(for: normalizedDay, after: error)
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

            func scheduleAutomaticRetryForTesting(for day: Date, after error: Error) {
                scheduleAutomaticRetry(for: day, after: error)
            }

            var automaticRetryAttemptForTesting: Int { automaticRetryAttempt }

            var hasAutomaticBoundaryFallbackForTesting: Bool {
                automaticBoundaryFallbackWorkItem != nil
            }
        #endif

        private func maybeGenerateAutomaticRecap() {
            guard analysisConsentProvider() else { return }
            guard started, automaticRecapsEnabled, !isGenerating else { return }
            guard let completedDay = ChatGPTDailyRecapSchedule.completedDay(at: Date()) else { return }
            if let stored = ChatGPTRecapPersistence.load(for: completedDay, from: recapsDirectory),
                stored.isValidCurrentAssessment
            {
                clearAutomaticRetry(for: completedDay)
                return
            }
            generateRecap(for: completedDay, automatic: true)
        }

        private func scheduleAutomaticRetry(for day: Date, after error: Error) {
            guard started, automaticRecapsEnabled, Self.isRetryableAutomaticError(error) else {
                return
            }
            let normalizedDay = Calendar.current.startOfDay(for: day)
            if automaticRetryDay != normalizedDay {
                automaticRetryWorkItem?.cancel()
                automaticRetryWorkItem = nil
                automaticRetryDay = normalizedDay
                automaticRetryAttempt = 0
            }
            guard automaticRetryAttempt < Self.automaticRetryDelays.count else { return }
            let delay = Self.automaticRetryDelays[automaticRetryAttempt]
            automaticRetryAttempt += 1
            automaticRetryWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.started, self.automaticRecapsEnabled else { return }
                self.automaticRetryWorkItem = nil
                if let stored = ChatGPTRecapPersistence.load(
                    for: normalizedDay,
                    from: self.recapsDirectory
                ), stored.isValidCurrentAssessment {
                    self.clearAutomaticRetry(for: normalizedDay)
                    return
                }
                self.generateRecap(for: normalizedDay, automatic: true)
            }
            automaticRetryWorkItem = workItem
            automaticRetryScheduler(delay, workItem)
        }

        private func clearAutomaticRetry(for day: Date? = nil) {
            if let day, automaticRetryDay != Calendar.current.startOfDay(for: day) { return }
            automaticRetryWorkItem?.cancel()
            automaticRetryWorkItem = nil
            automaticRetryDay = nil
            automaticRetryAttempt = 0
        }

        static func isRetryableAutomaticError(_ error: Error) -> Bool {
            guard let codexError = error as? CodexAppServerError else { return false }
            switch codexError {
            case .launchFailed, .processExited, .timeout, .malformedResponse, .server,
                .generationFailed:
                return true
            case .executableUnavailable, .protocolLimitExceeded, .loginFailed, .accountNotChatGPT:
                return false
            }
        }

        static var automaticRetryDelaysForTesting: [TimeInterval] {
            automaticRetryDelays
        }

        private func scheduleNextAutomaticRecap() {
            timer?.invalidate()
            timer = nil
            guard started, automaticRecapsEnabled,
                let fireDate = ChatGPTDailyRecapSchedule.nextBoundary(after: Date())
            else { return }
            let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.maybeGenerateAutomaticRecap()
                self.scheduleNextAutomaticRecap()
            }
            timer.tolerance = 60
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func scheduleAutomaticBoundaryFallback() {
            automaticBoundaryFallbackWorkItem?.cancel()
            automaticBoundaryFallbackWorkItem = nil
            guard started, automaticRecapsEnabled,
                let boundary = ChatGPTDailyRecapSchedule.nextBoundary(after: Date())
            else { return }
            let fireDate = boundary.addingTimeInterval(Self.automaticBoundaryFallbackDelay)
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.started, self.automaticRecapsEnabled else { return }
                self.automaticBoundaryFallbackWorkItem = nil
                self.maybeGenerateAutomaticRecap()
                self.scheduleAutomaticBoundaryFallback()
            }
            automaticBoundaryFallbackWorkItem = workItem
            automaticBoundaryFallbackScheduler(fireDate, workItem)
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
