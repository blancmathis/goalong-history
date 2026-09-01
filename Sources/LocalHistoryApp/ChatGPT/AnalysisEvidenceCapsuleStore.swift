#if os(macOS)
    import CryptoKit
    import Foundation
    import LocalHistoryCore
    import Security

    enum AnalysisEvidenceCapsuleError: Error, LocalizedError {
        case invalidExecutionID
        case randomFailure(OSStatus)
        case keychainFailure(OSStatus)
        case malformedCapsule
        case integrityFailure

        var errorDescription: String? {
            switch self {
            case .invalidExecutionID: return "The analysis execution identifier is invalid."
            case .randomFailure(let status): return "Secure random generation failed (OSStatus \(status))."
            case .keychainFailure(let status): return "The local evidence key could not be accessed (OSStatus \(status))."
            case .malformedCapsule: return "The local evidence capsule is malformed."
            case .integrityFailure: return "The local evidence capsule failed authenticated decryption."
            }
        }
    }

    /// Stores only the bounded generated response. Source conversations and the
    /// complete context prompt remain hash-only and are never copied here.
    final class AnalysisEvidenceCapsuleStore {
        static let service = "goalong.evidence.v1"
        static let retentionDays = 30
        static let maximumPlaintextBytes = 64 * 1_024
        static let maximumCapsuleOverheadBytes = 8 * 1_024

        private static let magic = Data("GOALONG-EVIDENCE-V1\0".utf8)
        private let directory: URL

        init(directory: URL) {
            self.directory = directory
        }

        func storeGeneratedResponse(
            _ plaintext: Data,
            executionID: String,
            createdAt: Date
        ) throws -> URL {
            guard UUID(uuidString: executionID) != nil else {
                throw AnalysisEvidenceCapsuleError.invalidExecutionID
            }
            guard plaintext.count <= Self.maximumPlaintextBytes else {
                throw CodexAppServerError.protocolLimitExceeded(
                    "generated response exceeded the local evidence capsule limit"
                )
            }
            try ChatGPTSecureStorage.prepareDirectory(directory)
            let keyData = try loadOrCreateKey(executionID: executionID)
            let key = SymmetricKey(data: keyData)
            let digest = GoalongProofDigest.sha256(plaintext)
            let aad = Data(
                "execution_id=\(executionID)\nkind=provider_response\nplaintext=\(digest)\nversion=1\n"
                    .utf8
            )
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
            guard let combined = sealed.combined else {
                throw AnalysisEvidenceCapsuleError.integrityFailure
            }
            var capsule = Data()
            capsule.append(Self.magic)
            var aadLength = UInt32(aad.count).bigEndian
            withUnsafeBytes(of: &aadLength) { capsule.append(contentsOf: $0) }
            capsule.append(aad)
            capsule.append(combined)
            guard capsule.count - plaintext.count <= Self.maximumCapsuleOverheadBytes else {
                throw AnalysisEvidenceCapsuleError.malformedCapsule
            }
            let destination = capsuleURL(executionID: executionID)
            try ChatGPTSecureStorage.writeFileAtomically(capsule, to: destination)
            try? FileManager.default.setAttributes(
                [.creationDate: createdAt, .modificationDate: createdAt, .posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return destination
        }

        func decryptGeneratedResponse(executionID: String) throws -> Data {
            let capsule = try ChatGPTHistoryStore.readStableSource(
                at: capsuleURL(executionID: executionID),
                maximumBytes: Int64(Self.maximumPlaintextBytes + Self.maximumCapsuleOverheadBytes)
            )
            guard capsule.starts(with: Self.magic),
                capsule.count >= Self.magic.count + 4
            else { throw AnalysisEvidenceCapsuleError.malformedCapsule }
            let lengthRange = Self.magic.count..<(Self.magic.count + 4)
            let aadLength = capsule[lengthRange].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let aadStart = Self.magic.count + 4
            let aadEnd = aadStart + Int(aadLength)
            guard aadEnd <= capsule.count else { throw AnalysisEvidenceCapsuleError.malformedCapsule }
            let aad = capsule[aadStart..<aadEnd]
            let combined = capsule[aadEnd...]
            let keyData = try loadKey(executionID: executionID)
            do {
                let sealed = try AES.GCM.SealedBox(combined: combined)
                return try AES.GCM.open(
                    sealed,
                    using: SymmetricKey(data: keyData),
                    authenticating: aad
                )
            } catch {
                throw AnalysisEvidenceCapsuleError.integrityFailure
            }
        }

        /// Cryptographic deletion is key-first: once SecItemDelete succeeds the
        /// ciphertext is unrecoverable, even if its file removal is interrupted.
        func destroy(executionID: String) throws {
            var removedOrAbsent = false
            for dataProtection in [true, false] {
                var query = keyQuery(executionID: executionID)
                if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
                let status = SecItemDelete(query as CFDictionary)
                if status == errSecSuccess || status == errSecItemNotFound
                    || status == errSecMissingEntitlement
                {
                    removedOrAbsent = true
                    continue
                }
                throw AnalysisEvidenceCapsuleError.keychainFailure(status)
            }
            guard removedOrAbsent else { throw AnalysisEvidenceCapsuleError.keychainFailure(errSecItemNotFound) }
            try ChatGPTSecureStorage.removeRegularFileIfPresent(
                at: capsuleURL(executionID: executionID)
            )
        }

        @discardableResult
        func purgeExpired(
            now: Date = Date(),
            retentionDays: Int = AnalysisEvidenceCapsuleStore.retentionDays
        ) -> Int {
            let cutoff = now.addingTimeInterval(-Double(max(1, retentionDays)) * 86_400)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var removed = 0
            for file in files where file.pathExtension == "capsule" {
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                ), values.isRegularFile == true,
                    let date = values.contentModificationDate, date < cutoff
                else { continue }
                let executionID = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: executionID) != nil else { continue }
                if (try? destroy(executionID: executionID)) != nil { removed += 1 }
            }
            return removed
        }

        func capsuleURL(executionID: String) -> URL {
            directory.appendingPathComponent("\(executionID.lowercased()).capsule", isDirectory: false)
        }

        private func loadOrCreateKey(executionID: String) throws -> Data {
            if let existing = try? loadKey(executionID: executionID) { return existing }
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw AnalysisEvidenceCapsuleError.randomFailure(status)
            }
            for dataProtection in [true, false] {
                var attributes = keyQuery(executionID: executionID)
                attributes[kSecValueData as String] = bytes
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                if dataProtection { attributes[kSecUseDataProtectionKeychain as String] = true }
                let addStatus = SecItemAdd(attributes as CFDictionary, nil)
                if addStatus == errSecSuccess { return bytes }
                if addStatus == errSecDuplicateItem {
                    return try loadKey(executionID: executionID)
                }
                if dataProtection, addStatus == errSecMissingEntitlement { continue }
                throw AnalysisEvidenceCapsuleError.keychainFailure(addStatus)
            }
            throw AnalysisEvidenceCapsuleError.keychainFailure(errSecMissingEntitlement)
        }

        private func loadKey(executionID: String) throws -> Data {
            var lastStatus = errSecItemNotFound
            for dataProtection in [true, false] {
                var query = keyQuery(executionID: executionID)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecSuccess, let data = result as? Data, data.count == 32 {
                    return data
                }
                lastStatus = status
                if status == errSecItemNotFound || status == errSecMissingEntitlement { continue }
                throw AnalysisEvidenceCapsuleError.keychainFailure(status)
            }
            throw AnalysisEvidenceCapsuleError.keychainFailure(lastStatus)
        }

        private func keyQuery(executionID: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: executionID.lowercased(),
            ]
        }
    }
#endif
