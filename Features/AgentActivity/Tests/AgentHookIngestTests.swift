import Darwin
import Dispatch
import Foundation
import XCTest

@testable import AgentActivity

final class AgentHookIngestTests: XCTestCase {
    func testSimulatedOversizedUnterminatedStreamIsBoundedAndBodyNeverReachesStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-hook-ingest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
        }

        let secret = "HOOK-SECRET-\(UUID().uuidString)-MUST-NOT-BE-PERSISTED"
        let body = Data((secret + String(repeating: "x", count: 256)).utf8)
        let written = body.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(writeDescriptor, baseAddress, rawBuffer.count)
        }
        XCTAssertEqual(written, body.count)

        let byteLimit = 64
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let discardedBytes = AgentHookInputDrainer.discard(
            fromFileDescriptor: readDescriptor,
            maximumBytes: byteLimit,
            timeoutMilliseconds: 100
        )
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000

        XCTAssertEqual(discardedBytes, Int64(byteLimit))
        XCTAssertLessThan(elapsedSeconds, 0.5)

        let signalURL = try AgentHookSignalWriter.write(
            rootDirectory: root,
            provider: .codex,
            eventName: "UserPromptSubmit",
            discardedPayloadBytes: discardedBytes,
            processIdentifier: 42,
            signaledAt: Date(timeIntervalSince1970: 1_787_472_000)
        )
        let signalData = try Data(contentsOf: signalURL)
        let signalObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: signalData) as? [String: Any]
        )
        XCTAssertEqual(
            Set(signalObject.keys),
            Set([
                "schemaVersion", "provider", "eventName", "signaledAt",
                "processIdentifier", "discardedPayloadBytes",
            ])
        )
        XCTAssertEqual(signalObject["discardedPayloadBytes"] as? Int, byteLimit)
        XCTAssertFalse(try storedUTF8(beneath: root).contains(secret))
        XCTAssertLessThan(signalData.count, 1_024)
    }

    func testUnterminatedEmptyStreamStopsAtDeadline() {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let discardedBytes = AgentHookInputDrainer.discard(
            fromFileDescriptor: readDescriptor,
            timeoutMilliseconds: 50
        )
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000

        XCTAssertEqual(discardedBytes, 0)
        XCTAssertGreaterThanOrEqual(elapsedSeconds, 0.025)
        XCTAssertLessThan(elapsedSeconds, 0.5)
    }

    func testFiniteStreamStopsAtEOFAndCountsOnlyConsumedBytes() {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer { Darwin.close(readDescriptor) }

        let body = Data("finite-hook-\(UUID().uuidString)".utf8)
        let written = body.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(writeDescriptor, baseAddress, rawBuffer.count)
        }
        XCTAssertEqual(written, body.count)
        XCTAssertEqual(Darwin.close(writeDescriptor), 0)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let discardedBytes = AgentHookInputDrainer.discard(fromFileDescriptor: readDescriptor)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000

        XCTAssertEqual(discardedBytes, Int64(body.count))
        XCTAssertLessThan(elapsedSeconds, 0.5)
    }

    func testSignalWriterClampsCountAndKeepsEveryProviderAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-hook-providers-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        for provider in AgentProvider.allCases {
            let signalURL = try AgentHookSignalWriter.write(
                rootDirectory: root,
                provider: provider,
                eventName: "unknown-event-containing-content",
                discardedPayloadBytes: Int64.max,
                processIdentifier: -1
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let signal = try decoder.decode(AgentHookSignal.self, from: Data(contentsOf: signalURL))
            XCTAssertEqual(signal.provider, provider)
            XCTAssertEqual(signal.eventName, "event")
            XCTAssertEqual(signal.processIdentifier, 0)
            XCTAssertEqual(
                signal.discardedPayloadBytes,
                Int64(AgentHookInputDrainer.maximumInputBytes)
            )
        }
        XCTAssertFalse(try storedUTF8(beneath: root).contains("unknown-event-containing-content"))
    }

    func testSignalWriterRepairsOwnerOnlyModesAndRejectsUnsafeSignalTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-hook-permissions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let signal = try AgentHookSignalWriter.write(
            rootDirectory: root,
            provider: .codex,
            eventName: "SessionStart",
            discardedPayloadBytes: 0,
            processIdentifier: 1
        )
        let signals = root.appendingPathComponent("signals", isDirectory: true)
        let lock = signals.appendingPathComponent(".writer.lock")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: signals.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lock.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: signal.path)

        _ = try AgentHookSignalWriter.write(
            rootDirectory: root,
            provider: .codex,
            eventName: "Stop",
            discardedPayloadBytes: 0,
            processIdentifier: 2
        )
        XCTAssertEqual(try permissions(signals), 0o700)
        XCTAssertEqual(try permissions(lock), 0o600)
        XCTAssertEqual(try permissions(signal), 0o600)

        let external = root.appendingPathComponent("external.json")
        let externalBytes = Data("external-must-not-change".utf8)
        try externalBytes.write(to: external)
        try FileManager.default.removeItem(at: signal)
        try FileManager.default.createSymbolicLink(at: signal, withDestinationURL: external)
        XCTAssertThrowsError(
            try AgentHookSignalWriter.write(
                rootDirectory: root,
                provider: .codex,
                eventName: "Stop",
                discardedPayloadBytes: 0,
                processIdentifier: 3
            )
        )
        XCTAssertEqual(try Data(contentsOf: external), externalBytes)
        XCTAssertTrue(try signal.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testSignalWriterFailsClosedWhenSignalsDirectoryCannotBeOpenedForRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-hook-chmod-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        let signals = root.appendingPathComponent("signals", isDirectory: true)
        try FileManager.default.createDirectory(at: signals, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: signals.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: signals.path)
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertThrowsError(
            try AgentHookSignalWriter.write(
                rootDirectory: root,
                provider: .claudeCode,
                eventName: "Stop",
                discardedPayloadBytes: 0,
                processIdentifier: 1
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: signals.appendingPathComponent("claudeCode.json").path))
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        return value.intValue & 0o777
    }

    private func storedUTF8(beneath root: URL) throws -> String {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        else { return "" }

        var stored = ""
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            stored += String(decoding: try Data(contentsOf: file), as: UTF8.self)
        }
        return stored
    }
}
