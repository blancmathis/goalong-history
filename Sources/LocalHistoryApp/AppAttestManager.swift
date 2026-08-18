#if os(macOS)
    import Foundation
    import LocalHistoryCore

    #if canImport(DeviceCheck) && !LOCALHISTORY_NO_APP_ATTEST
        import DeviceCheck
    #endif

    struct AppAttestMaterial {
        let keyID: String?
        let attestationObjectBase64: String?
        let assertionBase64: String?
    }

    /// Optional hardening layer. The cryptographic anchor protocol works without App Attest,
    /// but the server must display a lower trust tier when App Attest is unavailable.
    final class AppAttestManager {
        private let enabled: Bool
        private let defaultsKey = "LocalHistory.AppAttest.KeyID.v1"

        init(enabled: Bool) {
            self.enabled = enabled
        }

        func materialForRegistration(clientDataHash: Data, completion: @escaping (AppAttestMaterial) -> Void) {
            guard enabled else {
                completion(AppAttestMaterial(keyID: nil, attestationObjectBase64: nil, assertionBase64: nil))
                return
            }

            #if canImport(DeviceCheck) && !LOCALHISTORY_NO_APP_ATTEST
                if #available(macOS 27.0, *) {
                    let service = DCAppAttestService.shared
                    guard service.isSupported else {
                        completion(AppAttestMaterial(keyID: nil, attestationObjectBase64: nil, assertionBase64: nil))
                        return
                    }

                    if let keyID = UserDefaults.standard.string(forKey: defaultsKey) {
                        service.generateAssertion(keyID, clientDataHash: clientDataHash) { assertion, _ in
                            completion(AppAttestMaterial(
                                keyID: keyID,
                                attestationObjectBase64: nil,
                                assertionBase64: assertion?.base64EncodedString()
                            ))
                        }
                        return
                    }

                    service.generateKey { [weak self] keyID, error in
                        guard let self, let keyID, error == nil else {
                            completion(AppAttestMaterial(keyID: nil, attestationObjectBase64: nil, assertionBase64: nil))
                            return
                        }
                        UserDefaults.standard.set(keyID, forKey: self.defaultsKey)
                        service.attestKey(keyID, clientDataHash: clientDataHash) { object, _ in
                            completion(AppAttestMaterial(
                                keyID: keyID,
                                attestationObjectBase64: object?.base64EncodedString(),
                                assertionBase64: nil
                            ))
                        }
                    }
                    return
                }
            #endif

            completion(AppAttestMaterial(keyID: nil, attestationObjectBase64: nil, assertionBase64: nil))
        }

        func assertion(clientDataHash: Data, completion: @escaping (AppAttestMaterial) -> Void) {
            guard enabled else {
                completion(AppAttestMaterial(keyID: nil, attestationObjectBase64: nil, assertionBase64: nil))
                return
            }

            #if canImport(DeviceCheck) && !LOCALHISTORY_NO_APP_ATTEST
                if #available(macOS 27.0, *),
                   let keyID = UserDefaults.standard.string(forKey: defaultsKey),
                   DCAppAttestService.shared.isSupported
                {
                    DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash) { assertion, _ in
                        completion(AppAttestMaterial(
                            keyID: keyID,
                            attestationObjectBase64: nil,
                            assertionBase64: assertion?.base64EncodedString()
                        ))
                    }
                    return
                }
            #endif

            completion(AppAttestMaterial(keyID: nil, attestationObjectBase64: nil, assertionBase64: nil))
        }
    }
#endif
