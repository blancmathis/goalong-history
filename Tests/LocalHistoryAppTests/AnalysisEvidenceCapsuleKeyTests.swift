#if os(macOS)
    import Foundation
    import Security
    import XCTest
    @testable import LocalHistoryApp

    /// In-memory keychain: these tests never touch the real keychain.
    private final class FakeEvidenceKeychain {
        var items: [String: Data] = [:]
        var copyStatus: OSStatus?
        var addCount = 0

        private func account(_ query: CFDictionary) -> String {
            ((query as NSDictionary)[kSecAttrAccount as String] as? String) ?? ""
        }

        func makeStore(directory: URL) -> AnalysisEvidenceCapsuleStore {
            AnalysisEvidenceCapsuleStore(
                directory: directory,
                deleteKeyItem: { [unowned self] query in
                    items.removeValue(forKey: account(query)) == nil ? errSecItemNotFound : errSecSuccess
                },
                copyKeyItem: { [unowned self] query, result in
                    if let copyStatus { return copyStatus }
                    guard let data = items[account(query)] else { return errSecItemNotFound }
                    result?.pointee = data as CFData
                    return errSecSuccess
                },
                addKeyItem: { [unowned self] query in
                    addCount += 1
                    let name = account(query)
                    guard items[name] == nil else { return errSecDuplicateItem }
                    items[name] = (query as NSDictionary)[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            )
        }
    }

    final class AnalysisEvidenceCapsuleKeyTests: XCTestCase {
        private func directory() throws -> URL {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            _ = FileManager.default.temporaryDirectory.path.withCString { Darwin.realpath($0, &buffer) }
            let base = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            let url = base
                .appendingPathComponent("goalong-evidence-key-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }

        func testKeyIsRemovedWhenTheCapsuleCannotBeWritten() throws {
            let root = try directory()
            let keychain = FakeEvidenceKeychain()
            let store = keychain.makeStore(directory: root)
            let id = UUID().uuidString.lowercased()
            // A directory where the capsule file must go makes the atomic write fail.
            try FileManager.default.createDirectory(
                at: store.capsuleURL(executionID: id), withIntermediateDirectories: true)
            XCTAssertThrowsError(
                try store.storeGeneratedResponse(Data("x".utf8), executionID: id, createdAt: Date()))
            XCTAssertEqual(keychain.addCount, 1)
            XCTAssertTrue(keychain.items.isEmpty, "the orphan key must be deleted")
        }

        func testSuccessfulWriteKeepsTheKeyAndRoundTrips() throws {
            let keychain = FakeEvidenceKeychain()
            let store = keychain.makeStore(directory: try directory())
            let id = UUID().uuidString.lowercased()
            _ = try store.storeGeneratedResponse(Data("hello".utf8), executionID: id, createdAt: Date())
            XCTAssertEqual(keychain.items.count, 1)
            XCTAssertEqual(try store.decryptGeneratedResponse(executionID: id), Data("hello".utf8))
        }

        func testTransientKeychainErrorNeverCreatesAReplacementKey() throws {
            let keychain = FakeEvidenceKeychain()
            keychain.copyStatus = errSecInteractionNotAllowed
            let store = keychain.makeStore(directory: try directory())
            XCTAssertThrowsError(
                try store.storeGeneratedResponse(
                    Data("x".utf8), executionID: UUID().uuidString.lowercased(), createdAt: Date())
            ) { error in
                guard case .keychainFailure(let status)? = error as? AnalysisEvidenceCapsuleError
                else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(status, errSecInteractionNotAllowed)
            }
            XCTAssertEqual(keychain.addCount, 0)
            XCTAssertTrue(keychain.items.isEmpty)
        }

        func testLongTextIsTruncatedNotRejectedAndNoNamePrefixSurvivesTheCut() throws {
            let secret = "SENSITIVEPROJECTNAME"
            let transformer = try GoalongTextTransformer([
                GoalongTextReplacement(search: secret, replacement: "Projet A")
            ])
            // Secret straddles the pre-cut (bound 120 000, margin 2 048).
            let cut = 120_000 - 2_048
            let text = String(repeating: "a", count: cut - 5) + secret + String(repeating: "b", count: 400_000)
            XCTAssertThrowsError(try transformer.apply(text))
            let result = try transformer.applyTruncating(text, keeping: 16_000)
            XCTAssertFalse(result.contains("SENSITIVE"))
            XCTAssertFalse(result.contains("PROJ"))
            XCTAssertGreaterThanOrEqual(result.count, 16_000)
            XCTAssertEqual(try transformer.applyTruncating("Voir \(secret)", keeping: 16_000), "Voir Projet A")
        }
    }
#endif
