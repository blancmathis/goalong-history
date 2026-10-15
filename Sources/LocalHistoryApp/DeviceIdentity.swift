#if os(macOS)
    import Foundation
    import LocalAuthentication
    import LocalHistoryCore
    import Security

    enum DeviceIdentityError: Error, CustomStringConvertible {
        case cannotCreateKey(OSStatus)
        case cannotLoadKey(OSStatus)
        case cannotCopyPublicKey
        case cannotExportPublicKey(OSStatus)
        case cannotPersistSoftwareKey
        case cannotSign(CFError?)

        var description: String {
            switch self {
            case .cannotCreateKey(let status): return "Cannot create signing key (OSStatus \(status))"
            case .cannotLoadKey(let status): return "Cannot load signing key (OSStatus \(status))"
            case .cannotCopyPublicKey: return "Cannot copy signing public key"
            case .cannotExportPublicKey(let status): return "Cannot export public key (OSStatus \(status))"
            case .cannotPersistSoftwareKey: return "Cannot persist the local software signing key"
            case .cannotSign(let error): return "Cannot sign anchor: \(String(describing: error))"
            }
        }

        var shouldSuspendBackgroundSigning: Bool {
            guard case .cannotSign(let error) = self, let error else { return false }
            let code = CFErrorGetCode(error)
            return code == errSecUserCanceled
                || code == errSecInteractionNotAllowed
                || code == errSecAuthFailed
        }
    }

    struct DeviceIdentityInfo: Codable {
        let deviceID: String
        let publicKeyBase64: String
        let trustTier: String
        let algorithm: String

        var protectionTitle: String {
            switch trustTier {
            case "secure_enclave": return "Protégée par la Secure Enclave"
            case "keychain_software": return "Protégée par le Trousseau"
            default: return "Clé logicielle locale"
            }
        }

        var protectionSummary: String {
            switch trustTier {
            case "secure_enclave":
                return "Les engagements minute par minute sont signés par une clé P-256 non exportable de la Secure Enclave."
            case "keychain_software":
                return "Les engagements minute par minute sont signés par une clé P-256 logicielle conservée dans le Trousseau."
            default:
                return "Les engagements minute par minute sont signés par une clé P-256 locale réservée à votre compte (version compilée localement)."
            }
        }
    }

    final class DeviceIdentity {
        // v1 keys were stored in the legacy file-based macOS keychain. A key created
        // by an ad-hoc development build can then ask for the login password on every
        // signature after the app receives a stable signature. v2 deliberately uses
        // the Data Protection keychain, whose access is tied to the app identity and
        // which never presents authentication UI for background minute sealing.
        private static let secureEnclaveTag = Data("ai.goalong.localhistory.anchor-key.secureenclave.v2".utf8)
        private static let softwareTag = Data("ai.goalong.localhistory.anchor-key.software.v2".utf8)
        private static let keyLabel = "Goalong History minute signing key"

        private let privateKey: SecKey
        let info: DeviceIdentityInfo

        private static let sharedLock = NSLock()
        private static var sharedInstance: DeviceIdentity?
        private static let lastIdentityKey = "goalong.deviceIdentity.last.v1"

        /// One identity per process: the app and the ChatGPT recap must sign with the same key,
        /// and a second resolution must never land on another tier.
        static func shared() throws -> DeviceIdentity {
            sharedLock.lock(); defer { sharedLock.unlock() }
            if let sharedInstance { return sharedInstance }
            let identity = try DeviceIdentity()
            noteIdentity(identity.info)
            sharedInstance = identity
            return identity
        }

        /// Pure: a device that resolves to another id or tier than the previous launch is a changed trust state.
        static func identityChanged(previous: String?, current: DeviceIdentityInfo) -> Bool {
            guard let previous else { return false }
            return previous != "\(current.deviceID)|\(current.trustTier)"
        }

        private static func noteIdentity(_ info: DeviceIdentityInfo, defaults: UserDefaults = .standard) {
            let previous = defaults.string(forKey: lastIdentityKey)
            if identityChanged(previous: previous, current: info) {
                Diagnostics.write("Device signing identity changed since the previous launch (tier \(info.trustTier))")
            }
            defaults.set("\(info.deviceID)|\(info.trustTier)", forKey: lastIdentityKey)
        }

        /// A tier is unavailable when it cannot be used at all (no entitlement, key creation refused).
        /// Any other load failure means an existing key could not be read right now.
        static func isTierUnavailable(_ error: Error) -> Bool {
            switch error as? DeviceIdentityError {
            case .cannotCreateKey: return true
            case .cannotLoadKey(let status): return status == errSecMissingEntitlement
            default: return false
            }
        }

        /// Returns the first tier that yields a value. Falls through only from unavailable tiers.
        /// An unreadable existing key is retried, then thrown: creating a lower-tier key would fork the device identity.
        static func resolveFirst<T>(
            _ tiers: [() throws -> T], attempts: Int = 4, delay: TimeInterval = 0.25,
            pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        ) throws -> T? {
            for tier in tiers {
                var attempt = 0
                while true {
                    do { return try tier() }
                    catch {
                        if isTierUnavailable(error) { break }
                        attempt += 1
                        if attempt >= attempts { throw error }
                        pause(delay)
                    }
                }
            }
            return nil
        }

        init() throws {
            let tiers: [() throws -> (SecKey, String)] = [
                { (try Self.loadOrCreateDataProtectionKey(tag: Self.secureEnclaveTag, secureEnclave: true), "secure_enclave") },
                { (try Self.loadOrCreateDataProtectionKey(tag: Self.softwareTag, secureEnclave: false), "keychain_software") },
                {
                    guard let signingScope = Self.stableSigningScope() else {
                        throw DeviceIdentityError.cannotLoadKey(errSecMissingEntitlement)
                    }
                    return (try Self.loadOrCreateLegacySoftwareKey(
                        tag: Self.scopedLegacyTag(base: Self.softwareTag, signingScope: signingScope)), "keychain_software")
                },
            ]
            if let (key, tier) = try Self.resolveFirst(tiers) {
                privateKey = key
                info = try Self.makeInfo(privateKey: key, trustTier: tier)
                return
            }

            // Ad-hoc source builds do not have a stable application identifier and
            // therefore cannot use the Data Protection keychain. They fall back to a
            // user-only local key file instead of the legacy keychain, because the
            // latter is what causes the recurring password dialog after recompiles.
            let key = try Self.loadOrCreateLocalSoftwareKey()
            privateKey = key
            info = try Self.makeInfo(privateKey: key, trustTier: "local_software")
        }

        func sign(_ message: Data) throws -> Data {
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                privateKey,
                .ecdsaSignatureMessageX962SHA256,
                message as CFData,
                &error
            ) as Data? else {
                throw DeviceIdentityError.cannotSign(error?.takeRetainedValue())
            }
            return signature
        }

        private static func loadOrCreateDataProtectionKey(tag: Data, secureEnclave: Bool) throws -> SecKey {
            let authenticationContext = LAContext()
            authenticationContext.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: authenticationContext,
            ]

            var result: CFTypeRef?
            let existingStatus = SecItemCopyMatching(query as CFDictionary, &result)
            if existingStatus == errSecSuccess, let result {
                return result as! SecKey
            }
            if existingStatus != errSecItemNotFound {
                throw DeviceIdentityError.cannotLoadKey(existingStatus)
            }

            var privateAttrs: [String: Any] = [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrLabel as String: keyLabel,
                kSecAttrIsExtractable as String: false,
            ]

            if secureEnclave {
                var accessError: Unmanaged<CFError>?
                if let access = SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    [.privateKeyUsage],
                    &accessError
                ) {
                    privateAttrs[kSecAttrAccessControl as String] = access
                }
            } else {
                // The privateKeyUsage constraint is specific to Secure Enclave keys.
                // Applying it to the software fallback prevents Keychain from storing
                // the generated key and makes the app fail during startup.
                privateAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }

            var attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: privateAttrs,
                kSecUseDataProtectionKeychain as String: true,
            ]
            if secureEnclave {
                attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            }

            var createError: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
                throw DeviceIdentityError.cannotCreateKey(osStatus(from: createError))
            }
            return key
        }

        private static func loadOrCreateLegacySoftwareKey(tag: Data) throws -> SecKey {
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]

            var result: CFTypeRef?
            let existingStatus = SecItemCopyMatching(query as CFDictionary, &result)
            if existingStatus == errSecSuccess, let result {
                return result as! SecKey
            }
            if existingStatus != errSecItemNotFound {
                throw DeviceIdentityError.cannotLoadKey(existingStatus)
            }

            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: tag,
                    kSecAttrLabel as String: keyLabel,
                    kSecAttrIsExtractable as String: false,
                ],
            ]
            var createError: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
                throw DeviceIdentityError.cannotCreateKey(osStatus(from: createError))
            }
            return key
        }

        private static func stableSigningScope() -> String? {
            var dynamicCode: SecCode?
            guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else { return nil }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess, let staticCode else {
                return nil
            }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
                let values = information as? [String: Any],
                let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
            else { return nil }

            var requirement: SecRequirement?
            guard !teamIdentifier.isEmpty,
                  SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
                  let requirement
            else { return nil }
            var requirementData: CFData?
            guard SecRequirementCopyData(requirement, [], &requirementData) == errSecSuccess,
                  let requirementData
            else { return nil }
            return String(SHA256Digest.hashHex(requirementData as Data).prefix(20))
        }

        private static func scopedLegacyTag(base: Data, signingScope: String) -> Data {
            var tag = base
            tag.append(Data(".\(signingScope)".utf8))
            return tag
        }

        private static func loadOrCreateLocalSoftwareKey() throws -> SecKey {
            try AppPaths.prepare()
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 256,
            ]

            if let data = try? Data(contentsOf: AppPaths.softwareSigningKeyFile) {
                var loadError: Unmanaged<CFError>?
                if let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &loadError) {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: AppPaths.softwareSigningKeyFile.path)
                    return key
                }
            }

            var createError: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
                throw DeviceIdentityError.cannotCreateKey(osStatus(from: createError))
            }
            var exportError: Unmanaged<CFError>?
            guard let data = SecKeyCopyExternalRepresentation(key, &exportError) as Data? else {
                throw DeviceIdentityError.cannotExportPublicKey(osStatus(from: exportError))
            }
            do {
                try data.write(to: AppPaths.softwareSigningKeyFile, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: AppPaths.softwareSigningKeyFile.path)
            } catch {
                throw DeviceIdentityError.cannotPersistSoftwareKey
            }
            return key
        }

        private static func osStatus(from unmanagedError: Unmanaged<CFError>?) -> OSStatus {
            guard let unmanagedError else {
                return errSecParam
            }
            let error = unmanagedError.takeRetainedValue()
            return OSStatus(CFErrorGetCode(error))
        }

        private static func makeInfo(privateKey: SecKey, trustTier: String) throws -> DeviceIdentityInfo {
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw DeviceIdentityError.cannotCopyPublicKey
            }
            var error: Unmanaged<CFError>?
            guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
                throw DeviceIdentityError.cannotExportPublicKey(osStatus(from: error))
            }
            let deviceID = SHA256Digest.hashHex(data)
            return DeviceIdentityInfo(
                deviceID: deviceID,
                publicKeyBase64: data.base64EncodedString(),
                trustTier: trustTier,
                algorithm: "P-256/ECDSA-X9.62-SHA256"
            )
        }
    }
#endif
