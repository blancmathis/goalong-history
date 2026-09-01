import CryptoKit
import Foundation
import XCTest

@testable import LocalHistoryCore

final class AnalysisProofTests: XCTestCase {
    func testCanonicalJSONRejectsDuplicateKeysAndFloatingPointValues() throws {
        XCTAssertThrowsError(
            try GoalongCanonicalJSONValue.parse(Data(#"{"a":1,"a":2}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? GoalongCanonicalJSONError, .duplicateKey("a"))
        }
        XCTAssertThrowsError(
            try GoalongCanonicalJSONValue.parse(Data(#"{"value":1.5}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? GoalongCanonicalJSONError, .unsupportedValue)
        }

        let value = GoalongCanonicalJSONValue.object([
            "z": .integer(2),
            "a": .string("é/\n"),
        ])
        XCTAssertEqual(
            String(decoding: try value.encoded(), as: UTF8.self),
            #"{"a":"é/\n","z":2}"#
        )
    }

    func testES256JWSUsesCanonicalPayloadSPKIKIDAndLowSRawSignature() throws {
        let key = P256.Signing.PrivateKey()
        let payload = try GoalongCanonicalJSONValue.object([
            "execution_id": .string(UUID().uuidString.lowercased()),
            "schema_version": .integer(1),
        ]).encoded()
        let compact = try GoalongES256JWS.compact(
            canonicalPayload: payload,
            type: "goalong-test+jws",
            publicKeyX963: key.publicKey.x963Representation
        ) { message in
            try key.signature(for: message).derRepresentation
        }
        let verification = GoalongES256JWS.verify(
            compact,
            expectedType: "goalong-test+jws",
            publicKeyX963: key.publicKey.x963Representation
        )
        XCTAssertTrue(verification.valid, verification.issue ?? "")
        XCTAssertEqual(verification.payload, payload)
        XCTAssertTrue(verification.keyID?.hasPrefix("sha256:") == true)

        var parts = compact.split(separator: ".").map(String.init)
        var signature = try XCTUnwrap(GoalongBase64URL.decode(parts[2]))
        signature[63] ^= 0x01
        parts[2] = GoalongBase64URL.encode(signature)
        XCTAssertFalse(
            GoalongES256JWS.verify(
                parts.joined(separator: "."),
                expectedType: "goalong-test+jws",
                publicKeyX963: key.publicKey.x963Representation
            ).valid
        )
    }

    func testStandaloneProofRoundTripsAndRejectsTamperingAndUnlistedEntries() throws {
        let fixture = try proofFixture()
        let archive = try GoalongProofArchive.create(entries: fixture.entries)
        XCTAssertLessThan(archive.count, GoalongProofArchive.maximumArchiveBytes)
        let report = try GoalongProofPackageVerifier.verify(archive: archive)
        XCTAssertTrue(report.isLocallyValid, report.issues.joined(separator: ", "))
        XCTAssertEqual(report.runSignature, "valid")
        XCTAssertEqual(report.definitionSignature, "valid")
        XCTAssertEqual(report.sourceCommitments, "valid")
        XCTAssertEqual(report.externalReceipt, "not_present")

        var tampered = fixture.entries
        tampered["result.json"] = Data(#"{"altered":true}"#.utf8)
        let tamperedReport = try GoalongProofPackageVerifier.verify(
            archive: GoalongProofArchive.create(entries: tampered)
        )
        XCTAssertFalse(tamperedReport.isLocallyValid)
        XCTAssertTrue(tamperedReport.issues.contains("artifact_hash_mismatch:result.json"))

        var rebound = fixture.entries
        rebound.removeValue(forKey: "manifest.json")
        rebound["result.json"] = Data(#"{"altered":true}"#.utf8)
        rebound = try addingManifest(to: rebound)
        let reboundReport = try GoalongProofPackageVerifier.verify(
            archive: GoalongProofArchive.create(entries: rebound)
        )
        XCTAssertFalse(reboundReport.isLocallyValid)
        XCTAssertTrue(reboundReport.issues.contains("response_result_descriptor_mismatch"))

        var extra = fixture.entries
        extra["unlisted.txt"] = Data("hidden".utf8)
        XCTAssertThrowsError(
            try GoalongProofPackageVerifier.verify(
                archive: GoalongProofArchive.create(entries: extra)
            )
        ) { error in
            XCTAssertEqual(error as? GoalongProofArchiveError, .manifestMismatch)
        }
    }

    func testProofArchiveRejectsTraversalAndBoundsStorage() throws {
        XCTAssertThrowsError(
            try GoalongProofArchive.create(entries: ["../escape": Data()])
        ) { error in
            XCTAssertEqual(error as? GoalongProofArchiveError, .unsafePath("../escape"))
        }
        XCTAssertThrowsError(
            try GoalongProofArchive.create(entries: [
                "large.bin": Data(count: GoalongProofArchive.maximumEntryBytes + 1)
            ])
        ) { error in
            XCTAssertEqual(error as? GoalongProofArchiveError, .tooLarge)
        }
    }

    private func proofFixture() throws -> (entries: [String: Data], runID: UUID) {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let keyID = try XCTUnwrap(GoalongES256JWS.keyID(publicKeyX963: publicKey))
        let runID = UUID()
        let executionID = runID.uuidString.lowercased()
        let timestamp = "2026-08-31T10:00:00.000Z"
        let simple = Data("fixture".utf8)
        let definition = AnalysisDefinitionRevision(
            definitionID: "daily",
            revision: "v1",
            createdAt: timestamp,
            provider: "codex",
            model: "gpt-5.6-luna",
            reasoningEffort: "high",
            promptTemplate: AnalysisArtifactDescriptor(data: simple, mediaType: "text/plain"),
            contextPolicy: AnalysisArtifactDescriptor(data: simple, mediaType: "text/plain"),
            outputSchema: AnalysisArtifactDescriptor(data: simple, mediaType: "application/json")
        )
        let definitionJWS = try GoalongES256JWS.compact(
            canonicalPayload: definition.canonicalData(),
            type: AnalysisDefinitionRevision.jwsType,
            publicKeyX963: publicKey
        ) { try key.signature(for: $0).derRepresentation }
        let definitionData = Data(definitionJWS.utf8)

        let salt = Data(repeating: 7, count: 32)
        let source = AnalysisContextSource(
            sourceID: "source-1",
            provider: "codex",
            stableID: "conversation-1",
            sourceReference: "/original/provider/session.jsonl",
            sourceKind: "file",
            availability: "available",
            byteCount: 123,
            fingerprint: GoalongProofDigest.sha256(simple),
            modifiedAt: timestamp,
            startOffset: 0,
            endOffset: 123,
            selectionDigest: GoalongProofDigest.sha256(Data("selection".utf8)),
            includedMaterialDigest: GoalongProofDigest.sha256(Data("visible messages hash only".utf8)),
            coverage: "complete_direct_read"
        )
        let contextManifest = AnalysisContextManifest(
            executionID: executionID,
            day: "2026-08-31",
            generatedAt: timestamp,
            sourceSaltBase64URL: GoalongBase64URL.encode(salt),
            sourceRoot: try AnalysisSourceMerkleTree.root(sources: [source], salt: salt),
            contextDigest: GoalongProofDigest.sha256(Data("context".utf8)),
            sourceCountsDigest: GoalongProofDigest.sha256(Data("counts".utf8)),
            renderedContextBytes: 7,
            coverageStatus: "complete",
            sources: [source]
        )
        XCTAssertTrue(contextManifest.isValid)
        let contextData = try contextManifest.canonicalData()
        let request = ProviderRequestArtifact(
            executionID: executionID,
            provider: "codex",
            model: "gpt-5.6-luna",
            reasoningEffort: "high",
            prompt: AnalysisArtifactDescriptor(data: Data("private prompt hash only".utf8), mediaType: "text/plain"),
            outputSchema: AnalysisArtifactDescriptor(data: simple, mediaType: "application/json"),
            contextManifest: AnalysisArtifactDescriptor(data: contextData, mediaType: "application/json"),
            permissionProfile: "restricted",
            networkAccess: "disabled",
            toolAccess: "disabled"
        )
        let requestData = try request.canonicalData()
        let resultData = try GoalongCanonicalJSONValue.object([
            "summary_lines": .array((1...5).map { .string("Line \($0)") })
        ]).encoded()
        let response = ProviderResponseArtifact(
            executionID: executionID,
            provider: "codex",
            threadID: "thread",
            turnID: "turn",
            observedAt: timestamp,
            rawResponse: AnalysisArtifactDescriptor(data: resultData, mediaType: "application/json"),
            parsedResult: AnalysisArtifactDescriptor(data: resultData, mediaType: "application/json"),
            status: "exact_final_assistant_bytes_encrypted_locally"
        )
        let responseData = try response.canonicalData()
        let run = AnalysisRunProof(
            executionID: executionID,
            nonceBase64URL: GoalongBase64URL.encode(Data(repeating: 9, count: 32)),
            sequence: 0,
            previousAttestationDigest: nil,
            slot: "daily:2026-08-31",
            retryID: nil,
            day: "2026-08-31",
            periodStart: "2026-08-31T00:00:00.000Z",
            periodEnd: "2026-09-01T00:00:00.000Z",
            generatedAt: timestamp,
            trigger: "manual",
            definitionJWS: AnalysisArtifactDescriptor(data: definitionData, mediaType: "application/jose"),
            contextManifest: AnalysisArtifactDescriptor(data: contextData, mediaType: "application/json"),
            providerRequest: AnalysisArtifactDescriptor(data: requestData, mediaType: "application/json"),
            providerResponse: AnalysisArtifactDescriptor(data: responseData, mediaType: "application/json"),
            sourceRoot: contextManifest.sourceRoot,
            firstActivityAnchor: nil,
            lastActivityAnchor: nil,
            providerObservation: "local_codex_app_server_final_stream_observed",
            helperIdentity: "restricted_ephemeral",
            signerDeviceID: GoalongProofDigest.sha256(publicKey),
            keyID: keyID,
            retentionMode: "hash_only_no_transcript_copy",
            softwareVersion: "1",
            softwareBuild: "1",
            buildTrust: "local_build",
            externalReceiptStatus: "not_present",
            appAttestStatus: "local_build_not_eligible",
            terminalStatus: "completed"
        )
        XCTAssertTrue(run.isValid)
        let runJWS = try GoalongES256JWS.compact(
            canonicalPayload: run.canonicalData(),
            type: AnalysisRunProof.jwsType,
            publicKeyX963: publicKey
        ) { try key.signature(for: $0).derRepresentation }
        let files: [String: Data] = [
            "definition.jws": definitionData,
            "context-manifest.json": contextData,
            "provider-request.json": requestData,
            "provider-response.json": responseData,
            "result.json": resultData,
            "device-public-key.x963": publicKey,
            "run.jws": Data(runJWS.utf8),
        ]
        return (try addingManifest(to: files), runID)
    }

    private func addingManifest(to files: [String: Data]) throws -> [String: Data] {
        var output = files
        let rows = files.sorted { $0.key < $1.key }.map { path, data in
            GoalongCanonicalJSONValue.object([
                "byte_count": .integer(Int64(data.count)),
                "path": .string(path),
                "sha256": .string(GoalongProofDigest.sha256(data)),
            ])
        }
        output["manifest.json"] = try GoalongCanonicalJSONValue.object([
            "files": .array(rows),
            "format": .string("goalong-proof-directory-v1"),
            "schema_version": .integer(1),
        ]).encoded()
        return output
    }
}
