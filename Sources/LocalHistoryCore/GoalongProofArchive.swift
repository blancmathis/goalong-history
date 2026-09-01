import Foundation

public enum GoalongProofArchiveError: Error, Equatable, LocalizedError {
    case tooLarge
    case tooManyEntries
    case unsafePath(String)
    case duplicatePath(String)
    case unsupportedZIP
    case malformedZIP
    case checksumMismatch(String)
    case manifestMismatch

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "The Goalong proof package exceeded its size limit."
        case .tooManyEntries: return "The Goalong proof package contains too many entries."
        case .unsafePath(let path): return "The Goalong proof package contains an unsafe path: \(path)."
        case .duplicatePath(let path): return "The Goalong proof package contains a duplicate path: \(path)."
        case .unsupportedZIP: return "The Goalong proof package uses an unsupported ZIP feature."
        case .malformedZIP: return "The Goalong proof package is malformed."
        case .checksumMismatch(let path): return "The Goalong proof package checksum failed for \(path)."
        case .manifestMismatch: return "The Goalong proof package inventory does not match its manifest."
        }
    }
}

/// A deliberately small ZIP profile for standalone `.goalong-proof` files.
/// Only stored (uncompressed) regular UTF-8 entries are accepted. This keeps
/// verification streaming-friendly and rejects path traversal, symlinks,
/// duplicate entries, data descriptors, ZIP64 and decompression bombs.
public enum GoalongProofArchive {
    public static let maximumArchiveBytes = 16 * 1_024 * 1_024
    public static let maximumEntryBytes = 4 * 1_024 * 1_024
    public static let maximumEntries = 32

    public static func create(entries: [String: Data]) throws -> Data {
        guard entries.count <= maximumEntries else { throw GoalongProofArchiveError.tooManyEntries }
        let sorted = try entries.map { path, data -> (String, Data) in
            guard isSafePath(path) else { throw GoalongProofArchiveError.unsafePath(path) }
            guard data.count <= maximumEntryBytes else { throw GoalongProofArchiveError.tooLarge }
            return (path, data)
        }.sorted { $0.0 < $1.0 }

        struct CentralEntry {
            let path: String
            let data: Data
            let crc: UInt32
            let offset: UInt32
        }
        var archive = Data()
        var central: [CentralEntry] = []
        for (path, data) in sorted {
            guard archive.count <= Int(UInt32.max), data.count <= Int(UInt32.max) else {
                throw GoalongProofArchiveError.tooLarge
            }
            let name = Data(path.utf8)
            let crc = CRC32.hash(data)
            let offset = UInt32(archive.count)
            appendUInt32(0x0403_4B50, to: &archive)
            appendUInt16(20, to: &archive)
            appendUInt16(0x0800, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(crc, to: &archive)
            appendUInt32(UInt32(data.count), to: &archive)
            appendUInt32(UInt32(data.count), to: &archive)
            appendUInt16(UInt16(name.count), to: &archive)
            appendUInt16(0, to: &archive)
            archive.append(name)
            archive.append(data)
            central.append(CentralEntry(path: path, data: data, crc: crc, offset: offset))
        }
        let centralOffset = archive.count
        for entry in central {
            let name = Data(entry.path.utf8)
            appendUInt32(0x0201_4B50, to: &archive)
            appendUInt16(0x0314, to: &archive)
            appendUInt16(20, to: &archive)
            appendUInt16(0x0800, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(entry.crc, to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt16(UInt16(name.count), to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(UInt32(0o100644) << 16, to: &archive)
            appendUInt32(entry.offset, to: &archive)
            archive.append(name)
        }
        let centralSize = archive.count - centralOffset
        guard archive.count + 22 <= maximumArchiveBytes,
            centralOffset <= Int(UInt32.max), centralSize <= Int(UInt32.max)
        else { throw GoalongProofArchiveError.tooLarge }
        appendUInt32(0x0605_4B50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(central.count), to: &archive)
        appendUInt16(UInt16(central.count), to: &archive)
        appendUInt32(UInt32(centralSize), to: &archive)
        appendUInt32(UInt32(centralOffset), to: &archive)
        appendUInt16(0, to: &archive)
        return archive
    }

    public static func extract(_ archive: Data) throws -> [String: Data] {
        guard archive.count <= maximumArchiveBytes, archive.count >= 22 else {
            throw GoalongProofArchiveError.tooLarge
        }
        let eocd = archive.count - 22
        guard readUInt32(archive, at: eocd) == 0x0605_4B50,
            readUInt16(archive, at: eocd + 4) == 0,
            readUInt16(archive, at: eocd + 6) == 0,
            let diskEntries = readUInt16(archive, at: eocd + 8),
            let totalEntries = readUInt16(archive, at: eocd + 10),
            diskEntries == totalEntries,
            Int(totalEntries) <= maximumEntries,
            let centralSize = readUInt32(archive, at: eocd + 12),
            let centralOffset = readUInt32(archive, at: eocd + 16),
            readUInt16(archive, at: eocd + 20) == 0,
            Int(centralOffset) + Int(centralSize) == eocd
        else { throw GoalongProofArchiveError.malformedZIP }

        struct Entry {
            let path: String
            let crc: UInt32
            let size: Int
            let localOffset: Int
        }
        var entries: [Entry] = []
        var seen: Set<String> = []
        var cursor = Int(centralOffset)
        for _ in 0..<Int(totalEntries) {
            guard readUInt32(archive, at: cursor) == 0x0201_4B50,
                let versionMade = readUInt16(archive, at: cursor + 4),
                let versionNeeded = readUInt16(archive, at: cursor + 6),
                versionNeeded == 20,
                let flags = readUInt16(archive, at: cursor + 8), flags == 0x0800,
                readUInt16(archive, at: cursor + 10) == 0,
                let crc = readUInt32(archive, at: cursor + 16),
                let compressed = readUInt32(archive, at: cursor + 20),
                let uncompressed = readUInt32(archive, at: cursor + 24),
                compressed == uncompressed,
                Int(uncompressed) <= maximumEntryBytes,
                let nameLength = readUInt16(archive, at: cursor + 28), nameLength > 0,
                let extraLength = readUInt16(archive, at: cursor + 30), extraLength == 0,
                let commentLength = readUInt16(archive, at: cursor + 32), commentLength == 0,
                readUInt16(archive, at: cursor + 34) == 0,
                readUInt16(archive, at: cursor + 36) == 0,
                let externalAttributes = readUInt32(archive, at: cursor + 38),
                let localOffset = readUInt32(archive, at: cursor + 42)
            else { throw GoalongProofArchiveError.unsupportedZIP }
            let madeByUnix = (versionMade >> 8) == 3
            let fileType = UInt16((externalAttributes >> 16) & 0o170000)
            guard !madeByUnix || fileType == 0 || fileType == 0o100000 else {
                throw GoalongProofArchiveError.unsupportedZIP
            }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= eocd,
                let path = String(data: archive[nameStart..<nameEnd], encoding: .utf8),
                isSafePath(path)
            else { throw GoalongProofArchiveError.malformedZIP }
            guard seen.insert(path).inserted else {
                throw GoalongProofArchiveError.duplicatePath(path)
            }
            entries.append(
                Entry(path: path, crc: crc, size: Int(uncompressed), localOffset: Int(localOffset))
            )
            cursor = nameEnd
        }
        guard cursor == eocd else { throw GoalongProofArchiveError.malformedZIP }

        var ranges: [Range<Int>] = []
        var output: [String: Data] = [:]
        for entry in entries {
            let offset = entry.localOffset
            guard readUInt32(archive, at: offset) == 0x0403_4B50,
                readUInt16(archive, at: offset + 4) == 20,
                readUInt16(archive, at: offset + 6) == 0x0800,
                readUInt16(archive, at: offset + 8) == 0,
                readUInt32(archive, at: offset + 14) == entry.crc,
                readUInt32(archive, at: offset + 18) == UInt32(entry.size),
                readUInt32(archive, at: offset + 22) == UInt32(entry.size),
                let nameLength = readUInt16(archive, at: offset + 26),
                readUInt16(archive, at: offset + 28) == 0
            else { throw GoalongProofArchiveError.malformedZIP }
            let nameStart = offset + 30
            let nameEnd = nameStart + Int(nameLength)
            let dataEnd = nameEnd + entry.size
            guard nameEnd <= Int(centralOffset), dataEnd <= Int(centralOffset),
                String(data: archive[nameStart..<nameEnd], encoding: .utf8) == entry.path
            else { throw GoalongProofArchiveError.malformedZIP }
            let range = offset..<dataEnd
            guard !ranges.contains(where: { $0.overlaps(range) }) else {
                throw GoalongProofArchiveError.malformedZIP
            }
            ranges.append(range)
            let data = Data(archive[nameEnd..<dataEnd])
            guard CRC32.hash(data) == entry.crc else {
                throw GoalongProofArchiveError.checksumMismatch(entry.path)
            }
            output[entry.path] = data
        }
        let orderedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var expectedOffset = 0
        for range in orderedRanges {
            guard range.lowerBound == expectedOffset else {
                throw GoalongProofArchiveError.malformedZIP
            }
            expectedOffset = range.upperBound
        }
        guard expectedOffset == Int(centralOffset) else {
            throw GoalongProofArchiveError.malformedZIP
        }
        return output
    }

    private static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty,
            path.utf8.count <= 256,
            !path.hasPrefix("/"),
            !path.contains("\\"),
            !path.contains("\0")
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private enum CRC32 {
        private static let table: [UInt32] = (0..<256).map { value in
            var crc = UInt32(value)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
            }
            return crc
        }

        static func hash(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return crc ^ 0xFFFF_FFFF
        }
    }
}

public enum GoalongProofPackageVerifier {
    private static let versionOneEntries: Set<String> = [
        "definition.jws", "context-manifest.json", "provider-request.json",
        "provider-response.json", "result.json", "device-public-key.x963", "run.jws",
    ]

    public static func verify(archive: Data) throws -> AnalysisProofVerificationReport {
        let entries = try GoalongProofArchive.extract(archive)
        guard let manifestData = entries["manifest.json"] else {
            throw GoalongProofArchiveError.manifestMismatch
        }
        let manifest = try GoalongCanonicalJSONValue.parse(
            manifestData, maximumBytes: 128 * 1_024
        )
        guard try manifest.encoded(maximumBytes: 128 * 1_024) == manifestData,
            let listed = manifestFiles(manifest),
            Set(listed.keys) == versionOneEntries,
            Set(entries.keys) == Set(listed.keys).union(["manifest.json"])
        else { throw GoalongProofArchiveError.manifestMismatch }

        var issues: [String] = []
        var hashesValid = true
        for (path, descriptor) in listed {
            guard let data = entries[path],
                data.count == descriptor.byteCount,
                GoalongProofDigest.sha256(data) == descriptor.sha256
            else {
                hashesValid = false
                issues.append("artifact_hash_mismatch:\(path)")
                continue
            }
        }
        guard let publicKey = entries["device-public-key.x963"],
            let runData = entries["run.jws"],
            let definitionData = entries["definition.jws"],
            let contextData = entries["context-manifest.json"]
        else { throw GoalongProofArchiveError.manifestMismatch }
        let run = GoalongES256JWS.verify(
            String(decoding: runData, as: UTF8.self),
            expectedType: AnalysisRunProof.jwsType,
            publicKeyX963: publicKey
        )
        let definition = GoalongES256JWS.verify(
            String(decoding: definitionData, as: UTF8.self),
            expectedType: AnalysisDefinitionRevision.jwsType,
            publicKeyX963: publicKey
        )
        let contextValid = try validateContextManifest(contextData)
        if !run.valid { issues.append("run_jws:\(run.issue ?? "invalid")") }
        if !definition.valid { issues.append("definition_jws:\(definition.issue ?? "invalid")") }
        if !contextValid { issues.append("context_manifest_invalid") }

        let bindingIssues: [String]
        if run.valid, definition.valid, contextValid,
            let runPayload = run.payload,
            let definitionPayload = definition.payload,
            let runKeyID = run.keyID,
            let definitionKeyID = definition.keyID
        {
            bindingIssues = try validateSignedBindings(
                entries: entries,
                runPayload: runPayload,
                definitionPayload: definitionPayload,
                runKeyID: runKeyID,
                definitionKeyID: definitionKeyID
            )
        } else {
            bindingIssues = ["signed_artifact_bindings_unavailable"]
        }
        issues.append(contentsOf: bindingIssues)
        let bindingsValid = bindingIssues.isEmpty

        let runStates = run.payload.flatMap(statusesFromRunPayload)
        return AnalysisProofVerificationReport(
            isLocallyValid: hashesValid && run.valid && definition.valid && contextValid && bindingsValid,
            runSignature: run.valid ? "valid" : "invalid",
            definitionSignature: definition.valid ? "valid" : "invalid",
            artifactHashes: hashesValid && bindingsValid ? "valid_and_signed_bindings_match" : "invalid",
            contextManifest: contextValid ? "valid" : "invalid",
            sourceCommitments: contextValid ? "valid" : "invalid",
            chainContinuity: runStates?.previous == nil ? "new_chain" : "signed_previous_digest_present",
            activityAnchors: runStates?.anchors ?? "not_present",
            providerObservation: runStates?.provider ?? "unknown",
            externalReceipt: runStates?.external ?? "not_present",
            appAttest: runStates?.appAttest ?? "not_present",
            privacyMode: runStates?.privacy ?? "unknown",
            issues: issues,
            limitation:
                "This standalone package proves its local Goalong signatures and internal hashes. Provider authorship, external anchoring and App Attest are independent checks and are reported as absent unless their signed artifacts are embedded."
        )
    }

    private static func validateSignedBindings(
        entries: [String: Data],
        runPayload: Data,
        definitionPayload: Data,
        runKeyID: String,
        definitionKeyID: String
    ) throws -> [String] {
        guard let publicKey = entries["device-public-key.x963"],
            case .object(let run) = try GoalongCanonicalJSONValue.parse(
                runPayload, maximumBytes: AnalysisRunProof.maximumCanonicalBytes
            ),
            case .object(let definition) = try GoalongCanonicalJSONValue.parse(
                definitionPayload, maximumBytes: 64 * 1_024
            ),
            case .object(let context) = try GoalongCanonicalJSONValue.parse(
                entries["context-manifest.json"] ?? Data(), maximumBytes: 4 * 1_024 * 1_024
            ),
            case .object(let request) = try GoalongCanonicalJSONValue.parse(
                entries["provider-request.json"] ?? Data(), maximumBytes: 64 * 1_024
            ),
            case .object(let response) = try GoalongCanonicalJSONValue.parse(
                entries["provider-response.json"] ?? Data(), maximumBytes: 64 * 1_024
            )
        else { return ["signed_artifact_bindings_malformed"] }

        let runKeys: Set<String> = [
            "app_attest_status", "build_trust", "context_manifest", "day",
            "definition_jws", "execution_id", "external_receipt_status",
            "first_activity_anchor", "generated_at", "helper_identity", "key_id",
            "last_activity_anchor", "nonce", "period_end", "period_start",
            "previous_attestation_digest", "provider_observation", "provider_request",
            "provider_response", "retention_mode", "retry_id", "schema_version",
            "sequence", "signer_device_id", "slot", "software_build", "software_version",
            "source_root", "terminal_status", "trigger",
        ]
        let definitionKeys: Set<String> = [
            "context_policy", "created_at", "definition_id", "model", "output_schema",
            "privacy_mode", "prompt_template", "provider", "reasoning_effort", "revision",
            "schema_version",
        ]
        let requestKeys: Set<String> = [
            "context_manifest", "execution_id", "model", "network_access", "output_schema",
            "permission_profile", "prompt", "provider", "reasoning_effort", "retention_mode",
            "schema_version", "tool_access",
        ]
        let responseKeys: Set<String> = [
            "execution_id", "observed_at", "parsed_result", "provider", "raw_response",
            "schema_version", "status", "thread_id", "turn_id",
        ]
        let contextKeys: Set<String> = [
            "context_digest", "coverage_status", "day", "execution_id", "generated_at",
            "rendered_context_bytes", "schema_version", "source_counts_digest", "source_root",
            "source_salt", "sources",
        ]

        var issues: [String] = []
        if Set(run.keys) != runKeys { issues.append("run_schema_unknown_or_missing_fields") }
        if Set(definition.keys) != definitionKeys { issues.append("definition_schema_unknown_or_missing_fields") }
        if Set(request.keys) != requestKeys { issues.append("request_schema_unknown_or_missing_fields") }
        if Set(response.keys) != responseKeys { issues.append("response_schema_unknown_or_missing_fields") }
        if Set(context.keys) != contextKeys { issues.append("context_schema_unknown_or_missing_fields") }
        if run["schema_version"] != .integer(1)
            || definition["schema_version"] != .integer(1)
            || request["schema_version"] != .integer(1)
            || response["schema_version"] != .integer(1)
            || context["schema_version"] != .integer(1)
        {
            issues.append("unsupported_signed_schema")
        }

        for (field, path) in [
            ("definition_jws", "definition.jws"),
            ("context_manifest", "context-manifest.json"),
            ("provider_request", "provider-request.json"),
            ("provider_response", "provider-response.json"),
        ] where !descriptor(run[field], matches: entries[path]) {
            issues.append("run_descriptor_mismatch:\(path)")
        }
        if !descriptor(request["context_manifest"], matches: entries["context-manifest.json"]) {
            issues.append("request_context_descriptor_mismatch")
        }
        if !descriptor(response["parsed_result"], matches: entries["result.json"]) {
            issues.append("response_result_descriptor_mismatch")
        }

        let executionIDs = [run, context, request, response].compactMap { object -> String? in
            guard case .string(let value)? = object["execution_id"] else { return nil }
            return value
        }
        if executionIDs.count != 4 || Set(executionIDs).count != 1
            || UUID(uuidString: executionIDs.first ?? "") == nil
        {
            issues.append("execution_id_binding_mismatch")
        }
        if run["day"] != context["day"] { issues.append("day_binding_mismatch") }
        if run["source_root"] != context["source_root"] { issues.append("source_root_binding_mismatch") }
        if request["provider"] != response["provider"] { issues.append("provider_binding_mismatch") }

        let computedKeyID = GoalongES256JWS.keyID(publicKeyX963: publicKey)
        if computedKeyID == nil || runKeyID != computedKeyID || definitionKeyID != computedKeyID
            || run["key_id"] != computedKeyID.map(GoalongCanonicalJSONValue.string)
        {
            issues.append("signing_key_binding_mismatch")
        }
        if run["signer_device_id"] != .string(GoalongProofDigest.sha256(publicKey)) {
            issues.append("signer_device_binding_mismatch")
        }
        return issues
    }

    private static func descriptor(
        _ value: GoalongCanonicalJSONValue?,
        matches data: Data?
    ) -> Bool {
        guard let data,
            case .object(let descriptor)? = value,
            Set(descriptor.keys) == ["byte_count", "media_type", "sha256"],
            case .integer(let byteCount)? = descriptor["byte_count"],
            case .string(let mediaType)? = descriptor["media_type"],
            case .string(let digest)? = descriptor["sha256"]
        else { return false }
        return byteCount == Int64(data.count)
            && !mediaType.isEmpty
            && digest == GoalongProofDigest.sha256(data)
    }

    private struct ManifestDescriptor {
        let byteCount: Int
        let sha256: String
    }

    private static func manifestFiles(
        _ value: GoalongCanonicalJSONValue
    ) -> [String: ManifestDescriptor]? {
        guard case .object(let root) = value,
            root["format"] == .string("goalong-proof-directory-v1"),
            root["schema_version"] == .integer(1),
            case .array(let files)? = root["files"]
        else { return nil }
        var output: [String: ManifestDescriptor] = [:]
        for value in files {
            guard case .object(let row) = value,
                case .string(let path)? = row["path"],
                case .string(let digest)? = row["sha256"],
                case .integer(let byteCount)? = row["byte_count"],
                byteCount >= 0, byteCount <= Int64(GoalongProofArchive.maximumEntryBytes),
                GoalongProofDigest.isValid(digest), output[path] == nil
            else { return nil }
            output[path] = ManifestDescriptor(byteCount: Int(byteCount), sha256: digest)
        }
        return output
    }

    private static func validateContextManifest(_ data: Data) throws -> Bool {
        let value = try GoalongCanonicalJSONValue.parse(data, maximumBytes: 4 * 1_024 * 1_024)
        guard try value.encoded(maximumBytes: 4 * 1_024 * 1_024) == data,
            case .object(let root) = value,
            root["schema_version"] == .integer(1),
            case .string(let saltText)? = root["source_salt"],
            let salt = GoalongBase64URL.decode(saltText), salt.count == 32,
            case .string(let expectedRoot)? = root["source_root"],
            case .array(let sources)? = root["sources"],
            sources.count <= AnalysisContextManifest.maximumSources
        else { return false }
        var commitments: [(String, Data)] = []
        var seen: Set<String> = []
        for source in sources {
            guard case .object(let object) = source,
                case .string(let sourceID)? = object["source_id"],
                seen.insert(sourceID).inserted
            else { return false }
            var material = Data("GOALONG-CONTEXT-SOURCE-V1\0".utf8)
            material.append(salt)
            material.append(try source.encoded(maximumBytes: 16 * 1_024))
            commitments.append((sourceID, SHA256Digest.hash(material)))
        }
        return merkleRoot(commitments) == expectedRoot
    }

    private static func merkleRoot(_ commitments: [(String, Data)]) -> String {
        if commitments.isEmpty {
            return GoalongProofDigest.sha256(Data("GOALONG-EMPTY-SOURCE-ROOT-V1".utf8))
        }
        var level = commitments.sorted { $0.0 < $1.0 }.map { _, commitment -> Data in
            var leaf = Data([0])
            leaf.append(commitment)
            return SHA256Digest.hash(leaf)
        }
        while level.count > 1 {
            var next: [Data] = []
            for index in stride(from: 0, to: level.count, by: 2) {
                var node = Data([1])
                node.append(level[index])
                node.append(index + 1 < level.count ? level[index + 1] : level[index])
                next.append(SHA256Digest.hash(node))
            }
            level = next
        }
        return "sha256:\(GoalongBase64URL.encode(level[0]))"
    }

    private struct RunStatuses {
        let previous: String?
        let anchors: String
        let provider: String
        let external: String
        let appAttest: String
        let privacy: String
    }

    private static func statusesFromRunPayload(_ data: Data) -> RunStatuses? {
        guard let value = try? GoalongCanonicalJSONValue.parse(data),
            case .object(let object) = value,
            case .string(let provider)? = object["provider_observation"],
            case .string(let external)? = object["external_receipt_status"],
            case .string(let appAttest)? = object["app_attest_status"],
            case .string(let privacy)? = object["retention_mode"]
        else { return nil }
        let previous: String?
        if case .string(let value)? = object["previous_attestation_digest"] {
            previous = value
        } else {
            previous = nil
        }
        let firstPresent: Bool
        if case .string = object["first_activity_anchor"] { firstPresent = true } else { firstPresent = false }
        let lastPresent: Bool
        if case .string = object["last_activity_anchor"] { lastPresent = true } else { lastPresent = false }
        return RunStatuses(
            previous: previous,
            anchors: firstPresent && lastPresent ? "linked_hashes_present" : "not_present",
            provider: provider,
            external: external,
            appAttest: appAttest,
            privacy: privacy
        )
    }
}
