import XCTest

@testable import LocalHistoryCore
@testable import LocalHistoryQueryCLI

final class GoalongCLIProofCommandsTests: XCTestCase {
    private typealias Fixture = GoalongCLIProofFixture
    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        super.tearDown()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-proof-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }

    private func output(_ arguments: [String]) throws -> [String: Any] {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var failure: Error?
        do { try GoalongQueryCLI.run(arguments: arguments) } catch { failure = error }
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let failure { throw failure }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeArchive(_ entries: [String: Data], named name: String = "proof.goalong-proof", in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try GoalongProofArchive.create(entries: entries).write(to: url)
        return url
    }

    private func report(_ json: [String: Any]) -> [String: Any]? { json["report"] as? [String: Any] }

    // MARK: verify-proof

    func testVerifyProofAcceptsAValidStandaloneProof() throws {
        let directory = try temporaryDirectory()
        let package = try writeArchive(Fixture.proofEntries().entries, in: directory)
        let json = try output(["verify-proof", package.path])
        XCTAssertEqual(json["status"] as? String, "locallyValid")
        XCTAssertNil(json["error"] as? String)
        XCTAssertEqual(report(json)?["isLocallyValid"] as? Bool, true)
        XCTAssertEqual(report(json)?["runSignature"] as? String, "valid")
        XCTAssertEqual(json["packageSHA256"] as? String, GoalongProofDigest.sha256(try Data(contentsOf: package)))
    }

    func testVerifyProofRejectsATamperedArtifactWithoutPassingIt() throws {
        let directory = try temporaryDirectory()
        var entries = try Fixture.proofEntries().entries
        entries["result.json"] = Data(#"{"altered":true}"#.utf8)
        let json = try output(["verify-proof", try writeArchive(entries, in: directory).path])
        XCTAssertEqual(json["status"] as? String, "invalid")
        XCTAssertEqual(report(json)?["isLocallyValid"] as? Bool, false)
        XCTAssertTrue((json["error"] as? String ?? "").contains("artifact_hash_mismatch:result.json"))
    }

    func testVerifyProofRejectsAProofSignedByAnotherDeviceKey() throws {
        let directory = try temporaryDirectory()
        var entries = try Fixture.proofEntries().entries
        let foreign = try Fixture.proofEntries().entries
        entries["device-public-key.x963"] = foreign["device-public-key.x963"]
        entries["manifest.json"] = try Fixture.manifest(
            for: entries.filter { $0.key != "manifest.json" })
        let json = try output(["verify-proof", try writeArchive(entries, in: directory).path])
        XCTAssertNotEqual(json["status"] as? String, "locallyValid")
        XCTAssertEqual(report(json)?["isLocallyValid"] as? Bool, false)
    }

    func testVerifyProofReportsTruncatedGarbageAndMissingFilesAsInaccessibleOrInvalid() throws {
        let directory = try temporaryDirectory()
        let valid = try GoalongProofArchive.create(entries: Fixture.proofEntries().entries)
        let truncated = directory.appendingPathComponent("truncated.goalong-proof")
        try valid.prefix(valid.count / 2).write(to: truncated)
        let garbage = directory.appendingPathComponent("garbage.goalong-proof")
        try Data("not a zip".utf8).write(to: garbage)
        for path in [truncated.path, garbage.path, directory.appendingPathComponent("missing.goalong-proof").path] {
            let json = try output(["verify-proof", path])
            XCTAssertEqual(json["status"] as? String, "inaccessibleOrInvalid", path)
            XCTAssertEqual(json["packageBytes"] as? Int, 0)
            XCTAssertEqual(json["packageSHA256"] as? String, "")
            XCTAssertFalse((json["error"] as? String ?? "").isEmpty)
            XCTAssertNil(json["report"] as? [String: Any])
        }
    }

    func testVerifyProofRejectsAnUnlistedEntryAndBadUsage() throws {
        let directory = try temporaryDirectory()
        var entries = try Fixture.proofEntries().entries
        entries["unlisted.txt"] = Data("hidden".utf8)
        let json = try output(["verify-proof", try writeArchive(entries, in: directory).path])
        XCTAssertEqual(json["status"] as? String, "inaccessibleOrInvalid")
        XCTAssertThrowsError(try output(["verify-proof"]))
        XCTAssertThrowsError(try output(["verify-proof", "a.goalong-proof", "b.goalong-proof"]))
    }

    // MARK: export-proof

    private func prepareExportRoot(
        tamper: ((inout [String: Data]) -> Void)? = nil,
        withProofReference: Bool = true
    ) throws -> (root: URL, executionID: String) {
        let root = try temporaryDirectory()
        var (entries, executionID) = try Fixture.proofEntries()
        let runJWS = entries["run.jws"]!
        tamper?(&entries)
        try Fixture.writeProofDirectory(entries, executionID: executionID, root: root)
        let proof = withProofReference
            ? Fixture.proofReference(executionID: executionID, runJWS: runJWS) : nil
        try Fixture.writeRecap(try Fixture.recapObject(schemaVersion: 4, proof: proof), root: root)
        return (root, executionID)
    }

    func testExportProofWritesAPackageThatVerifyProofAccepts() throws {
        let (root, executionID) = try prepareExportRoot()
        let destination = try temporaryDirectory().appendingPathComponent("day.goalong-proof")
        let json = try output(["--root", root.path, "export-proof", Fixture.day, "--output", destination.path])
        XCTAssertEqual(json["status"] as? String, "locallyValid")
        XCTAssertEqual(json["requestedDay"] as? String, Fixture.day)
        XCTAssertEqual(json["packagePath"] as? String, destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(json["packageBytes"] as? Int, try Data(contentsOf: destination).count)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let verified = try output(["verify-proof", destination.path])
        XCTAssertEqual(verified["status"] as? String, "locallyValid")
        XCTAssertEqual(verified["packageSHA256"] as? String, json["packageSHA256"] as? String)
        XCTAssertFalse(executionID.isEmpty)
    }

    func testExportProofRefusesATamperedProofAndWritesNothing() throws {
        let (root, _) = try prepareExportRoot(tamper: { $0["result.json"] = Data(#"{"altered":true}"#.utf8) })
        let destination = try temporaryDirectory().appendingPathComponent("tampered.goalong-proof")
        XCTAssertThrowsError(
            try output(["--root", root.path, "export-proof", Fixture.day, "--output", destination.path])
        ) { error in
            XCTAssertTrue(GoalongQueryCLI.errorMessage(for: error).contains("failed verification"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportProofRefusesAnIncompleteProofDirectory() throws {
        let (root, _) = try prepareExportRoot(tamper: { $0.removeValue(forKey: "run.jws") })
        let destination = try temporaryDirectory().appendingPathComponent("missing-run.goalong-proof")
        XCTAssertThrowsError(
            try output(["--root", root.path, "export-proof", Fixture.day, "--output", destination.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportProofRefusesBadDestinationsAndNeverOverwrites() throws {
        let (root, _) = try prepareExportRoot()
        let directory = try temporaryDirectory()
        let wrongExtension = directory.appendingPathComponent("day.zip")
        XCTAssertThrowsError(
            try output(["--root", root.path, "export-proof", Fixture.day, "--output", wrongExtension.path])
        ) { XCTAssertTrue(GoalongQueryCLI.errorMessage(for: $0).contains(".goalong-proof")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrongExtension.path))

        let existing = directory.appendingPathComponent("existing.goalong-proof")
        try Data("keep me".utf8).write(to: existing)
        XCTAssertThrowsError(
            try output(["--root", root.path, "export-proof", Fixture.day, "--output", existing.path])
        ) { XCTAssertTrue(GoalongQueryCLI.errorMessage(for: $0).contains("already exists")) }
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep me".utf8))
    }

    func testExportProofNeedsARecapWithAStandaloneProofReference() throws {
        let missing = try temporaryDirectory()
        let destination = try temporaryDirectory().appendingPathComponent("none.goalong-proof")
        let json = try? output(
            ["--root", missing.path, "export-proof", Fixture.day, "--output", destination.path])
        XCTAssertNil(json)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let (root, _) = try prepareExportRoot(withProofReference: false)
        XCTAssertThrowsError(
            try output(["--root", root.path, "export-proof", Fixture.day, "--output", destination.path])
        ) { XCTAssertTrue(GoalongQueryCLI.errorMessage(for: $0).contains("No standalone analysis proof")) }
        XCTAssertThrowsError(try output(["--root", root.path, "export-proof", Fixture.day, "extra"]))
    }

    // MARK: verify-share

    private func writeShare(_ package: DaySharePackage, in directory: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("share.json")
        try encoder.encode(package).write(to: url)
        return url
    }

    func testVerifyShareAcceptsAValidSignedPackage() throws {
        let url = try writeShare(Fixture.sharePackage(), in: try temporaryDirectory())
        let json = try output(["verify-share", url.path])
        XCTAssertEqual(json["status"] as? String, "locallyValid")
        XCTAssertEqual(json["localDay"] as? String, Fixture.day)
        XCTAssertNil(json["error"] as? String)
        XCTAssertEqual(report(json)?["validDeviceSignatureCount"] as? Int, 1)
        XCTAssertEqual((json["packageSHA256"] as? String)?.count, 64)
    }

    func testVerifyShareRejectsATamperedSignatureAndAnEmptyPackage() throws {
        let directory = try temporaryDirectory()
        let tampered = try output(["verify-share", try writeShare(Fixture.sharePackage(tamperSignature: true), in: directory).path])
        XCTAssertEqual(tampered["status"] as? String, "invalid")
        XCTAssertTrue((tampered["error"] as? String ?? "").contains("minute_7_device_signature_invalid"))
        XCTAssertEqual(report(tampered)?["validDeviceSignatureCount"] as? Int, 0)

        let empty = try output(["verify-share", try writeShare(Fixture.sharePackage(minuteCount: 0), in: directory).path])
        XCTAssertEqual(empty["status"] as? String, "invalid")
        XCTAssertTrue((empty["error"] as? String ?? "").contains("package_contains_no_minutes"))
    }

    func testVerifyShareReportsTruncatedAndMissingFilesAsInaccessibleOrInvalid() throws {
        let directory = try temporaryDirectory()
        let url = try writeShare(Fixture.sharePackage(), in: directory)
        let data = try Data(contentsOf: url)
        let truncated = directory.appendingPathComponent("truncated.json")
        try data.prefix(data.count / 2).write(to: truncated)
        for path in [truncated.path, directory.appendingPathComponent("missing.json").path] {
            let json = try output(["verify-share", path])
            XCTAssertEqual(json["status"] as? String, "inaccessibleOrInvalid", path)
            XCTAssertEqual(json["packageBytes"] as? Int, 0)
            XCTAssertNil(json["report"] as? [String: Any])
        }
        XCTAssertThrowsError(try output(["verify-share"]))
    }

    func testExportProofRefusesAProofReferenceThatPointsOutsideItsOwnDirectory() throws {
        let (root, executionID) = try prepareExportRoot()
        let recapURL = root.appendingPathComponent("chatgpt/recaps/\(Fixture.day).chatgpt-recap.json")
        let destination = try temporaryDirectory().appendingPathComponent("escape.goalong-proof")
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: recapURL)) as? [String: Any])
        for (field, value) in [("proofDirectoryName", "../\(executionID)"), ("executionID", "not-a-uuid")] {
            var object = original
            var proof = try XCTUnwrap(object["proof"] as? [String: Any])
            proof[field] = value
            if field == "executionID" { proof["proofDirectoryName"] = value }
            object["proof"] = proof
            try Fixture.writeRecap(object, root: root)
            XCTAssertThrowsError(
                try output(["--root", root.path, "export-proof", Fixture.day, "--output", destination.path]), field
            ) { XCTAssertTrue(GoalongQueryCLI.errorMessage(for: $0).contains("No standalone analysis proof"), field) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), field)
        }
    }

    func testVerifyProofAndVerifyShareDoNotFollowDirectoriesOrSymlinks() throws {
        let directory = try temporaryDirectory()
        let real = try writeArchive(Fixture.proofEntries().entries, in: directory)
        let link = directory.appendingPathComponent("link.goalong-proof")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let viaLink = try output(["verify-proof", link.path])
        XCTAssertNotEqual(viaLink["status"] as? String, "locallyValid")
        XCTAssertEqual(try output(["verify-proof", directory.path])["status"] as? String, "inaccessibleOrInvalid")
        XCTAssertEqual(try output(["verify-share", directory.path])["status"] as? String, "inaccessibleOrInvalid")
    }

    func testVerifyShareRejectsAnUnsupportedSchemaAndAMismatchedDeclaredDevice() throws {
        let directory = try temporaryDirectory()
        let valid = try Fixture.sharePackage()
        let unsupported = DaySharePackage(
            schemaVersion: 99, createdAt: valid.createdAt, deviceID: valid.deviceID,
            deviceIDs: valid.deviceIDs, localDay: valid.localDay, classifierVersion: "test", minutes: valid.minutes)
        let json = try output(["verify-share", try writeShare(unsupported, in: directory).path])
        XCTAssertEqual(json["status"] as? String, "invalid")
        XCTAssertTrue((json["error"] as? String ?? "").contains("unsupported_package_schema"))
        let foreignDevice = DaySharePackage(
            createdAt: valid.createdAt, deviceID: String(repeating: "e", count: 64),
            deviceIDs: valid.deviceIDs, localDay: valid.localDay, classifierVersion: "test", minutes: valid.minutes)
        let mismatch = try output(["verify-share", try writeShare(foreignDevice, in: directory).path])
        XCTAssertEqual(mismatch["status"] as? String, "invalid")
        XCTAssertTrue((mismatch["error"] as? String ?? "").contains("primary_device_identity_mismatch"))
    }

    // MARK: recap integrity

    func testRecapMarksASignedRecapLocallySignedAndVerifyRecapAgrees() throws {
        let root = try temporaryDirectory()
        try Fixture.writeRecap(try Fixture.recapObject(), root: root)
        let json = try output(["--root", root.path, "recap", Fixture.day])
        XCTAssertEqual(json["status"] as? String, "available")
        let integrity = try XCTUnwrap(json["integrity"] as? [String: Any])
        XCTAssertEqual(integrity["status"] as? String, "locallySigned")
        XCTAssertEqual(integrity["localDeviceSignatureValid"] as? Bool, true)
        XCTAssertEqual(integrity["savedResultMatches"] as? Bool, true)

        let file = root.appendingPathComponent("chatgpt/recaps/\(Fixture.day).chatgpt-recap.json")
        let verified = try output(["verify-recap", file.path])
        XCTAssertEqual(verified["status"] as? String, "locallyValid")
        XCTAssertNil(verified["error"] as? String)
    }

    func testRecapFlagsAChangedSummaryScoreOrForeignSignatureAsInvalid() throws {
        let root = try temporaryDirectory()
        var changedLine = try Fixture.recapObject()
        var lines = Fixture.summaryLines
        lines[0] = "Edited after signing"
        changedLine["summaryLines"] = lines
        changedLine["markdown"] = lines.joined(separator: "\n")
        var changedScore = try Fixture.recapObject()
        changedScore["productivityScore"] = 99
        var foreign = try Fixture.recapObject()
        var foreignAttestation = try XCTUnwrap(foreign["attestation"] as? [String: Any])
        let other = try XCTUnwrap(try Fixture.recapObject()["attestation"] as? [String: Any])
        foreignAttestation["publicKeyBase64"] = other["publicKeyBase64"]
        foreign["attestation"] = foreignAttestation
        let directory = try temporaryDirectory()
        for (index, object) in [changedLine, changedScore, foreign].enumerated() {
            try Fixture.writeRecap(object, root: root)
            let json = try output(["--root", root.path, "recap", Fixture.day])
            let integrity = try XCTUnwrap(json["integrity"] as? [String: Any])
            XCTAssertEqual(integrity["status"] as? String, "invalid", "case \(index)")
            let file = directory.appendingPathComponent("recap\(index).json")
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            let verified = try output(["verify-recap", file.path])
            XCTAssertEqual(verified["status"] as? String, "invalid", "case \(index)")
            XCTAssertNotNil(verified["error"] as? String)
        }
    }

    func testRecapReportsLegacyUnsignedMissingAndUnreadableRecaps() throws {
        let root = try temporaryDirectory()
        let notGenerated = try output(["--root", root.path, "recap", Fixture.day])
        XCTAssertEqual(notGenerated["status"] as? String, "notGenerated")
        XCTAssertNil(notGenerated["recap"] as? [String: Any])

        try Fixture.writeRecap(try Fixture.recapObject(signed: false), root: root)
        let legacy = try output(["--root", root.path, "recap", Fixture.day])
        let integrity = try XCTUnwrap(legacy["integrity"] as? [String: Any])
        XCTAssertEqual(integrity["status"] as? String, "legacyUnsigned")
        XCTAssertEqual(integrity["localDeviceSignatureValid"] as? Bool, false)

        let file = root.appendingPathComponent("chatgpt/recaps/\(Fixture.day).chatgpt-recap.json")
        try Data("{\"truncated".utf8).write(to: file)
        let corrupt = try output(["--root", root.path, "recap", Fixture.day])
        XCTAssertEqual(corrupt["status"] as? String, "inaccessibleOrInvalid")
        XCTAssertNil(corrupt["integrity"] as? [String: Any])
        let verified = try output(["verify-recap", file.path])
        XCTAssertEqual(verified["status"] as? String, "inaccessibleOrInvalid")
        XCTAssertEqual(verified["reportBytes"] as? Int, 0)
        XCTAssertThrowsError(try output(["verify-recap"]))
        XCTAssertThrowsError(try output(["--root", root.path, "recap", Fixture.day, "extra"]))
    }

    func testRecapRequiresMatchingProofReferenceForSchemaFour() throws {
        let root = try temporaryDirectory()
        let runJWS = Data("a.b.c".utf8)
        let executionID = UUID().uuidString.lowercased()
        let proof = Fixture.proofReference(executionID: executionID, runJWS: runJWS)
        try Fixture.writeRecap(try Fixture.recapObject(schemaVersion: 4, proof: proof), root: root)
        let valid = try output(["--root", root.path, "recap", Fixture.day])
        XCTAssertEqual((valid["integrity"] as? [String: Any])?["status"] as? String, "locallySigned")

        var wrong = proof
        wrong["executionID"] = UUID().uuidString.lowercased()
        var object = try Fixture.recapObject(schemaVersion: 4, proof: proof)
        object["proof"] = wrong
        try Fixture.writeRecap(object, root: root)
        let mismatch = try output(["--root", root.path, "recap", Fixture.day])
        XCTAssertEqual((mismatch["integrity"] as? [String: Any])?["status"] as? String, "invalid")

        try Fixture.writeRecap(try Fixture.recapObject(schemaVersion: 4, proof: nil), root: root)
        let noProof = try output(["--root", root.path, "recap", Fixture.day])
        XCTAssertEqual((noProof["integrity"] as? [String: Any])?["status"] as? String, "invalid")
    }
}
