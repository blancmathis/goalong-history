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
        /// The existing key could not be read at startup: signing stays suspended for this launch.
        case identityUnavailable(OSStatus)

        var description: String {
            switch self {
            case .cannotCreateKey(let status): return "Cannot create signing key (OSStatus \(status))"
            case .cannotLoadKey(let status): return "Cannot load signing key (OSStatus \(status))"
            case .cannotCopyPublicKey: return "Cannot copy signing public key"
            case .cannotExportPublicKey(let status): return "Cannot export public key (OSStatus \(status))"
            case .cannotPersistSoftwareKey: return "Cannot persist the local software signing key"
            case .cannotSign(let error): return "Cannot sign anchor: \(String(describing: error))"
            case .identityUnavailable(let status): return "Signing identity unavailable (OSStatus \(status))"
            }
        }

        var shouldSuspendBackgroundSigning: Bool {
            if case .identityUnavailable = self { return true }
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

        /// Placeholder ID of a degraded identity with no persisted ID. Never a real device.
        static let unavailableDeviceID = "unavailable"

        /// The device ID, or nil when the identity is degraded and no earlier ID is known.
        var knownDeviceID: String? {
            deviceID.isEmpty || deviceID == Self.unavailableDeviceID ? nil : deviceID
        }

        var protectionTitle: String {
            switch trustTier {
            case "secure_enclave": return "Protégée par la Secure Enclave"
            case "keychain_software": return "Protégée par le Trousseau"
            case "unavailable": return "Signature suspendue"
            default: return "Clé logicielle locale"
            }
        }

        var protectionSummary: String {
            switch trustTier {
            case "secure_enclave":
                return "Les engagements minute par minute sont signés par une clé P-256 non exportable de la Secure Enclave."
            case "keychain_software":
                return "Les engagements minute par minute sont signés par une clé P-256 logicielle conservée dans le Trousseau."
            case "unavailable":
                return "Le Trousseau est inaccessible : les engagements minute par minute ne sont pas signés pendant ce lancement."
            default:
                return "Les engagements minute par minute sont signés par une clé P-256 locale réservée à votre compte (version compilée localement)."
            }
        }
    }

    /// Signing identity used when the existing key cannot be read at startup. It never signs.
    final class UnavailableDeviceIdentity: MinuteSealSigningIdentity {
        let info: DeviceIdentityInfo
        let status: OSStatus
        init(status: OSStatus, deviceID: String?) {
            self.status = status
            info = DeviceIdentityInfo(
                deviceID: deviceID ?? DeviceIdentityInfo.unavailableDeviceID, publicKeyBase64: "", trustTier: "unavailable",
                algorithm: "P-256/ECDSA-X9.62-SHA256")
        }
        func sign(_ message: Data) throws -> Data { throw DeviceIdentityError.identityUnavailable(status) }
    }

    struct DeviceIdentityStartup {
        let identity: MinuteSealSigningIdentity
        let info: DeviceIdentityInfo
        /// Non-nil when the key could not be read: sealing is suspended for this launch.
        let unavailableStatus: OSStatus?
        var unavailableError: Error? = nil
        var isDegraded: Bool { unavailableStatus != nil }

        /// Resolves the identity without ever failing startup. An unreadable existing key
        /// never creates another key; the app records without sealing instead.
        static func resolve(
            provider: () throws -> DeviceIdentity = { try DeviceIdentity.shared(attempts: 2, delay: 0.1) },
            defaults: UserDefaults = .standard
        ) -> DeviceIdentityStartup {
            do {
                let identity = try provider()
                return DeviceIdentityStartup(identity: identity, info: identity.info, unavailableStatus: nil)
            } catch {
                var status = errSecInteractionNotAllowed
                switch error as? DeviceIdentityError {
                case .cannotLoadKey(let value), .cannotCreateKey(let value), .identityUnavailable(let value):
                    status = value
                default: break
                }
                Diagnostics.write("Signing identity unavailable at startup, sealing suspended for this launch: \(error)")
                let unavailable = UnavailableDeviceIdentity(
                    status: status, deviceID: DeviceIdentity.lastPersistedDeviceID(defaults: defaults))
                return DeviceIdentityStartup(
                    identity: unavailable, info: unavailable.info, unavailableStatus: status, unavailableError: error)
            }
        }
    }

    struct DeviceIdentityRotation: Equatable {
        let at: Date
        let previousTier: String
        let newTier: String

        static func load(defaults: UserDefaults = .standard) -> DeviceIdentityRotation? {
            guard let value = defaults.string(forKey: DeviceIdentity.rotationKey) else { return nil }
            let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let seconds = TimeInterval(parts[0]) else { return nil }
            return DeviceIdentityRotation(
                at: Date(timeIntervalSince1970: seconds), previousTier: parts[1], newTier: parts[2])
        }

        static func tierTitle(_ tier: String) -> String {
            switch tier {
            case "secure_enclave": return "Secure Enclave"
            case "keychain_software": return "Trousseau"
            case "local_software": return "clé logicielle locale"
            default: return "inconnue"
            }
        }

        var notice: String {
            let date = at.formatted(date: .abbreviated, time: .omitted)
            return "Nouvelle identité de vérification depuis le \(date) (\(Self.tierTitle(previousTier)) → \(Self.tierTitle(newTier))). Les preuves précédentes restent liées à l’ancienne identité."
        }
    }

    /// Process-wide trust state shown in the menu bar and the integrity section.
    final class DeviceTrustState {
        static let shared = DeviceTrustState()
        static let didChange = Notification.Name("ai.goalong.deviceTrustDidChange")
        private let lock = NSLock()
        private var suspendedStatus: OSStatus?
        private var retryInFlight = false
        private var lastRetryFailedAt: Date?

        var sealingSuspendedNotice: String? {
            lock.lock(); defer { lock.unlock() }
            return suspendedStatus == nil ? nil : "Preuves suspendues : Trousseau inaccessible"
        }

        /// Secondary line shown under the notice after a failed « Réessayer ». The notice
        /// itself must not change: the Privacy page matches it by string equality.
        var retryFeedback: String? {
            lock.lock(); defer { lock.unlock() }
            guard suspendedStatus != nil else { return nil }
            if retryInFlight { return "Nouvelle tentative en cours…" }
            guard let failedAt = lastRetryFailedAt else { return nil }
            return "Échec à \(failedAt.formatted(date: .omitted, time: .shortened)) : trousseau toujours inaccessible. Déverrouillez-le puis réessayez."
        }

        var isRetryInFlight: Bool {
            lock.lock(); defer { lock.unlock() }
            return retryInFlight
        }

        /// Returns false when a retry is already running, so double clicks never overlap.
        func beginRetry() -> Bool {
            lock.lock()
            if retryInFlight { lock.unlock(); return false }
            retryInFlight = true
            lock.unlock()
            Self.postChange()
            return true
        }

        func markRetryFailed(at date: Date = Date()) {
            lock.lock(); retryInFlight = false; lastRetryFailedAt = date; lock.unlock()
            Self.postChange()
        }

        func setSealingSuspended(status: OSStatus?) {
            lock.lock()
            suspendedStatus = status
            if status == nil { retryInFlight = false; lastRetryFailedAt = nil }
            lock.unlock()
            Self.postChange()
        }

        static func postChange() {
            NotificationCenter.default.post(name: didChange, object: nil)
        }

        static func acknowledgeRotation(defaults: UserDefaults = .standard) {
            defaults.removeObject(forKey: DeviceIdentity.rotationKey)
            postChange()
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
        static func shared(attempts: Int = 4, delay: TimeInterval = 0.25) throws -> DeviceIdentity {
            sharedLock.lock(); defer { sharedLock.unlock() }
            if let sharedInstance { return sharedInstance }
            let identity = try DeviceIdentity(attempts: attempts, delay: delay)
            noteIdentity(identity.info)
            sharedInstance = identity
            return identity
        }

        /// Pure: a device that resolves to another id or tier than the previous launch is a changed trust state.
        static func identityChanged(previous: String?, current: DeviceIdentityInfo) -> Bool {
            guard let previous else { return false }
            return previous != "\(current.deviceID)|\(current.trustTier)"
        }

        static func noteIdentity(
            _ info: DeviceIdentityInfo, defaults: UserDefaults = .standard, now: Date = Date()
        ) {
            let previous = defaults.string(forKey: lastIdentityKey)
            if identityChanged(previous: previous, current: info) {
                Diagnostics.write("Device signing identity changed since the previous launch (tier \(info.trustTier))")
                // A visible changed trust state, kept until the user acknowledges it.
                let previousTier = previous?.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first
                    .map(String.init) ?? ""
                defaults.set(
                    "\(now.timeIntervalSince1970)|\(previousTier)|\(info.trustTier)", forKey: rotationKey)
                DeviceTrustState.postChange()
            }
            defaults.set("\(info.deviceID)|\(info.trustTier)", forKey: lastIdentityKey)
        }

        static let rotationKey = "goalong.deviceIdentity.rotation.v1"

        /// The device ID of the previous launch, if any. Never creates a key.
        static func lastPersistedDeviceID(defaults: UserDefaults = .standard) -> String? {
            guard let value = defaults.string(forKey: lastIdentityKey),
                let id = value.split(separator: "|", omittingEmptySubsequences: false).first, !id.isEmpty
            else { return nil }
            return String(id)
        }

        /// Errors where retrying would only repeat a prompt the user already answered.
        static func isImmediateStop(_ error: Error) -> Bool {
            guard case .cannotLoadKey(let status)? = error as? DeviceIdentityError else { return false }
            return status == errSecUserCanceled || status == errSecAuthFailed
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
                        if isImmediateStop(error) { throw error }
                        attempt += 1
                        if attempt >= attempts { throw error }
                        pause(delay)
                    }
                }
            }
            return nil
        }

        init(attempts: Int = 4, delay: TimeInterval = 0.25) throws {
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
            if let (key, tier) = try Self.resolveFirst(tiers, attempts: attempts, delay: delay) {
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
