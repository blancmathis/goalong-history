import CryptoKit
import Foundation
import XCTest

@testable import LocalHistoryCore

/// Builds a locally signed standalone proof, a signed recap and a signed share package for the CLI verification tests.
enum GoalongCLIProofFixture {
    static let day = "2026-08-31"

    static func proofEntries() throws -> (entries: [String: Data], executionID: String) {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let keyID = try XCTUnwrap(GoalongES256JWS.keyID(publicKeyX963: publicKey))
        let executionID = UUID().uuidString.lowercased()
        let timestamp = "2026-08-31T10:00:00.000Z"
        let simple = Data("fixture".utf8)
        let definition = AnalysisDefinitionRevision(
            definitionID: "daily", revision: "v1", createdAt: timestamp,
            provider: "codex", model: "gpt-5.6-luna", reasoningEffort: "high",
            promptTemplate: AnalysisArtifactDescriptor(data: simple, mediaType: "text/plain"),
            contextPolicy: AnalysisArtifactDescriptor(data: simple, mediaType: "text/plain"),
            outputSchema: AnalysisArtifactDescriptor(data: simple, mediaType: "application/json")
        )
        let definitionData = Data(
            try GoalongES256JWS.compact(
                canonicalPayload: definition.canonicalData(),
                type: AnalysisDefinitionRevision.jwsType,
                publicKeyX963: publicKey
            ) { try key.signature(for: $0).derRepresentation }.utf8)
        let salt = Data(repeating: 7, count: 32)
        let source = AnalysisContextSource(
            sourceID: "source-1", provider: "codex", stableID: "conversation-1",
            sourceReference: "/original/provider/session.jsonl", sourceKind: "file",
            availability: "available", byteCount: 123,
            fingerprint: GoalongProofDigest.sha256(simple), modifiedAt: timestamp,
            startOffset: 0, endOffset: 123,
            selectionDigest: GoalongProofDigest.sha256(Data("selection".utf8)),
            includedMaterialDigest: GoalongProofDigest.sha256(Data("visible messages hash only".utf8)),
            coverage: "complete_direct_read"
        )
        let contextManifest = AnalysisContextManifest(
            executionID: executionID, day: day, generatedAt: timestamp,
            sourceSaltBase64URL: GoalongBase64URL.encode(salt),
            sourceRoot: try AnalysisSourceMerkleTree.root(sources: [source], salt: salt),
            contextDigest: GoalongProofDigest.sha256(Data("context".utf8)),
            sourceCountsDigest: GoalongProofDigest.sha256(Data("counts".utf8)),
            renderedContextBytes: 7, coverageStatus: "complete", sources: [source]
        )
        let contextData = try contextManifest.canonicalData()
        let requestData = try ProviderRequestArtifact(
            executionID: executionID, provider: "codex", model: "gpt-5.6-luna",
            reasoningEffort: "high",
            prompt: AnalysisArtifactDescriptor(data: Data("private prompt hash only".utf8), mediaType: "text/plain"),
            outputSchema: AnalysisArtifactDescriptor(data: simple, mediaType: "application/json"),
            contextManifest: AnalysisArtifactDescriptor(data: contextData, mediaType: "application/json"),
            permissionProfile: "restricted", networkAccess: "disabled", toolAccess: "disabled"
        ).canonicalData()
        let resultData = try GoalongCanonicalJSONValue.object([
            "summary_lines": .array((1...5).map { .string("Line \($0)") })
        ]).encoded()
        let responseData = try ProviderResponseArtifact(
            executionID: executionID, provider: "codex", threadID: "thread", turnID: "turn",
            observedAt: timestamp,
            rawResponse: AnalysisArtifactDescriptor(data: resultData, mediaType: "application/json"),
            parsedResult: AnalysisArtifactDescriptor(data: resultData, mediaType: "application/json"),
            status: "exact_final_assistant_bytes_encrypted_locally"
        ).canonicalData()
        let run = AnalysisRunProof(
            executionID: executionID,
            nonceBase64URL: GoalongBase64URL.encode(Data(repeating: 9, count: 32)),
            sequence: 0, previousAttestationDigest: nil, slot: "daily:\(day)", retryID: nil,
            day: day, periodStart: "2026-08-31T00:00:00.000Z", periodEnd: "2026-09-01T00:00:00.000Z",
            generatedAt: timestamp, trigger: "manual",
            definitionJWS: AnalysisArtifactDescriptor(data: definitionData, mediaType: "application/jose"),
            contextManifest: AnalysisArtifactDescriptor(data: contextData, mediaType: "application/json"),
            providerRequest: AnalysisArtifactDescriptor(data: requestData, mediaType: "application/json"),
            providerResponse: AnalysisArtifactDescriptor(data: responseData, mediaType: "application/json"),
            sourceRoot: contextManifest.sourceRoot,
            firstActivityAnchor: nil, lastActivityAnchor: nil,
            providerObservation: "local_codex_app_server_final_stream_observed",
            helperIdentity: "restricted_ephemeral",
            signerDeviceID: GoalongProofDigest.sha256(publicKey), keyID: keyID,
            retentionMode: "hash_only_no_transcript_copy", softwareVersion: "1", softwareBuild: "1",
            buildTrust: "local_build", externalReceiptStatus: "not_present",
            appAttestStatus: "local_build_not_eligible", terminalStatus: "completed"
        )
        let runJWS = Data(
            try GoalongES256JWS.compact(
                canonicalPayload: run.canonicalData(),
                type: AnalysisRunProof.jwsType,
                publicKeyX963: publicKey
            ) { try key.signature(for: $0).derRepresentation }.utf8)
        var files: [String: Data] = [
            "definition.jws": definitionData, "context-manifest.json": contextData,
            "provider-request.json": requestData, "provider-response.json": responseData,
            "result.json": resultData, "device-public-key.x963": publicKey, "run.jws": runJWS,
        ]
        files["manifest.json"] = try manifest(for: files)
        return (files, executionID)
    }

    static func manifest(for files: [String: Data]) throws -> Data {
        let rows = files.sorted { $0.key < $1.key }.map { path, data in
            GoalongCanonicalJSONValue.object([
                "byte_count": .integer(Int64(data.count)),
                "path": .string(path),
                "sha256": .string(GoalongProofDigest.sha256(data)),
            ])
        }
        return try GoalongCanonicalJSONValue.object([
            "files": .array(rows),
            "format": .string("goalong-proof-directory-v1"),
            "schema_version": .integer(1),
        ]).encoded()
    }

    /// Writes the proof files under `root/chatgpt/proofs/<executionID>/`.
    static func writeProofDirectory(_ entries: [String: Data], executionID: String, root: URL) throws {
        let directory = root.appendingPathComponent("chatgpt/proofs/\(executionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in entries { try data.write(to: directory.appendingPathComponent(name)) }
    }

    static let summaryLines = (1...5).map { "Signed summary line \($0)" }
    static let sourceCounts = ["codex": 3, "claude": 1]

    /// The local midnight of `day`, so the CLI's local-day string is the same in every time zone.
    static var dayDate: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 31))!
    }

    static var generatedAt: Date { dayDate.addingTimeInterval(36_000) }

    static func isoString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// A recap JSON object. `signed: false` leaves it as a legacy unsigned recap.
    static func recapObject(
        signed: Bool = true,
        schemaVersion: Int = 3,
        proof: [String: Any]? = nil
    ) throws -> [String: Any] {
        let markdown = summaryLines.joined(separator: "\n")
        var object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "day": isoString(dayDate),
            "generatedAt": isoString(generatedAt),
            "provider": "codex",
            "contextDigest": String(repeating: "c", count: 64),
            "sourceCounts": sourceCounts,
            "markdown": markdown,
            "model": "gpt-5.6-luna",
            "reasoningEffort": "high",
            "productivityScore": 70,
            "confidenceScore": 80,
            "summaryLines": summaryLines,
        ]
        if let proof { object["proof"] = proof }
        guard signed else { return object }

        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let deviceID = SHA256Digest.hashHex(publicKey)
        let saved = try XCTUnwrap(
            AnalysisRunSavedResult(
                markdown: markdown, productivityScore: 70, confidenceScore: 80,
                summaryLines: summaryLines
            ).canonicalData())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let countsData = try encoder.encode(sourceCounts)
        let runID = (proof?["executionID"] as? String) ?? UUID().uuidString.lowercased()
        let fields: [String: Any] = [
            "schemaVersion": 1, "runID": runID, "day": day,
            "generatedAtMilliseconds": Int64(generatedAt.timeIntervalSince1970 * 1_000),
            "trigger": "manual",
            "definitionID": GoalongDailyAnalysisDefinition.identifier,
            "definitionRevision": GoalongDailyAnalysisDefinition.revision,
            "provider": "codex", "model": "gpt-5.6-luna", "reasoningEffort": "high",
            "promptSHA256": String(repeating: "a", count: 64), "promptByteCount": 10,
            "responseSHA256": SHA256Digest.hashHex(saved), "responseByteCount": saved.count,
            "contextDigest": String(repeating: "c", count: 64),
            "sourceCountsSHA256": SHA256Digest.hashHex(countsData),
            "signerDeviceID": deviceID,
            "publicKeyBase64": publicKey.base64EncodedString(),
            "signatureAlgorithm": AnchorSignatureVerifier.supportedAlgorithm,
        ]
        var attestation = fields
        let unsigned = try JSONDecoder().decode(
            AnalysisRunAttestation.self,
            from: JSONSerialization.data(
                withJSONObject: fields.merging(["signatureBase64": ""]) { $1 })
        )
        let message = try XCTUnwrap(unsigned.signingMessage())
        attestation["signatureBase64"] = try key.signature(for: message).derRepresentation
            .base64EncodedString()
        object["attestation"] = attestation
        return object
    }

    static func proofReference(executionID: String, runJWS: Data) -> [String: Any] {
        [
            "schemaVersion": 1, "executionID": executionID, "proofDirectoryName": executionID,
            "runJWSSHA256": GoalongProofDigest.sha256(runJWS), "localSignatureStatus": "valid",
            "providerObservationStatus": "observed", "contextStatus": "valid",
            "activityAnchorStatus": "not_present", "externalReceiptStatus": "not_present",
            "appAttestStatus": "local_build_not_eligible",
            "retentionMode": "hash_only_no_transcript_copy",
        ]
    }

    static func writeRecap(_ object: [String: Any], root: URL, day: String = day) throws {
        let directory = root.appendingPathComponent("chatgpt/recaps", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent("\(day).chatgpt-recap.json"))
    }

    /// A signed one-minute share package for `day`; `tamperSignature` replaces the device signature.
    static func sharePackage(tamperSignature: Bool = false, minuteCount: Int = 1) throws -> DaySharePackage {
        let minuteFields = IntegrityDomains.minuteFieldOrder.enumerated().map { index, name in
            CommitmentBuilder.makeMinute(
                name: name,
                fields: name == "time" ? ["local_day": day] : ["value": "signed-\(name)"],
                salt: Data(repeating: UInt8(index + 31), count: 32)
            )
        }
        let commitments = Dictionary(uniqueKeysWithValues: minuteFields.map { ($0.name, $0.commitmentHex) })
        let minuteRoot = MerkleTree.root(
            labeledHexValues: IntegrityDomains.minuteFieldOrder.map { ($0, commitments[$0]!) })
        let previous = String(repeating: "0", count: 64)
        let key = P256.Signing.PrivateKey()
        let publicKeyData = key.publicKey.x963Representation
        let deviceID = SHA256Digest.hashHex(publicKeyData)
        let signature = try key.signature(
            for: ChainHash.signingMessage(
                deviceID: deviceID, sequence: 7, previous: previous, minuteRoot: minuteRoot))
        let signatureBase64 = tamperSignature
            ? Data("tampered".utf8).base64EncodedString()
            : signature.derRepresentation.base64EncodedString()
        let disclosure = MinuteDisclosure(
            anchorSequence: 7, minuteRoot: minuteRoot, previousAnchorHash: previous,
            anchorHash: ChainHash.anchor(sequence: 7, previous: previous, minuteRoot: minuteRoot),
            shareLevel: .privateOnly,
            minuteFields: minuteFields.map {
                FieldDisclosure(
                    name: $0.name, commitmentHex: $0.commitmentHex,
                    opening: ["time", "coverage"].contains($0.name) ? $0.opening : nil)
            },
            eventRoots: nil, events: nil, signatureBase64: signatureBase64,
            signatureAlgorithm: AnchorSignatureVerifier.supportedAlgorithm,
            publicKeyBase64: publicKeyData.base64EncodedString(), deviceID: deviceID,
            trustTier: "keychain_software", liveReceiptID: nil
        )
        return DaySharePackage(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            deviceID: deviceID, deviceIDs: [deviceID], localDay: day, classifierVersion: "test",
            minutes: minuteCount == 0 ? [] : [disclosure]
        )
    }
}
