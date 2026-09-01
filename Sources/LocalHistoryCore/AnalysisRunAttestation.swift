import Foundation

public enum GoalongDailyAnalysisDefinition {
    public static let identifier = "daily-activity-five-line"
    public static let revision = "2026.08.v1"
}

/// The complete bounded result that Goalong saves for one daily analysis.
///
/// Scores are part of the signed result just like the five displayed lines, so
/// changing a score after generation invalidates the analysis attestation.
/// The binary format is deliberately domain-separated and length-prefixed; it
/// does not depend on dictionary order or a JSON encoder's formatting choices.
public struct AnalysisRunSavedResult: Equatable {
    public static let currentSchemaVersion = 1
    public static let signingDomain = "GOALONG-ANALYSIS-SAVED-RESULT-V1"

    public let markdown: String
    public let productivityScore: Int
    public let confidenceScore: Int
    public let summaryLines: [String]

    public init(
        markdown: String,
        productivityScore: Int,
        confidenceScore: Int,
        summaryLines: [String]
    ) {
        self.markdown = markdown
        self.productivityScore = productivityScore
        self.confidenceScore = confidenceScore
        self.summaryLines = summaryLines
    }

    public func canonicalData() -> Data? {
        guard (0...100).contains(productivityScore),
            (0...100).contains(confidenceScore),
            summaryLines.count == 5,
            !markdown.isEmpty,
            markdown.utf8.count <= 8 * 1_024,
            summaryLines.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0")
            }),
            markdown == summaryLines.joined(separator: "\n"),
            !markdown.contains("\0")
        else { return nil }

        var data = Data(Self.signingDomain.utf8)
        data.append(0)
        Self.append(UInt64(Self.currentSchemaVersion), to: &data)
        Self.append(UInt64(productivityScore), to: &data)
        Self.append(UInt64(confidenceScore), to: &data)
        Self.append(markdown, to: &data)
        Self.append(UInt64(summaryLines.count), to: &data)
        for line in summaryLines {
            Self.append(line, to: &data)
        }
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

/// A compact, local-device-signed statement about one completed AI analysis.
///
/// It intentionally contains hashes and byte counts rather than the source
/// conversation bodies. The five-line response may remain in the recap store,
/// while the much larger prompt is reconstructed transiently from the original
/// sources and represented here only by its exact SHA-256 digest.
public struct AnalysisRunAttestation: Codable, Equatable {
    public static let currentSchemaVersion = 1
    public static let signingDomain = "GOALONG-ANALYSIS-RUN-V1"

    public let schemaVersion: Int
    public let runID: String
    public let day: String
    public let generatedAtMilliseconds: Int64
    public let trigger: String
    public let definitionID: String
    public let definitionRevision: String
    public let provider: String
    public let planType: String?
    public let model: String
    public let reasoningEffort: String
    public let promptSHA256: String
    public let promptByteCount: Int
    public let responseSHA256: String
    public let responseByteCount: Int
    public let contextDigest: String
    public let sourceCountsSHA256: String
    public let signerDeviceID: String
    public let publicKeyBase64: String
    public let signatureBase64: String
    public let signatureAlgorithm: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        runID: String,
        day: String,
        generatedAtMilliseconds: Int64,
        trigger: String,
        definitionID: String,
        definitionRevision: String,
        provider: String,
        planType: String?,
        model: String,
        reasoningEffort: String,
        promptSHA256: String,
        promptByteCount: Int,
        responseSHA256: String,
        responseByteCount: Int,
        contextDigest: String,
        sourceCountsSHA256: String,
        signerDeviceID: String,
        publicKeyBase64: String,
        signatureBase64: String,
        signatureAlgorithm: String
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.day = day
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.trigger = trigger
        self.definitionID = definitionID
        self.definitionRevision = definitionRevision
        self.provider = provider
        self.planType = planType
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.promptSHA256 = promptSHA256
        self.promptByteCount = promptByteCount
        self.responseSHA256 = responseSHA256
        self.responseByteCount = responseByteCount
        self.contextDigest = contextDigest
        self.sourceCountsSHA256 = sourceCountsSHA256
        self.signerDeviceID = signerDeviceID
        self.publicKeyBase64 = publicKeyBase64
        self.signatureBase64 = signatureBase64
        self.signatureAlgorithm = signatureAlgorithm
    }

    public func verifiesDeviceSignature() -> Bool {
        guard let message = signingMessage() else { return false }
        return DeviceP256SignatureVerifier.verifies(
            message: message,
            deviceID: signerDeviceID,
            publicKeyBase64: publicKeyBase64,
            signatureBase64: signatureBase64,
            signatureAlgorithm: signatureAlgorithm
        )
    }

    public func matches(
        response: Data,
        contextDigest: String,
        sourceCountsCanonicalData: Data
    ) -> Bool {
        response.count == responseByteCount
            && SHA256Digest.hashHex(response) == responseSHA256
            && self.contextDigest == contextDigest
            && SHA256Digest.hashHex(sourceCountsCanonicalData) == sourceCountsSHA256
    }

    public func signingMessage() -> Data? {
        Self.signingMessage(
            schemaVersion: schemaVersion,
            runID: runID,
            day: day,
            generatedAtMilliseconds: generatedAtMilliseconds,
            trigger: trigger,
            definitionID: definitionID,
            definitionRevision: definitionRevision,
            provider: provider,
            planType: planType,
            model: model,
            reasoningEffort: reasoningEffort,
            promptSHA256: promptSHA256,
            promptByteCount: promptByteCount,
            responseSHA256: responseSHA256,
            responseByteCount: responseByteCount,
            contextDigest: contextDigest,
            sourceCountsSHA256: sourceCountsSHA256,
            signerDeviceID: signerDeviceID
        )
    }

    public static func signingMessage(
        schemaVersion: Int = currentSchemaVersion,
        runID: String,
        day: String,
        generatedAtMilliseconds: Int64,
        trigger: String,
        definitionID: String,
        definitionRevision: String,
        provider: String,
        planType: String?,
        model: String,
        reasoningEffort: String,
        promptSHA256: String,
        promptByteCount: Int,
        responseSHA256: String,
        responseByteCount: Int,
        contextDigest: String,
        sourceCountsSHA256: String,
        signerDeviceID: String
    ) -> Data? {
        guard schemaVersion == currentSchemaVersion,
            UUID(uuidString: runID) != nil,
            isLocalDay(day),
            generatedAtMilliseconds >= 0,
            ["manual", "automatic"].contains(trigger),
            bounded(definitionID, maximumUTF8Bytes: 128),
            bounded(definitionRevision, maximumUTF8Bytes: 128),
            bounded(provider, maximumUTF8Bytes: 128),
            planType.map({ bounded($0, maximumUTF8Bytes: 128) }) ?? true,
            bounded(model, maximumUTF8Bytes: 128),
            bounded(reasoningEffort, maximumUTF8Bytes: 64),
            isLowercaseSHA256(promptSHA256),
            (0...16 * 1_024 * 1_024).contains(promptByteCount),
            isLowercaseSHA256(responseSHA256),
            (0...1 * 1_024 * 1_024).contains(responseByteCount),
            isLowercaseSHA256(contextDigest),
            isLowercaseSHA256(sourceCountsSHA256),
            isLowercaseSHA256(signerDeviceID)
        else { return nil }

        var data = Data(Self.signingDomain.utf8)
        data.append(0)
        append(UInt64(schemaVersion), to: &data)
        for value in [
            runID,
            day,
            trigger,
            definitionID,
            definitionRevision,
            provider,
            planType ?? "",
            model,
            reasoningEffort,
            promptSHA256,
            responseSHA256,
            contextDigest,
            sourceCountsSHA256,
            signerDeviceID,
        ] {
            append(value, to: &data)
        }
        append(UInt64(generatedAtMilliseconds), to: &data)
        append(UInt64(promptByteCount), to: &data)
        append(UInt64(responseByteCount), to: &data)
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func bounded(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumUTF8Bytes && !value.contains("\0")
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
    }

    private static func isLocalDay(_ value: String) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let bytes = Array(value.utf8)
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else {
            return false
        }
        return bytes.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7
                ? byte == UInt8(ascii: "-")
                : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }
}
