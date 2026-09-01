import Foundation

private enum AnalysisProofTimestampFormatter {
    static let lock = NSLock()
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

public enum AnalysisProofTimestamp {
    public static func string(from date: Date) -> String {
        AnalysisProofTimestampFormatter.string(from: date)
    }

    public static func isCanonical(_ value: String) -> Bool {
        guard value.utf8.count == 24,
            value.hasSuffix("Z"),
            value[value.index(value.startIndex, offsetBy: 10)] == "T",
            value[value.index(value.startIndex, offsetBy: 19)] == "."
        else { return false }
        let punctuation: [Int: Character] = [4: "-", 7: "-", 10: "T", 13: ":", 16: ":", 19: ".", 23: "Z"]
        return value.enumerated().allSatisfy { index, character in
            if let expected = punctuation[index] { return character == expected }
            return character.isASCII && character.isNumber
        }
    }
}

public struct AnalysisArtifactDescriptor: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int
    public let mediaType: String

    public init(sha256: String, byteCount: Int, mediaType: String) {
        self.sha256 = sha256
        self.byteCount = max(0, byteCount)
        self.mediaType = mediaType
    }

    public init(data: Data, mediaType: String) {
        self.init(
            sha256: GoalongProofDigest.sha256(data),
            byteCount: data.count,
            mediaType: mediaType
        )
    }

    public var canonicalValue: GoalongCanonicalJSONValue {
        .object([
            "byte_count": .integer(Int64(byteCount)),
            "media_type": .string(mediaType),
            "sha256": .string(sha256),
        ])
    }

    public var isValid: Bool {
        GoalongProofDigest.isValid(sha256)
            && byteCount >= 0
            && !mediaType.isEmpty
            && mediaType.utf8.count <= 128
    }
}

public struct AnalysisDefinitionRevision: Codable, Equatable, Sendable {
    public static let jwsType = "goalong-analysis-definition+jws"

    public let schemaVersion: Int
    public let definitionID: String
    public let revision: String
    public let createdAt: String
    public let provider: String
    public let model: String
    public let reasoningEffort: String
    public let promptTemplate: AnalysisArtifactDescriptor
    public let contextPolicy: AnalysisArtifactDescriptor
    public let outputSchema: AnalysisArtifactDescriptor
    public let privacyMode: String

    public init(
        schemaVersion: Int = 1,
        definitionID: String,
        revision: String,
        createdAt: String,
        provider: String,
        model: String,
        reasoningEffort: String,
        promptTemplate: AnalysisArtifactDescriptor,
        contextPolicy: AnalysisArtifactDescriptor,
        outputSchema: AnalysisArtifactDescriptor,
        privacyMode: String = "hash_only_no_transcript_copy"
    ) {
        self.schemaVersion = schemaVersion
        self.definitionID = definitionID
        self.revision = revision
        self.createdAt = createdAt
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.promptTemplate = promptTemplate
        self.contextPolicy = contextPolicy
        self.outputSchema = outputSchema
        self.privacyMode = privacyMode
    }

    public func canonicalData() throws -> Data {
        try canonicalValue.encoded(maximumBytes: 64 * 1_024)
    }

    public var canonicalValue: GoalongCanonicalJSONValue {
        .object([
            "context_policy": contextPolicy.canonicalValue,
            "created_at": .string(createdAt),
            "definition_id": .string(definitionID),
            "model": .string(model),
            "output_schema": outputSchema.canonicalValue,
            "privacy_mode": .string(privacyMode),
            "prompt_template": promptTemplate.canonicalValue,
            "provider": .string(provider),
            "reasoning_effort": .string(reasoningEffort),
            "revision": .string(revision),
            "schema_version": .integer(Int64(schemaVersion)),
        ])
    }

    public var isValid: Bool {
        schemaVersion == 1
            && AnalysisProofTimestamp.isCanonical(createdAt)
            && [definitionID, revision, provider, model, reasoningEffort, privacyMode]
                .allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0") }
            && promptTemplate.isValid
            && contextPolicy.isValid
            && outputSchema.isValid
            && privacyMode == "hash_only_no_transcript_copy"
    }
}

public struct AnalysisContextSource: Codable, Equatable, Sendable {
    public let sourceID: String
    public let provider: String
    public let stableID: String
    public let sourceReference: String
    public let sourceKind: String
    public let availability: String
    public let byteCount: Int64
    public let fingerprint: String?
    public let modifiedAt: String?
    public let startOffset: Int64?
    public let endOffset: Int64?
    public let selectionDigest: String
    public let includedMaterialDigest: String
    public let coverage: String

    public init(
        sourceID: String,
        provider: String,
        stableID: String,
        sourceReference: String,
        sourceKind: String,
        availability: String,
        byteCount: Int64,
        fingerprint: String?,
        modifiedAt: String?,
        startOffset: Int64?,
        endOffset: Int64?,
        selectionDigest: String,
        includedMaterialDigest: String,
        coverage: String
    ) {
        self.sourceID = sourceID
        self.provider = provider
        self.stableID = stableID
        self.sourceReference = sourceReference
        self.sourceKind = sourceKind
        self.availability = availability
        self.byteCount = max(0, byteCount)
        self.fingerprint = fingerprint
        self.modifiedAt = modifiedAt
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.selectionDigest = selectionDigest
        self.includedMaterialDigest = includedMaterialDigest
        self.coverage = coverage
    }

    public var canonicalValue: GoalongCanonicalJSONValue {
        .object([
            "availability": .string(availability),
            "byte_count": .integer(byteCount),
            "coverage": .string(coverage),
            "end_offset": endOffset.map(GoalongCanonicalJSONValue.integer) ?? .null,
            "fingerprint": fingerprint.map(GoalongCanonicalJSONValue.string) ?? .null,
            "included_material_digest": .string(includedMaterialDigest),
            "modified_at": modifiedAt.map(GoalongCanonicalJSONValue.string) ?? .null,
            "provider": .string(provider),
            "selection_digest": .string(selectionDigest),
            "source_id": .string(sourceID),
            "source_kind": .string(sourceKind),
            "source_reference": .string(sourceReference),
            "stable_id": .string(stableID),
            "start_offset": startOffset.map(GoalongCanonicalJSONValue.integer) ?? .null,
        ])
    }

    public func commitment(salt: Data) throws -> Data {
        var material = Data("GOALONG-CONTEXT-SOURCE-V1\0".utf8)
        material.append(salt)
        material.append(try canonicalValue.encoded(maximumBytes: 16 * 1_024))
        return SHA256Digest.hash(material)
    }

    public var isValid: Bool {
        let bounded = [sourceID, provider, stableID, sourceReference, sourceKind, availability, coverage]
            .allSatisfy { !$0.isEmpty && $0.utf8.count <= 2 * 1_024 && !$0.contains("\0") }
        let offsetsValid = (startOffset.map { $0 >= 0 } ?? true)
            && (endOffset.map { $0 >= 0 } ?? true)
            && (startOffset == nil || endOffset == nil || startOffset! <= endOffset!)
        return bounded
            && byteCount >= 0
            && offsetsValid
            && (fingerprint.map(GoalongProofDigest.isValid) ?? true)
            && (modifiedAt.map(AnalysisProofTimestamp.isCanonical) ?? true)
            && GoalongProofDigest.isValid(selectionDigest)
            && GoalongProofDigest.isValid(includedMaterialDigest)
    }
}

public enum AnalysisSourceMerkleTree {
    public static func root(sources: [AnalysisContextSource], salt: Data) throws -> String {
        guard salt.count == 32 else { throw GoalongCanonicalJSONError.unsupportedValue }
        if sources.isEmpty {
            return GoalongProofDigest.sha256(Data("GOALONG-EMPTY-SOURCE-ROOT-V1".utf8))
        }
        var level = try sources
            .sorted { $0.sourceID < $1.sourceID }
            .map { source -> Data in
                var leaf = Data([0])
                leaf.append(try source.commitment(salt: salt))
                return SHA256Digest.hash(leaf)
            }
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity((level.count + 1) / 2)
            for index in stride(from: 0, to: level.count, by: 2) {
                let left = level[index]
                let right = index + 1 < level.count ? level[index + 1] : left
                var node = Data([1])
                node.append(left)
                node.append(right)
                next.append(SHA256Digest.hash(node))
            }
            level = next
        }
        return "sha256:\(GoalongBase64URL.encode(level[0]))"
    }
}

public struct AnalysisContextManifest: Codable, Equatable, Sendable {
    public static let maximumSources = 4_096

    public let schemaVersion: Int
    public let executionID: String
    public let day: String
    public let generatedAt: String
    public let sourceSaltBase64URL: String
    public let sourceRoot: String
    public let contextDigest: String
    public let sourceCountsDigest: String
    public let renderedContextBytes: Int
    public let coverageStatus: String
    public let sources: [AnalysisContextSource]

    public init(
        schemaVersion: Int = 1,
        executionID: String,
        day: String,
        generatedAt: String,
        sourceSaltBase64URL: String,
        sourceRoot: String,
        contextDigest: String,
        sourceCountsDigest: String,
        renderedContextBytes: Int,
        coverageStatus: String,
        sources: [AnalysisContextSource]
    ) {
        self.schemaVersion = schemaVersion
        self.executionID = executionID
        self.day = day
        self.generatedAt = generatedAt
        self.sourceSaltBase64URL = sourceSaltBase64URL
        self.sourceRoot = sourceRoot
        self.contextDigest = contextDigest
        self.sourceCountsDigest = sourceCountsDigest
        self.renderedContextBytes = max(0, renderedContextBytes)
        self.coverageStatus = coverageStatus
        self.sources = sources.sorted { $0.sourceID < $1.sourceID }
    }

    public func canonicalData() throws -> Data {
        try canonicalValue.encoded(maximumBytes: 4 * 1_024 * 1_024)
    }

    public var canonicalValue: GoalongCanonicalJSONValue {
        .object([
            "context_digest": .string(contextDigest),
            "coverage_status": .string(coverageStatus),
            "day": .string(day),
            "execution_id": .string(executionID),
            "generated_at": .string(generatedAt),
            "rendered_context_bytes": .integer(Int64(renderedContextBytes)),
            "schema_version": .integer(Int64(schemaVersion)),
            "source_counts_digest": .string(sourceCountsDigest),
            "source_root": .string(sourceRoot),
            "source_salt": .string(sourceSaltBase64URL),
            "sources": .array(sources.map(\.canonicalValue)),
        ])
    }

    public var isValid: Bool {
        guard schemaVersion == 1,
            UUID(uuidString: executionID) != nil,
            day.utf8.count == 10,
            AnalysisProofTimestamp.isCanonical(generatedAt),
            let salt = GoalongBase64URL.decode(sourceSaltBase64URL), salt.count == 32,
            GoalongProofDigest.isValid(sourceRoot),
            GoalongProofDigest.isValid(contextDigest),
            GoalongProofDigest.isValid(sourceCountsDigest),
            renderedContextBytes <= 64 * 1_024 * 1_024,
            !coverageStatus.isEmpty,
            sources.count <= Self.maximumSources,
            Set(sources.map(\.sourceID)).count == sources.count,
            sources.allSatisfy(\.isValid),
            let recomputed = try? AnalysisSourceMerkleTree.root(sources: sources, salt: salt)
        else { return false }
        return recomputed == sourceRoot
    }
}

public struct ProviderRequestArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let executionID: String
    public let provider: String
    public let model: String
    public let reasoningEffort: String
    public let prompt: AnalysisArtifactDescriptor
    public let outputSchema: AnalysisArtifactDescriptor
    public let contextManifest: AnalysisArtifactDescriptor
    public let permissionProfile: String
    public let networkAccess: String
    public let toolAccess: String
    public let retentionMode: String

    public init(
        schemaVersion: Int = 1,
        executionID: String,
        provider: String,
        model: String,
        reasoningEffort: String,
        prompt: AnalysisArtifactDescriptor,
        outputSchema: AnalysisArtifactDescriptor,
        contextManifest: AnalysisArtifactDescriptor,
        permissionProfile: String,
        networkAccess: String,
        toolAccess: String,
        retentionMode: String = "hash_only_no_transcript_copy"
    ) {
        self.schemaVersion = schemaVersion
        self.executionID = executionID
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.prompt = prompt
        self.outputSchema = outputSchema
        self.contextManifest = contextManifest
        self.permissionProfile = permissionProfile
        self.networkAccess = networkAccess
        self.toolAccess = toolAccess
        self.retentionMode = retentionMode
    }

    public func canonicalData() throws -> Data {
        try canonicalValue.encoded(maximumBytes: 64 * 1_024)
    }

    public var canonicalValue: GoalongCanonicalJSONValue {
        .object([
            "context_manifest": contextManifest.canonicalValue,
            "execution_id": .string(executionID),
            "model": .string(model),
            "network_access": .string(networkAccess),
            "output_schema": outputSchema.canonicalValue,
            "permission_profile": .string(permissionProfile),
            "prompt": prompt.canonicalValue,
            "provider": .string(provider),
            "reasoning_effort": .string(reasoningEffort),
            "retention_mode": .string(retentionMode),
            "schema_version": .integer(Int64(schemaVersion)),
            "tool_access": .string(toolAccess),
        ])
    }
}

public struct ProviderResponseArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let executionID: String
    public let provider: String
    public let threadID: String?
    public let turnID: String?
    public let observedAt: String
    public let rawResponse: AnalysisArtifactDescriptor
    public let parsedResult: AnalysisArtifactDescriptor
    public let status: String

    public init(
        schemaVersion: Int = 1,
        executionID: String,
        provider: String,
        threadID: String?,
        turnID: String?,
        observedAt: String,
        rawResponse: AnalysisArtifactDescriptor,
        parsedResult: AnalysisArtifactDescriptor,
        status: String
    ) {
        self.schemaVersion = schemaVersion
        self.executionID = executionID
        self.provider = provider
        self.threadID = threadID
        self.turnID = turnID
        self.observedAt = observedAt
        self.rawResponse = rawResponse
        self.parsedResult = parsedResult
        self.status = status
    }

    public func canonicalData() throws -> Data {
        try canonicalValue.encoded(maximumBytes: 64 * 1_024)
    }

    public var canonicalValue: GoalongCanonicalJSONValue {
        .object([
            "execution_id": .string(executionID),
            "observed_at": .string(observedAt),
            "parsed_result": parsedResult.canonicalValue,
            "provider": .string(provider),
            "raw_response": rawResponse.canonicalValue,
            "schema_version": .integer(Int64(schemaVersion)),
            "status": .string(status),
            "thread_id": threadID.map(GoalongCanonicalJSONValue.string) ?? .null,
            "turn_id": turnID.map(GoalongCanonicalJSONValue.string) ?? .null,
        ])
    }
}

public struct AnalysisRunProof: Codable, Equatable, Sendable {
    public static let jwsType = "goalong-analysis-run+jws"
    public static let maximumCanonicalBytes = 32 * 1_024

    public let schemaVersion: Int
    public let executionID: String
    public let nonceBase64URL: String
    public let sequence: Int64
    public let previousAttestationDigest: String?
    public let slot: String
    public let retryID: String?
    public let day: String
    public let periodStart: String
    public let periodEnd: String
    public let generatedAt: String
    public let trigger: String
    public let definitionJWS: AnalysisArtifactDescriptor
    public let contextManifest: AnalysisArtifactDescriptor
    public let providerRequest: AnalysisArtifactDescriptor
    public let providerResponse: AnalysisArtifactDescriptor
    public let sourceRoot: String
    public let firstActivityAnchor: String?
    public let lastActivityAnchor: String?
    public let providerObservation: String
    public let helperIdentity: String
    public let signerDeviceID: String
    public let keyID: String
    public let retentionMode: String
    public let softwareVersion: String
    public let softwareBuild: String
    public let buildTrust: String
    public let externalReceiptStatus: String
    public let appAttestStatus: String
    public let terminalStatus: String

    public init(
        schemaVersion: Int = 1,
        executionID: String,
        nonceBase64URL: String,
        sequence: Int64,
        previousAttestationDigest: String?,
        slot: String,
        retryID: String?,
        day: String,
        periodStart: String,
        periodEnd: String,
        generatedAt: String,
        trigger: String,
        definitionJWS: AnalysisArtifactDescriptor,
        contextManifest: AnalysisArtifactDescriptor,
        providerRequest: AnalysisArtifactDescriptor,
        providerResponse: AnalysisArtifactDescriptor,
        sourceRoot: String,
        firstActivityAnchor: String?,
        lastActivityAnchor: String?,
        providerObservation: String,
        helperIdentity: String,
        signerDeviceID: String,
        keyID: String,
        retentionMode: String,
        softwareVersion: String,
        softwareBuild: String,
        buildTrust: String,
        externalReceiptStatus: String,
        appAttestStatus: String,
        terminalStatus: String
    ) {
        self.schemaVersion = schemaVersion
        self.executionID = executionID
        self.nonceBase64URL = nonceBase64URL
        self.sequence = max(0, sequence)
        self.previousAttestationDigest = previousAttestationDigest
        self.slot = slot
        self.retryID = retryID
        self.day = day
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.generatedAt = generatedAt
        self.trigger = trigger
        self.definitionJWS = definitionJWS
        self.contextManifest = contextManifest
        self.providerRequest = providerRequest
        self.providerResponse = providerResponse
        self.sourceRoot = sourceRoot
        self.firstActivityAnchor = firstActivityAnchor
        self.lastActivityAnchor = lastActivityAnchor
        self.providerObservation = providerObservation
        self.helperIdentity = helperIdentity
        self.signerDeviceID = signerDeviceID
        self.keyID = keyID
        self.retentionMode = retentionMode
        self.softwareVersion = softwareVersion
        self.softwareBuild = softwareBuild
        self.buildTrust = buildTrust
        self.externalReceiptStatus = externalReceiptStatus
        self.appAttestStatus = appAttestStatus
        self.terminalStatus = terminalStatus
    }

    public func canonicalData() throws -> Data {
        try canonicalValue.encoded(maximumBytes: Self.maximumCanonicalBytes)
    }

    public var canonicalValue: GoalongCanonicalJSONValue {
        .object([
            "app_attest_status": .string(appAttestStatus),
            "build_trust": .string(buildTrust),
            "context_manifest": contextManifest.canonicalValue,
            "day": .string(day),
            "definition_jws": definitionJWS.canonicalValue,
            "execution_id": .string(executionID),
            "external_receipt_status": .string(externalReceiptStatus),
            "first_activity_anchor": firstActivityAnchor.map(GoalongCanonicalJSONValue.string) ?? .null,
            "generated_at": .string(generatedAt),
            "helper_identity": .string(helperIdentity),
            "key_id": .string(keyID),
            "last_activity_anchor": lastActivityAnchor.map(GoalongCanonicalJSONValue.string) ?? .null,
            "nonce": .string(nonceBase64URL),
            "period_end": .string(periodEnd),
            "period_start": .string(periodStart),
            "previous_attestation_digest": previousAttestationDigest.map(GoalongCanonicalJSONValue.string) ?? .null,
            "provider_observation": .string(providerObservation),
            "provider_request": providerRequest.canonicalValue,
            "provider_response": providerResponse.canonicalValue,
            "retention_mode": .string(retentionMode),
            "retry_id": retryID.map(GoalongCanonicalJSONValue.string) ?? .null,
            "schema_version": .integer(Int64(schemaVersion)),
            "sequence": .integer(sequence),
            "signer_device_id": .string(signerDeviceID),
            "slot": .string(slot),
            "software_build": .string(softwareBuild),
            "software_version": .string(softwareVersion),
            "source_root": .string(sourceRoot),
            "terminal_status": .string(terminalStatus),
            "trigger": .string(trigger),
        ])
    }

    public var isValid: Bool {
        let boundedStrings = [
            slot, day, trigger, providerObservation, helperIdentity, softwareVersion,
            softwareBuild, buildTrust, externalReceiptStatus, appAttestStatus, terminalStatus,
        ].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }
        guard schemaVersion == 1,
            UUID(uuidString: executionID) != nil,
            let nonce = GoalongBase64URL.decode(nonceBase64URL), nonce.count == 32,
            sequence >= 0,
            previousAttestationDigest.map(GoalongProofDigest.isValid) ?? true,
            AnalysisProofTimestamp.isCanonical(periodStart),
            AnalysisProofTimestamp.isCanonical(periodEnd),
            AnalysisProofTimestamp.isCanonical(generatedAt),
            GoalongProofDigest.isValid(sourceRoot),
            GoalongProofDigest.isValid(signerDeviceID),
            GoalongProofDigest.isValid(keyID),
            definitionJWS.isValid,
            contextManifest.isValid,
            providerRequest.isValid,
            providerResponse.isValid,
            firstActivityAnchor.map(GoalongProofDigest.isValid) ?? true,
            lastActivityAnchor.map(GoalongProofDigest.isValid) ?? true,
            retentionMode == "hash_only_no_transcript_copy",
            boundedStrings
        else { return false }
        return ((try? canonicalData().count) ?? Int.max) <= Self.maximumCanonicalBytes
    }
}

public struct AnalysisProofReference: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let executionID: String
    public let proofDirectoryName: String
    public let runJWSSHA256: String
    public let localSignatureStatus: String
    public let providerObservationStatus: String
    public let contextStatus: String
    public let activityAnchorStatus: String
    public let externalReceiptStatus: String
    public let appAttestStatus: String
    public let retentionMode: String

    public init(
        schemaVersion: Int = 1,
        executionID: String,
        proofDirectoryName: String,
        runJWSSHA256: String,
        localSignatureStatus: String,
        providerObservationStatus: String,
        contextStatus: String,
        activityAnchorStatus: String,
        externalReceiptStatus: String,
        appAttestStatus: String,
        retentionMode: String
    ) {
        self.schemaVersion = schemaVersion
        self.executionID = executionID
        self.proofDirectoryName = proofDirectoryName
        self.runJWSSHA256 = runJWSSHA256
        self.localSignatureStatus = localSignatureStatus
        self.providerObservationStatus = providerObservationStatus
        self.contextStatus = contextStatus
        self.activityAnchorStatus = activityAnchorStatus
        self.externalReceiptStatus = externalReceiptStatus
        self.appAttestStatus = appAttestStatus
        self.retentionMode = retentionMode
    }
}

public struct AnalysisProofVerificationReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let isLocallyValid: Bool
    public let runSignature: String
    public let definitionSignature: String
    public let artifactHashes: String
    public let contextManifest: String
    public let sourceCommitments: String
    public let chainContinuity: String
    public let activityAnchors: String
    public let providerObservation: String
    public let externalReceipt: String
    public let appAttest: String
    public let privacyMode: String
    public let issues: [String]
    public let limitation: String

    public init(
        schemaVersion: Int = 1,
        isLocallyValid: Bool,
        runSignature: String,
        definitionSignature: String,
        artifactHashes: String,
        contextManifest: String,
        sourceCommitments: String,
        chainContinuity: String,
        activityAnchors: String,
        providerObservation: String,
        externalReceipt: String,
        appAttest: String,
        privacyMode: String,
        issues: [String],
        limitation: String
    ) {
        self.schemaVersion = schemaVersion
        self.isLocallyValid = isLocallyValid
        self.runSignature = runSignature
        self.definitionSignature = definitionSignature
        self.artifactHashes = artifactHashes
        self.contextManifest = contextManifest
        self.sourceCommitments = sourceCommitments
        self.chainContinuity = chainContinuity
        self.activityAnchors = activityAnchors
        self.providerObservation = providerObservation
        self.externalReceipt = externalReceipt
        self.appAttest = appAttest
        self.privacyMode = privacyMode
        self.issues = issues
        self.limitation = limitation
    }
}
