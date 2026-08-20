#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import Security

    enum BuildIdentityReader {
        static func current(bundle: Bundle = .main) -> CaptureBuildIdentity {
            let bundleIdentifier = bundle.bundleIdentifier ?? "ai.goalong.localhistory"
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let executablePath = bundle.executableURL?.path ?? CommandLine.arguments.first ?? "unknown"

            var code: SecCode?
            guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else {
                return fallback(
                    bundleIdentifier: bundleIdentifier,
                    version: version,
                    buildNumber: buildNumber,
                    executablePath: executablePath
                )
            }

            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
                let staticCode
            else {
                return fallback(
                    bundleIdentifier: bundleIdentifier,
                    version: version,
                    buildNumber: buildNumber,
                    executablePath: executablePath
                )
            }

            var rawInformation: CFDictionary?
            let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
            guard SecCodeCopySigningInformation(staticCode, flags, &rawInformation) == errSecSuccess,
                let information = rawInformation as? [String: Any]
            else {
                return fallback(
                    bundleIdentifier: bundleIdentifier,
                    version: version,
                    buildNumber: buildNumber,
                    executablePath: executablePath
                )
            }

            let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String
            let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
            let unique = information[kSecCodeInfoUnique as String] as? Data
            let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate]
            var designatedRequirementReference: SecRequirement?
            let designatedRequirement: String?
            if SecCodeCopyDesignatedRequirement(
                staticCode,
                SecCSFlags(rawValue: 0),
                &designatedRequirementReference
            ) == errSecSuccess, let designatedRequirementReference {
                designatedRequirement = requirementString(designatedRequirementReference)
            } else {
                designatedRequirement = nil
            }

            let signatureKind: BuildSignatureKind
            if teamIdentifier != nil {
                let receipt = bundle.appStoreReceiptURL
                signatureKind = receipt.map { FileManager.default.fileExists(atPath: $0.path) } == true
                    ? .appStore
                    : .developerID
            } else if unique != nil, certificates?.isEmpty != false {
                signatureKind = .adHoc
            } else if unique != nil {
                signatureKind = .other
            } else {
                signatureKind = .unsigned
            }

            return CaptureBuildIdentity(
                bundleIdentifier: bundleIdentifier,
                displayVersion: version,
                buildNumber: buildNumber,
                executablePath: executablePath,
                signatureKind: signatureKind,
                signingIdentifier: signingIdentifier,
                teamIdentifier: teamIdentifier,
                codeDirectoryHash: unique?.map { String(format: "%02x", $0) }.joined(),
                designatedRequirement: designatedRequirement
            )
        }

        private static func requirementString(_ requirement: SecRequirement) -> String? {
            var text: CFString?
            guard SecRequirementCopyString(requirement, SecCSFlags(rawValue: 0), &text) == errSecSuccess else {
                return nil
            }
            return text as String?
        }

        private static func fallback(
            bundleIdentifier: String,
            version: String?,
            buildNumber: String?,
            executablePath: String
        ) -> CaptureBuildIdentity {
            CaptureBuildIdentity(
                bundleIdentifier: bundleIdentifier,
                displayVersion: version,
                buildNumber: buildNumber,
                executablePath: executablePath,
                signatureKind: .unsigned,
                signingIdentifier: nil,
                teamIdentifier: nil,
                codeDirectoryHash: nil,
                designatedRequirement: nil
            )
        }
    }
#endif
