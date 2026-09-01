#if os(macOS) && GOALONG_LOCAL_ONLY
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
                return "Remote analysis is not present in Goalong History Local."
            case .launchFailed(let value), .processExited(let value), .server(let value),
                .loginFailed(let value), .generationFailed(let value):
                return value.isEmpty ? "The unavailable remote-analysis operation failed." : value
            case .timeout(let value):
                return "The unavailable remote-analysis operation timed out: \(value)."
            case .protocolLimitExceeded(let value):
                return "The remote-analysis protocol limit was exceeded: \(value)."
            case .malformedResponse(let value):
                return "The remote-analysis response was invalid: \(value)."
            case .accountNotChatGPT(let value):
                return "No supported ChatGPT account is available: \(value)."
            }
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
            var data = Data(value.utf8.prefix(maximumBytes))
            while !data.isEmpty, String(data: data, encoding: .utf8) == nil { data.removeLast() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    struct ChatGPTDailyAssessment: Codable, Equatable {
        static let requiredSummaryLineCount = 5
        static let maximumSummaryLineBytes = 512

        let productivityScore: Int
        let confidenceScore: Int
        let summaryLines: [String]
        let rawResponse: String?
        let threadID: String?
        let turnID: String?

        init(
            productivityScore: Int,
            confidenceScore: Int,
            summaryLines: [String],
            rawResponse: String? = nil,
            threadID: String? = nil,
            turnID: String? = nil
        ) throws {
            guard (0...100).contains(productivityScore), (0...100).contains(confidenceScore),
                summaryLines.count == Self.requiredSummaryLineCount,
                summaryLines.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw CodexAppServerError.malformedResponse("daily assessment does not match the fixed schema")
            }
            self.productivityScore = productivityScore
            self.confidenceScore = confidenceScore
            self.summaryLines = summaryLines.map {
                CodexAppServerLimits.boundedUTF8(
                    ActivitySemanticTextSanitizer.redact($0) ?? "",
                    maximumBytes: Self.maximumSummaryLineBytes
                )
            }
            self.rawResponse = rawResponse
            self.threadID = threadID
            self.turnID = turnID
        }

        static func decode(_ raw: String) throws -> ChatGPTDailyAssessment {
            guard let data = raw.data(using: .utf8) else {
                throw CodexAppServerError.malformedResponse("daily assessment was not UTF-8")
            }
            struct Unvalidated: Decodable {
                let productivityScore: Int
                let confidenceScore: Int
                let summaryLines: [String]
            }
            let value = try JSONDecoder().decode(Unvalidated.self, from: data)
            return try ChatGPTDailyAssessment(
                productivityScore: value.productivityScore,
                confidenceScore: value.confidenceScore,
                summaryLines: value.summaryLines,
                rawResponse: raw
            )
        }

        var markdown: String { summaryLines.joined(separator: "\n") }

        func withTransport(threadID: String, turnID: String?) throws -> ChatGPTDailyAssessment {
            try ChatGPTDailyAssessment(
                productivityScore: productivityScore,
                confidenceScore: confidenceScore,
                summaryLines: summaryLines,
                rawResponse: rawResponse,
                threadID: threadID,
                turnID: turnID
            )
        }
    }

    enum CodexDailyAssessmentContract {
        static let definitionID = GoalongDailyAnalysisDefinition.identifier
        static let definitionRevision = GoalongDailyAnalysisDefinition.revision
        static let model = "gpt-5.6-luna"
        static let reasoningEffort = "high"
        static let threadStartTimeout: TimeInterval = 120
        static let turnStartTimeout: TimeInterval = 120
        static let generationTimeout: TimeInterval = 900

        static var outputSchema: [String: Any] {
            [
                "type": "object",
                "properties": [
                    "productivityScore": ["type": "integer", "minimum": 0, "maximum": 100],
                    "confidenceScore": ["type": "integer", "minimum": 0, "maximum": 100],
                    "summaryLines": [
                        "type": "array",
                        "items": [
                            "type": "string", "minLength": 1,
                            "maxLength": ChatGPTDailyAssessment.maximumSummaryLineBytes,
                        ],
                        "minItems": ChatGPTDailyAssessment.requiredSummaryLineCount,
                        "maxItems": ChatGPTDailyAssessment.requiredSummaryLineCount,
                    ],
                ],
                "required": ["productivityScore", "confidenceScore", "summaryLines"],
                "additionalProperties": false,
            ]
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
            environment _: [String: String] = ProcessInfo.processInfo.environment,
            fileManager _: FileManager = .default,
            bundle _: Bundle = .main
        ) -> URL? { nil }
    }

    /// Compile-time stub. The real Process-based bridge is excluded from the
    /// Local target, so no child process or managed OAuth transport can start.
    final class CodexAppServerSession {
        init(
            executableURL _: URL,
            codexHomeURL _: URL = AppPaths.chatGPTCodexHomeDirectory,
            limits _: CodexAppServerLimits = .production
        ) throws {
            throw CodexAppServerError.executableUnavailable
        }

        func readAccount(refreshToken _: Bool = false) throws -> CodexAccount? {
            throw CodexAppServerError.executableUnavailable
        }
        func beginChatGPTLogin() throws -> CodexLoginStart {
            throw CodexAppServerError.executableUnavailable
        }
        func waitForChatGPTLogin(loginID _: String, timeout _: TimeInterval = 600) throws -> CodexAccount {
            throw CodexAppServerError.executableUnavailable
        }
        func logout() throws { throw CodexAppServerError.executableUnavailable }
        func generateRecap(
            prompt _: String,
            workingDirectory _: URL,
            onDelta _: ((String) -> Void)? = nil
        ) throws -> ChatGPTDailyAssessment {
            throw CodexAppServerError.executableUnavailable
        }
        func close() {}
    }
#endif
