#if os(macOS)
    import AgentActivity
    import AppleScreenTime
    import Foundation
    import LocalHistoryCore
    import Security

    struct AnalysisProofCreationResult {
        let reference: AnalysisProofReference
        let report: AnalysisProofVerificationReport
    }

    enum AnalysisProofStoreError: Error, LocalizedError {
        case invalidIdentity
        case invalidManifest
        case invalidProof
        case tooManySources
        case randomFailure(OSStatus)
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "The local analysis signing identity is invalid."
            case .invalidManifest: return "The analysis context manifest is invalid."
            case .invalidProof: return "The generated analysis proof failed local verification."
            case .tooManySources: return "The selected day contains too many source references for one bounded proof manifest."
            case .randomFailure(let status): return "Secure random generation failed (OSStatus \(status))."
            case .destinationExists: return "An analysis proof already exists for this execution identifier."
            }
        }
    }

    final class AnalysisProofStore {
        private struct ChainHead: Codable {
            let schemaVersion: Int
            let sequence: Int64
            let executionID: String
            let runJWSSHA256: String
        }

        private let rootDirectory: URL
        private let evidenceStore: AnalysisEvidenceCapsuleStore
        private let fileManager: FileManager
        private let shareBuilder: SharePackageBuilder

        init(
            rootDirectory: URL,
            fileManager: FileManager = .default,
            shareBuilder: SharePackageBuilder = SharePackageBuilder()
        ) {
            self.rootDirectory = rootDirectory
            self.fileManager = fileManager
            self.shareBuilder = shareBuilder
            evidenceStore = AnalysisEvidenceCapsuleStore(
                directory: rootDirectory.appendingPathComponent("private-evidence", isDirectory: true)
            )
        }

        func create(
            runID: UUID,
            day: Date,
            generatedAt: Date,
            trigger: String,
            prompt: String,
            context: ChatGPTRecapContext,
            assessment: ChatGPTDailyAssessment,
            recap: ChatGPTDailyRecap,
            identity: AnalysisRunSigningIdentity
        ) throws -> AnalysisProofCreationResult {
            try ChatGPTSecureStorage.prepareDirectory(rootDirectory)
            recoverInterruptedRuns(now: generatedAt)
            _ = evidenceStore.purgeExpired(now: generatedAt)

            guard let publicKeyX963 = Data(base64Encoded: identity.info.publicKeyBase64),
                publicKeyX963.count == 65,
                let keyID = GoalongES256JWS.keyID(publicKeyX963: publicKeyX963)
            else { throw AnalysisProofStoreError.invalidIdentity }

            let executionID = runID.uuidString.lowercased()
            let finalDirectory = rootDirectory.appendingPathComponent(executionID, isDirectory: true)
            guard !fileManager.fileExists(atPath: finalDirectory.path) else {
                throw AnalysisProofStoreError.destinationExists
            }
            let generatedAtString = AnalysisProofTimestamp.string(from: generatedAt)
            let dayString = AppPaths.localDayString(for: day)
            let contextData = Data(context.renderedData.utf8)
            let promptData = Data(prompt.utf8)
            let sourceCountsData = try canonicalSourceCounts(recap.sourceCounts)
            let resultData = try canonicalResult(recap)
            let rawResponseData = Data((assessment.rawResponse ?? String(decoding: resultData, as: UTF8.self)).utf8)

            let promptTemplate = prompt.replacingOccurrences(
                of: context.renderedData,
                with: "{{goalong_context_direct_read_hash_only}}"
            )
            guard promptTemplate != prompt else { throw AnalysisProofStoreError.invalidManifest }
            let contextPolicy = Data(Self.contextPolicyDescription.utf8)
            let outputSchema = try JSONSerialization.data(
                withJSONObject: CodexDailyAssessmentContract.outputSchema,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let definition = AnalysisDefinitionRevision(
                definitionID: CodexDailyAssessmentContract.definitionID,
                revision: CodexDailyAssessmentContract.definitionRevision,
                createdAt: "2026-08-31T00:00:00.000Z",
                provider: recap.provider,
                model: recap.model ?? CodexDailyAssessmentContract.model,
                reasoningEffort: recap.reasoningEffort ?? CodexDailyAssessmentContract.reasoningEffort,
                promptTemplate: AnalysisArtifactDescriptor(
                    data: Data(promptTemplate.utf8),
                    mediaType: "text/plain; charset=utf-8"
                ),
                contextPolicy: AnalysisArtifactDescriptor(
                    data: contextPolicy,
                    mediaType: "text/plain; charset=utf-8"
                ),
                outputSchema: AnalysisArtifactDescriptor(
                    data: outputSchema,
                    mediaType: "application/schema+json"
                )
            )
            guard definition.isValid else { throw AnalysisProofStoreError.invalidManifest }
            let definitionJWS = try GoalongES256JWS.compact(
                canonicalPayload: definition.canonicalData(),
                type: AnalysisDefinitionRevision.jwsType,
                publicKeyX963: publicKeyX963,
                signDER: identity.sign
            )
            let definitionJWSData = Data(definitionJWS.utf8)

            let salt = try secureRandom(count: 32)
            let sources = try contextSources(
                context: context,
                dayString: dayString,
                contextData: contextData,
                salt: salt
            )
            guard sources.count <= AnalysisContextManifest.maximumSources else {
                throw AnalysisProofStoreError.tooManySources
            }
            let sourceRoot = try AnalysisSourceMerkleTree.root(sources: sources, salt: salt)
            let manifest = AnalysisContextManifest(
                executionID: executionID,
                day: dayString,
                generatedAt: generatedAtString,
                sourceSaltBase64URL: GoalongBase64URL.encode(salt),
                sourceRoot: sourceRoot,
                contextDigest: GoalongProofDigest.sha256(contextData),
                sourceCountsDigest: GoalongProofDigest.sha256(sourceCountsData),
                renderedContextBytes: contextData.count,
                coverageStatus: coverageStatus(context: context),
                sources: sources
            )
            guard manifest.isValid else { throw AnalysisProofStoreError.invalidManifest }
            let contextManifestData = try manifest.canonicalData()

            let request = ProviderRequestArtifact(
                executionID: executionID,
                provider: recap.provider,
                model: recap.model ?? CodexDailyAssessmentContract.model,
                reasoningEffort: recap.reasoningEffort ?? CodexDailyAssessmentContract.reasoningEffort,
                prompt: AnalysisArtifactDescriptor(
                    data: promptData,
                    mediaType: "text/plain; charset=utf-8"
                ),
                outputSchema: AnalysisArtifactDescriptor(
                    data: outputSchema,
                    mediaType: "application/schema+json"
                ),
                contextManifest: AnalysisArtifactDescriptor(
                    data: contextManifestData,
                    mediaType: "application/vnd.goalong.context-manifest+json"
                ),
                permissionProfile: "goalong_daily_recap_restricted",
                networkAccess: "disabled_by_goalong_permission_profile",
                toolAccess: "disabled_by_goalong_permission_profile"
            )
            let requestData = try request.canonicalData()

            var capsuleURL: URL?
            do {
                capsuleURL = try evidenceStore.storeGeneratedResponse(
                    rawResponseData,
                    executionID: executionID,
                    createdAt: generatedAt
                )
                let response = ProviderResponseArtifact(
                    executionID: executionID,
                    provider: recap.provider,
                    threadID: assessment.threadID,
                    turnID: assessment.turnID,
                    observedAt: generatedAtString,
                    rawResponse: AnalysisArtifactDescriptor(
                        data: rawResponseData,
                        mediaType: "application/json"
                    ),
                    parsedResult: AnalysisArtifactDescriptor(
                        data: resultData,
                        mediaType: "application/vnd.goalong.daily-result+json"
                    ),
                    status: assessment.rawResponse == nil
                        ? "validated_result_without_raw_transport_bytes"
                        : "exact_final_assistant_bytes_encrypted_locally"
                )
                let responseData = try response.canonicalData()

                let chainHead = loadChainHead()
                let sequence = (chainHead?.sequence ?? -1) + 1
                let nonce = try secureRandom(count: 32)
                let anchors = try? shareBuilder.anchorBounds(for: day)
                let build = BuildIdentityReader.current()
                let deviceDigest = GoalongProofDigest.sha256(publicKeyX963)
                let period = try dayPeriod(day)
                let run = AnalysisRunProof(
                    executionID: executionID,
                    nonceBase64URL: GoalongBase64URL.encode(nonce),
                    sequence: sequence,
                    previousAttestationDigest: chainHead?.runJWSSHA256,
                    slot: "daily:\(dayString)",
                    retryID: nil,
                    day: dayString,
                    periodStart: AnalysisProofTimestamp.string(from: period.start),
                    periodEnd: AnalysisProofTimestamp.string(from: period.end),
                    generatedAt: generatedAtString,
                    trigger: trigger,
                    definitionJWS: AnalysisArtifactDescriptor(
                        data: definitionJWSData,
                        mediaType: "application/jose"
                    ),
                    contextManifest: AnalysisArtifactDescriptor(
                        data: contextManifestData,
                        mediaType: "application/vnd.goalong.context-manifest+json"
                    ),
                    providerRequest: AnalysisArtifactDescriptor(
                        data: requestData,
                        mediaType: "application/vnd.goalong.provider-request+json"
                    ),
                    providerResponse: AnalysisArtifactDescriptor(
                        data: responseData,
                        mediaType: "application/vnd.goalong.provider-response+json"
                    ),
                    sourceRoot: sourceRoot,
                    firstActivityAnchor: anchors.flatMap { proofDigest(hex: $0.firstAnchorHash) },
                    lastActivityAnchor: anchors.flatMap { proofDigest(hex: $0.lastAnchorHash) },
                    providerObservation: assessment.rawResponse == nil
                        ? "validated_parsed_result_only"
                        : "local_codex_app_server_final_stream_observed",
                    helperIdentity: "codex_app_server_restricted_ephemeral_thread",
                    signerDeviceID: deviceDigest,
                    keyID: keyID,
                    retentionMode: "hash_only_no_transcript_copy",
                    softwareVersion: build.displayVersion ?? "dev",
                    softwareBuild: build.buildNumber ?? "dev",
                    buildTrust: build.signatureKind.rawValue,
                    externalReceiptStatus: "not_present",
                    appAttestStatus: build.signatureKind == .appStore
                        ? "not_requested_for_analysis_run"
                        : "local_build_not_eligible",
                    terminalStatus: "completed"
                )
                guard run.isValid else { throw AnalysisProofStoreError.invalidProof }
                let runJWS = try GoalongES256JWS.compact(
                    canonicalPayload: run.canonicalData(),
                    type: AnalysisRunProof.jwsType,
                    publicKeyX963: publicKeyX963,
                    signDER: identity.sign
                )
                let runJWSData = Data(runJWS.utf8)

                let staging = rootDirectory.appendingPathComponent(
                    ".\(executionID).tmp", isDirectory: true
                )
                if fileManager.fileExists(atPath: staging.path) {
                    try? fileManager.removeItem(at: staging)
                }
                try ChatGPTSecureStorage.prepareDirectory(staging)
                let files: [(String, Data)] = [
                    ("definition.jws", definitionJWSData),
                    ("context-manifest.json", contextManifestData),
                    ("provider-request.json", requestData),
                    ("provider-response.json", responseData),
                    ("result.json", resultData),
                    ("device-public-key.x963", publicKeyX963),
                    ("run.jws", runJWSData),
                ]
                for (name, data) in files {
                    try ChatGPTSecureStorage.writeFileAtomically(
                        data,
                        to: staging.appendingPathComponent(name, isDirectory: false)
                    )
                }
                let packageManifestData = try packageManifest(files: files)
                try ChatGPTSecureStorage.writeFileAtomically(
                    packageManifestData,
                    to: staging.appendingPathComponent("manifest.json", isDirectory: false)
                )
                try fileManager.moveItem(at: staging, to: finalDirectory)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: finalDirectory.path
                )

                let runDigest = GoalongProofDigest.sha256(runJWSData)
                let newHead = ChainHead(
                    schemaVersion: 1,
                    sequence: sequence,
                    executionID: executionID,
                    runJWSSHA256: runDigest
                )
                try writeChainHead(newHead)
                let reference = AnalysisProofReference(
                    executionID: executionID,
                    proofDirectoryName: executionID,
                    runJWSSHA256: runDigest,
                    localSignatureStatus: "valid",
                    providerObservationStatus: assessment.rawResponse == nil
                        ? "parsed_result_only"
                        : "local_stream_observed",
                    contextStatus: "manifest_and_source_commitments_valid",
                    activityAnchorStatus: anchors == nil ? "not_present" : "linked",
                    externalReceiptStatus: "not_present",
                    appAttestStatus: run.appAttestStatus,
                    retentionMode: "hash_only_no_transcript_copy"
                )
                let report = try verify(reference: reference)
                guard report.isLocallyValid else { throw AnalysisProofStoreError.invalidProof }
                return AnalysisProofCreationResult(reference: reference, report: report)
            } catch {
                if capsuleURL != nil { try? evidenceStore.destroy(executionID: executionID) }
                throw error
            }
        }

        func verify(reference: AnalysisProofReference) throws -> AnalysisProofVerificationReport {
            guard UUID(uuidString: reference.executionID) != nil,
                reference.executionID == reference.proofDirectoryName
            else { throw AnalysisProofStoreError.invalidProof }
            let directory = rootDirectory.appendingPathComponent(
                reference.proofDirectoryName, isDirectory: true
            )
            let manifestData = try stableFile(
                directory.appendingPathComponent("manifest.json"), maximumBytes: 128 * 1_024
            )
            let manifestValue = try GoalongCanonicalJSONValue.parse(
                manifestData, maximumBytes: 128 * 1_024
            )
            guard try manifestValue.encoded(maximumBytes: 128 * 1_024) == manifestData,
                let listed = packageFiles(from: manifestValue)
            else { throw AnalysisProofStoreError.invalidProof }

            var loaded: [String: Data] = [:]
            for entry in listed {
                let data = try stableFile(
                    directory.appendingPathComponent(entry.path),
                    maximumBytes: 4 * 1_024 * 1_024
                )
                loaded[entry.path] = data
            }
            loaded["manifest.json"] = manifestData
            let archive = try GoalongProofArchive.create(entries: loaded)
            let packageReport = try GoalongProofPackageVerifier.verify(archive: archive)
            let referenceMatches = GoalongProofDigest.sha256(loaded["run.jws"] ?? Data())
                == reference.runJWSSHA256
            var issues = packageReport.issues
            if !referenceMatches { issues.append("run_reference_mismatch") }
            return AnalysisProofVerificationReport(
                isLocallyValid: packageReport.isLocallyValid && referenceMatches,
                runSignature: packageReport.runSignature,
                definitionSignature: packageReport.definitionSignature,
                artifactHashes: packageReport.artifactHashes,
                contextManifest: packageReport.contextManifest,
                sourceCommitments: packageReport.sourceCommitments,
                chainContinuity: reference.runJWSSHA256 == loadChainHead()?.runJWSSHA256
                    ? "current_local_head"
                    : "signed_link_only",
                activityAnchors: packageReport.activityAnchors,
                providerObservation: packageReport.providerObservation,
                externalReceipt: packageReport.externalReceipt,
                appAttest: packageReport.appAttest,
                privacyMode: packageReport.privacyMode,
                issues: issues,
                limitation: packageReport.limitation
            )
        }

        func export(
            reference: AnalysisProofReference,
            to destination: URL
        ) throws -> AnalysisProofVerificationReport {
            guard destination.pathExtension == "goalong-proof",
                UUID(uuidString: reference.executionID) != nil,
                reference.proofDirectoryName == reference.executionID
            else { throw AnalysisProofStoreError.invalidProof }
            let directory = rootDirectory.appendingPathComponent(
                reference.proofDirectoryName, isDirectory: true
            )
            let names = [
                "manifest.json", "definition.jws", "context-manifest.json",
                "provider-request.json", "provider-response.json", "result.json",
                "device-public-key.x963", "run.jws",
            ]
            var entries: [String: Data] = [:]
            for name in names {
                entries[name] = try stableFile(
                    directory.appendingPathComponent(name, isDirectory: false),
                    maximumBytes: 4 * 1_024 * 1_024
                )
            }
            let archive = try GoalongProofArchive.create(entries: entries)
            let report = try GoalongProofPackageVerifier.verify(archive: archive)
            guard report.isLocallyValid else { throw AnalysisProofStoreError.invalidProof }
            try archive.write(to: destination, options: [.atomic])
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path
            )
            let persisted = try ChatGPTHistoryStore.readStableSource(
                at: destination,
                maximumBytes: Int64(GoalongProofArchive.maximumArchiveBytes)
            )
            let persistedReport = try GoalongProofPackageVerifier.verify(archive: persisted)
            guard persistedReport.isLocallyValid else { throw AnalysisProofStoreError.invalidProof }
            return persistedReport
        }

        private static let contextPolicyDescription = """
            Goalong daily analysis context policy v1.
            Computer History is read from the selected day journal and compact projections.
            Screen Time is read from the selected Apple data projection.
            Agent conversations are read directly from original provider storage and include only user-visible user prompts and final assistant answers.
            System/developer prompts, hidden reasoning, tool traffic, progress commentary and compaction payloads are excluded.
            The complete prompt and transcript bodies are never retained by Goalong; only hashes, source references, counts and bounded offsets are persisted.
            """

        private func contextSources(
            context: ChatGPTRecapContext,
            dayString: String,
            contextData: Data,
            salt _: Data
        ) throws -> [AnalysisContextSource] {
            var sources: [AnalysisContextSource] = []
            let eventURL = AppPaths.eventFileURL(for: context.day)
            let eventAttributes = try? fileManager.attributesOfItem(atPath: eventURL.path)
            let eventSize = (eventAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            let eventModified = (eventAttributes?[.modificationDate] as? Date)
                .map(AnalysisProofTimestamp.string)
            let anchors = try? shareBuilder.anchorBounds(for: context.day)
            sources.append(
                AnalysisContextSource(
                    sourceID: "computer-history:\(dayString)",
                    provider: "goalong_computer_history",
                    stableID: dayString,
                    sourceReference: "goalong://computer-history/events/\(dayString)",
                    sourceKind: "append_only_jsonl",
                    availability: fileManager.fileExists(atPath: eventURL.path) ? "available" : "missing",
                    byteCount: eventSize,
                    fingerprint: anchors.flatMap { proofDigest(hex: $0.lastAnchorHash) },
                    modifiedAt: eventModified,
                    startOffset: 0,
                    endOffset: eventSize,
                    selectionDigest: GoalongProofDigest.sha256(
                        Data("selected_day=\(dayString);projection=computer_history_v1".utf8)
                    ),
                    includedMaterialDigest: GoalongProofDigest.sha256(contextData),
                    coverage: context.localJournalSourceAbsent ? "source_absent" : "selected_day_complete_or_gaps_declared"
                )
            )

            if let screenTime = context.screenTime {
                let screenData = (try? AppleScreenTimeJSON.encode(screenTime, prettyPrinted: false)) ?? Data()
                sources.append(
                    AnalysisContextSource(
                        sourceID: "screen-time:\(dayString)",
                        provider: "apple_screen_time",
                        stableID: dayString,
                        sourceReference: "goalong://apple-screen-time/selected-scope/\(dayString)",
                        sourceKind: "apple_screen_time_projection",
                        availability: "available",
                        byteCount: Int64(screenData.count),
                        fingerprint: GoalongProofDigest.sha256(screenData),
                        modifiedAt: nil,
                        startOffset: nil,
                        endOffset: nil,
                        selectionDigest: GoalongProofDigest.sha256(
                            Data("selected_day=\(dayString);scope=stored_configuration".utf8)
                        ),
                        includedMaterialDigest: GoalongProofDigest.sha256(screenData),
                        coverage: "apple_reported_projection"
                    )
                )
            }

            let captures = context.agentActivity.captures.sorted { $0.id < $1.id }
            guard captures.count + sources.count <= AnalysisContextManifest.maximumSources else {
                throw AnalysisProofStoreError.tooManySources
            }
            for capture in captures {
                let summaryDigest = digest(capture.summary)
                let opaqueReference = GoalongProofDigest.sha256(
                    Data(capture.index.reference.path.utf8)
                )
                sources.append(
                    AnalysisContextSource(
                        sourceID: capture.id,
                        provider: capture.provider.rawValue,
                        stableID: capture.index.stableConversationID,
                        sourceReference:
                            "goalong://agent-source/\(capture.provider.rawValue)/\(opaqueReference)",
                        sourceKind: capture.index.reference.kind.rawValue,
                        availability: capture.availability.rawValue,
                        byteCount: capture.byteCount,
                        fingerprint: proofDigest(hex: capture.sha256),
                        modifiedAt: capture.sourceModifiedAt.map(AnalysisProofTimestamp.string),
                        startOffset: capture.index.startOffset,
                        endOffset: capture.index.endOffset,
                        selectionDigest: GoalongProofDigest.sha256(
                            Data("selected_day=\(dayString);visible_user_and_assistant_final_only".utf8)
                        ),
                        includedMaterialDigest: summaryDigest,
                        coverage: capture.projectionIsComplete
                            ? (capture.isAnalyzed ? "complete_direct_read" : "metadata_only")
                            : "bounded_projection_incomplete"
                    )
                )
            }
            return sources
        }

        private func digest(_ summary: AgentDocumentSummary) -> String {
            var data = Data("GOALONG-TRANSIENT-AGENT-SUMMARY-V1\0".utf8)
            append(summary.format.rawValue, to: &data)
            append(summary.sessionID ?? "", to: &data)
            append(summary.title ?? "", to: &data)
            append(summary.projectPath ?? "", to: &data)
            for count in [
                summary.messageCount, summary.userMessageCount, summary.assistantMessageCount,
                summary.toolCallCount, summary.errorCount, summary.subagentCount,
            ] {
                append(Int64(count), to: &data)
            }
            for message in summary.visibleMessages {
                append(message.role.rawValue, to: &data)
                append(message.text, to: &data)
            }
            return GoalongProofDigest.sha256(data)
        }

        private func coverageStatus(context: ChatGPTRecapContext) -> String {
            if context.localJournalSourceAbsent { return "partial_local_journal_absent" }
            if context.agentActivity.captures.contains(where: { !$0.projectionIsComplete }) {
                return "partial_agent_projection_declared"
            }
            if context.agentActivity.captures.contains(where: { $0.availability != .available }) {
                return "partial_agent_source_unavailable_declared"
            }
            return "complete_with_declared_private_and_suppressed_gaps"
        }

        private func canonicalSourceCounts(_ counts: ChatGPTRecapSourceCounts) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(counts)
        }

        private func canonicalResult(_ recap: ChatGPTDailyRecap) throws -> Data {
            guard let productivity = recap.productivityScore,
                let confidence = recap.confidenceScore,
                let lines = recap.summaryLines
            else { throw AnalysisProofStoreError.invalidProof }
            return try GoalongCanonicalJSONValue.object([
                "confidence_score": .integer(Int64(confidence)),
                "markdown": .string(recap.markdown),
                "productivity_score": .integer(Int64(productivity)),
                "summary_lines": .array(lines.map(GoalongCanonicalJSONValue.string)),
            ]).encoded(maximumBytes: 16 * 1_024)
        }

        private func dayPeriod(_ day: Date) throws -> DateInterval {
            guard let interval = Calendar.current.dateInterval(of: .day, for: day) else {
                throw AnalysisProofStoreError.invalidManifest
            }
            return interval
        }

        private func secureRandom(count: Int) throws -> Data {
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw AnalysisProofStoreError.randomFailure(status)
            }
            return data
        }

        private func loadChainHead() -> ChainHead? {
            let url = rootDirectory.appendingPathComponent("chain-head.json", isDirectory: false)
            guard let data = try? ChatGPTHistoryStore.readStableSource(at: url, maximumBytes: 8 * 1_024),
                let head = try? JSONDecoder().decode(ChainHead.self, from: data),
                head.schemaVersion == 1,
                head.sequence >= 0,
                UUID(uuidString: head.executionID) != nil,
                GoalongProofDigest.isValid(head.runJWSSHA256),
                let runData = try? stableFile(
                    rootDirectory.appendingPathComponent(head.executionID, isDirectory: true)
                        .appendingPathComponent("run.jws", isDirectory: false),
                    maximumBytes: 64 * 1_024
                ),
                GoalongProofDigest.sha256(runData) == head.runJWSSHA256
            else { return nil }
            return head
        }

        private func writeChainHead(_ head: ChainHead) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try ChatGPTSecureStorage.writeFileAtomically(
                try encoder.encode(head),
                to: rootDirectory.appendingPathComponent("chain-head.json", isDirectory: false)
            )
        }

        private func recoverInterruptedRuns(now: Date) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: []
            ) else { return }
            let cutoff = now.addingTimeInterval(-86_400)
            for entry in entries where entry.lastPathComponent.hasPrefix(".")
                && entry.lastPathComponent.hasSuffix(".tmp")
            {
                let rawID = String(entry.lastPathComponent.dropFirst().dropLast(4))
                guard UUID(uuidString: rawID) != nil,
                    let values = try? entry.resourceValues(
                        forKeys: [.contentModificationDateKey, .isDirectoryKey]
                    ), values.isDirectory == true,
                    let modified = values.contentModificationDate, modified < cutoff
                else { continue }
                try? fileManager.removeItem(at: entry)
            }
        }

        private func packageManifest(files: [(String, Data)]) throws -> Data {
            let rows = files.sorted { $0.0 < $1.0 }.map { name, data in
                GoalongCanonicalJSONValue.object([
                    "byte_count": .integer(Int64(data.count)),
                    "path": .string(name),
                    "sha256": .string(GoalongProofDigest.sha256(data)),
                ])
            }
            return try GoalongCanonicalJSONValue.object([
                "files": .array(rows),
                "format": .string("goalong-proof-directory-v1"),
                "schema_version": .integer(1),
            ]).encoded(maximumBytes: 128 * 1_024)
        }

        private struct PackageFile {
            let path: String
            let sha256: String
            let byteCount: Int
        }

        private func packageFiles(
            from value: GoalongCanonicalJSONValue
        ) -> [PackageFile]? {
            guard case .object(let root) = value,
                root["format"] == .string("goalong-proof-directory-v1"),
                root["schema_version"] == .integer(1),
                case .array(let rows)? = root["files"],
                rows.count <= 32
            else { return nil }
            var seen: Set<String> = []
            var output: [PackageFile] = []
            for row in rows {
                guard case .object(let object) = row,
                    case .string(let path)? = object["path"],
                    case .string(let digest)? = object["sha256"],
                    case .integer(let byteCount)? = object["byte_count"],
                    byteCount >= 0, byteCount <= 4 * 1_024 * 1_024,
                    isSafeProofPath(path),
                    GoalongProofDigest.isValid(digest),
                    seen.insert(path).inserted
                else { return nil }
                output.append(PackageFile(path: path, sha256: digest, byteCount: Int(byteCount)))
            }
            return output
        }

        private func validateContextManifest(_ data: Data) throws -> Bool {
            let value = try GoalongCanonicalJSONValue.parse(data, maximumBytes: 4 * 1_024 * 1_024)
            guard try value.encoded(maximumBytes: 4 * 1_024 * 1_024) == data,
                case .object(let root) = value,
                root["schema_version"] == .integer(1),
                case .string(let saltString)? = root["source_salt"],
                let salt = GoalongBase64URL.decode(saltString), salt.count == 32,
                case .string(let expectedRoot)? = root["source_root"],
                case .array(let sourceValues)? = root["sources"],
                sourceValues.count <= AnalysisContextManifest.maximumSources
            else { return false }
            var leaves: [(String, Data)] = []
            var seen: Set<String> = []
            for source in sourceValues {
                guard case .object(let object) = source,
                    case .string(let sourceID)? = object["source_id"],
                    seen.insert(sourceID).inserted
                else { return false }
                var material = Data("GOALONG-CONTEXT-SOURCE-V1\0".utf8)
                material.append(salt)
                material.append(try source.encoded(maximumBytes: 16 * 1_024))
                leaves.append((sourceID, SHA256Digest.hash(material)))
            }
            return merkleRoot(leaves: leaves) == expectedRoot
        }

        private func merkleRoot(leaves: [(String, Data)]) -> String {
            if leaves.isEmpty {
                return GoalongProofDigest.sha256(Data("GOALONG-EMPTY-SOURCE-ROOT-V1".utf8))
            }
            var level = leaves.sorted { $0.0 < $1.0 }.map { _, commitment -> Data in
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

        private func stableFile(_ url: URL, maximumBytes: Int64) throws -> Data {
            try ChatGPTHistoryStore.readStableSource(at: url, maximumBytes: maximumBytes)
        }

        private func isSafeProofPath(_ path: String) -> Bool {
            !path.isEmpty
                && path.utf8.count <= 256
                && !path.hasPrefix("/")
                && !path.contains("\\")
                && !path.split(separator: "/").contains("..")
                && !path.contains("\0")
        }

        private func proofDigest(hex: String) -> String? {
            guard hex.utf8.count == 64 else { return nil }
            var data = Data()
            data.reserveCapacity(32)
            var index = hex.startIndex
            for _ in 0..<32 {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
            return "sha256:\(GoalongBase64URL.encode(data))"
        }

        private func append(_ value: String, to data: inout Data) {
            let bytes = Data(value.utf8)
            append(Int64(bytes.count), to: &data)
            data.append(bytes)
        }

        private func append(_ value: Int64, to data: inout Data) {
            var bigEndian = UInt64(max(0, value)).bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
    }
#endif
