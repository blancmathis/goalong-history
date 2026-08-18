#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import Security

    enum DeviceIdentityError: Error, CustomStringConvertible {
        case cannotCreateKey(OSStatus)
        case cannotLoadKey(OSStatus)
        case cannotCopyPublicKey
        case cannotExportPublicKey(OSStatus)
        case cannotSign(CFError?)

        var description: String {
            switch self {
            case .cannotCreateKey(let status): return "Cannot create signing key (OSStatus \(status))"
            case .cannotLoadKey(let status): return "Cannot load signing key (OSStatus \(status))"
            case .cannotCopyPublicKey: return "Cannot copy signing public key"
            case .cannotExportPublicKey(let status): return "Cannot export public key (OSStatus \(status))"
            case .cannotSign(let error): return "Cannot sign anchor: \(String(describing: error))"
            }
        }
    }

    struct DeviceIdentityInfo: Codable {
        let deviceID: String
        let publicKeyBase64: String
        let trustTier: String
        let algorithm: String
    }

    final class DeviceIdentity {
        private static let secureEnclaveTag = Data("ai.goalong.localhistory.anchor-key.secureenclave.v1".utf8)
        private static let softwareTag = Data("ai.goalong.localhistory.anchor-key.software.v1".utf8)

        private let privateKey: SecKey
        let info: DeviceIdentityInfo

        init() throws {
            if let key = try? Self.loadOrCreate(tag: Self.secureEnclaveTag, secureEnclave: true) {
                privateKey = key
                info = try Self.makeInfo(privateKey: key, trustTier: "secure_enclave")
            } else {
                let key = try Self.loadOrCreate(tag: Self.softwareTag, secureEnclave: false)
                privateKey = key
                info = try Self.makeInfo(privateKey: key, trustTier: "keychain_software")
            }
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

        private static func loadOrCreate(tag: Data, secureEnclave: Bool) throws -> SecKey {
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

            var privateAttrs: [String: Any] = [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
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
