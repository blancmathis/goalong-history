#if os(macOS)
import Darwin
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class SelectedSiteAnalysisTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBufferPointer { pointer in
            path.withCString { Darwin.realpath($0, pointer.baseAddress) }
        }
        guard resolved != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let url = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .appendingPathComponent("goalong-selected-analysis-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func selectedData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema": "goalong.analysis-request.v1",
            "requestId": "11111111-2222-4333-8444-555555555555",
            "date": "2026-09-07", "timezone": "Europe/Paris",
            "question": "Explain only these selected observations.",
            "data": ["totals": [["device": "SELECTED_PHONE", "kind": "phone",
                                    "source": "apple-screen-time", "seconds": 3600]]],
        ], options: [.sortedKeys])
    }

    private func draftObject() -> [String: Any] {
        ["title": "Selected observations", "summary": "The supplied device total is one hour.",
         "outcomes": ["Other sources were not supplied."]]
    }

    private func finalEvents(output: [String: Any]? = nil, turnID: String = "turn-1",
                             completionItems: [[String: Any]] = []) throws -> [[String: Any]] {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: output ?? draftObject()), as: UTF8.self)
        return [
            ["method": "item/completed", "params": ["threadId": "thread-1", "turnId": turnID,
                 "item": ["type": "agentMessage", "phase": "final_answer", "text": text]]],
            ["method": "turn/completed", "params": ["threadId": "thread-1",
                 "turn": ["id": turnID, "status": "completed", "items": completionItems]]],
        ]
    }

    /// A real stdio process with canned protocol messages; it never invokes Codex or a provider.
    private struct Fixture {
        let root: URL
        let home: URL
        let workspace: URL
        let executable: URL
        let transcript: URL

        init(root: URL, account: String = "chatgpt", profile: String = "goalong-site-analysis",
             rootOverride: String? = nil, ephemeral: Bool = true,
             startItems: [[String: Any]] = [], dynamicWorkspace: Bool = false,
             events: [[String: Any]]) throws {
            self.root = root
            home = root.appendingPathComponent("isolated-codex-home", isDirectory: true)
            workspace = root.appendingPathComponent("empty-workspace", isDirectory: true)
            executable = root.appendingPathComponent("codex-fixture")
            transcript = root.appendingPathComponent("requests.jsonl")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            func emit(_ value: [String: Any]) throws -> String {
                "printf '%s\\n' " + quote(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
            }
            var lines = ["#!/bin/sh", "set -eu",
                "take() { IFS= read -r line || exit 0; printf '%s\\n' \"$line\" >> \(quote(transcript.path)); }",
                "take", try emit(["id": 1, "result": ["codexHome": home.path]]), "take", "take",
                try emit(["id": 2, "result": ["account": ["type": account, "planType": "plus"]]]),
                "take", try emit(["id": 3, "result": ["data": [["id": "luna", "model": "gpt-5.6-luna",
                    "displayName": "GPT-5.6 Luna", "description": "fixture", "hidden": false,
                    "isDefault": false, "defaultReasoningEffort": "medium",
                    "supportedReasoningEfforts": [["reasoningEffort": "high", "description": "High"]]]],
                    "nextCursor": NSNull()]]),
                "take",
            ]
            if dynamicWorkspace {
                lines.append("confirmed_cwd=$(printf '%s' \"$line\" | /usr/bin/plutil -extract params.cwd raw -o - -)")
            }
            let confirmation = try emit(["id": 4, "result": ["thread": ["id": "thread-1", "ephemeral": ephemeral],
                    "model": "gpt-5.6-luna", "reasoningEffort": "high",
                    "activePermissionProfile": ["id": profile], "cwd": dynamicWorkspace ? "CONFIRMED_WORKSPACE" : workspace.path,
                    "runtimeWorkspaceRoots": [rootOverride ?? (dynamicWorkspace ? "CONFIRMED_WORKSPACE" : workspace.path)]]])
            lines += [dynamicWorkspace ? confirmation.replacingOccurrences(of: "CONFIRMED_WORKSPACE", with: "'\"$confirmed_cwd\"'") : confirmation,
                "take", try emit(["id": 5, "result": ephemeral
                    ? ["turn": ["id": "turn-1", "status": "inProgress", "items": startItems]] : [:]]),
            ]
            if ephemeral { lines += try events.map(emit) }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func session(isolated: Bool = true) throws -> CodexAppServerSession {
            try CodexAppServerSession(executableURL: executable, codexHomeURL: home, siteAnalysisOnly: isolated)
        }

        func requests() throws -> [[String: Any]] {
            guard FileManager.default.fileExists(atPath: transcript.path) else { return [] }
            return try Data(contentsOf: transcript).split(separator: 10).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
        }
    }

    func testSessionSendsOnlyImmutableSelectedPromptAndPinsRestrictedTurn() throws {
        let fixture = try Fixture(root: directory(), events: finalEvents())
        let file = fixture.root.appendingPathComponent("selected.json")
        try selectedData().write(to: file)
        let selected = try GoalongSiteAnalysisRequest.readSelectedFile(file)
        try Data("UNSELECTED_CHANGED_FILE_CANARY".utf8).write(to: file)
        try Data("UNSELECTED_SIBLING_CANARY".utf8).write(to: fixture.root.appendingPathComponent("history.json"))
        let session = try fixture.session()
        defer { session.close() }
        let draft = try session.generateSiteAnalysis(request: selected, workingDirectory: fixture.workspace)
        XCTAssertEqual(draft.title, "Selected observations")
        let requests = try fixture.requests()
        let thread = try XCTUnwrap(requests.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        let turn = try XCTUnwrap(requests.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        let input = try XCTUnwrap(turn["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["text"] as? String, selected.analysisPrompt)
        let wire = String(decoding: try Data(contentsOf: fixture.transcript), as: UTF8.self)
        XCTAssertFalse(wire.contains("UNSELECTED_CHANGED_FILE_CANARY"))
        XCTAssertFalse(wire.contains("UNSELECTED_SIBLING_CANARY"))
        XCTAssertEqual(thread["permissions"] as? String, "goalong-site-analysis")
        XCTAssertEqual(thread["approvalPolicy"] as? String, "never")
        XCTAssertEqual(thread["ephemeral"] as? Bool, true)
        XCTAssertEqual((thread["dynamicTools"] as? [Any])?.count, 0)
        XCTAssertEqual((thread["environments"] as? [Any])?.count, 0)
        XCTAssertEqual(thread["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual((thread["config"] as? [String: Any])?["model_reasoning_effort"] as? String, "high")
        XCTAssertEqual(turn["permissions"] as? String, "goalong-site-analysis")
        XCTAssertEqual((turn["outputSchema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.siteImport(for: selected)) as? [String: Any])
        let day = try XCTUnwrap((exported["days"] as? [[String: Any]])?.first)
        XCTAssertEqual(exported["source"] as? String, "chatgpt")
        XCTAssertEqual(day["date"] as? String, selected.date)
        XCTAssertTrue(day["activeMinutes"] is NSNull)
        XCTAssertEqual(day["coverage"] as? String, "unknown")
        XCTAssertEqual((day["activities"] as? [Any])?.count, 0)
        XCTAssertNil(day["telemetry"])
        XCTAssertNil(day["verified"])
    }

    func testNonChatGPTAccountRefusesBeforeModelThreadOrTurn() throws {
        let fixture = try Fixture(root: directory(), account: "apiKey", events: [])
        let session = try fixture.session()
        defer { session.close() }
        XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace)) {
            guard case CodexAppServerError.accountNotChatGPT = $0 else { return XCTFail("Expected account rejection: \($0)") }
        }
        XCTAssertEqual(try fixture.requests().compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/read"])
    }

    func testOrdinaryRecapSessionCannotAnalyzeSiteSelection() throws {
        let fixture = try Fixture(root: directory(), events: [])
        let session = try fixture.session(isolated: false)
        defer { session.close() }
        XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace))
        XCTAssertFalse(try fixture.requests().contains { $0["method"] as? String == "account/read" })
    }

    func testUnexpectedProfileOrWorkspaceRootRefusesBeforeTurn() throws {
        for wrongProfile in [true, false] {
            let fixture = try Fixture(root: directory(), profile: wrongProfile ? "goalong-recap" : "goalong-site-analysis",
                                      rootOverride: wrongProfile ? nil : "/", events: [])
            let session = try fixture.session()
            defer { session.close() }
            XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace))
            XCTAssertFalse(try fixture.requests().contains { $0["method"] as? String == "turn/start" })
        }
    }

    func testPersistentThreadIsDeletedWithoutSendingSelection() throws {
        let fixture = try Fixture(root: directory(), ephemeral: false, events: [])
        let session = try fixture.session()
        defer { session.close() }
        XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace))
        let methods = try fixture.requests().compactMap { $0["method"] as? String }
        XCTAssertTrue(methods.contains("thread/delete"))
        XCTAssertFalse(methods.contains("turn/start"))
    }

    func testNonemptyWorkspaceIsRejectedBeforeAccountRead() throws {
        let fixture = try Fixture(root: directory(), events: [])
        try Data("unselected".utf8).write(to: fixture.workspace.appendingPathComponent("unexpected.txt"))
        let session = try fixture.session()
        defer { session.close() }
        XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace))
        XCTAssertFalse(try fixture.requests().contains { $0["method"] as? String == "account/read" })
    }

    func testToolItemsAndServerApprovalRequestsRejectCompleteDraft() throws {
        let forbidden: [[String: Any]] = [
            ["method": "item/started", "params": ["item": ["type": "commandExecution"]]],
            ["method": "item/completed", "params": ["item": ["type": "mcpToolCall"]]],
            ["method": "item/fileChange/outputDelta", "params": ["delta": "unexpected"]],
            ["id": 99, "method": "item/commandExecution/requestApproval", "params": [:]],
        ]
        for message in forbidden {
            let fixture = try Fixture(root: directory(), events: [message] + finalEvents())
            let session = try fixture.session()
            defer { session.close() }
            XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace), "Unexpected capability: \(message["method"] ?? "")")
        }
    }

    func testToolItemsInsideTurnResponsesAreAlsoRejected() throws {
        for inStart in [true, false] {
            let tools: [[String: Any]] = [["type": "commandExecution", "id": "hidden-tool"]]
            let fixture = try Fixture(root: directory(), startItems: inStart ? tools : [],
                                      events: finalEvents(completionItems: inStart ? [] : tools))
            let session = try fixture.session()
            defer { session.close() }
            XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace), "Tool present only in \(inStart ? "start" : "completion") response")
        }
    }

    func testOtherTurnCannotSupplyTheFinalDraft() throws {
        let fixture = try Fixture(root: directory(), events: finalEvents(turnID: "unrelated-turn"))
        let session = try fixture.session()
        defer { session.close() }
        XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace))
    }

    func testModelOutputCannotIntroduceMeasurements() throws {
        var output = draftObject()
        output["metrics"] = ["screenSeconds": 7200]
        let fixture = try Fixture(root: directory(), events: finalEvents(output: output))
        let session = try fixture.session()
        defer { session.close() }
        XCTAssertThrowsError(try session.generateSiteAnalysis(request: GoalongSiteAnalysisRequest.parse(selectedData()), workingDirectory: fixture.workspace))
    }

    func testExportIsPrivateAndLeavesParentPermissionsUnchanged() throws {
        let parent = try directory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        let destination = parent.appendingPathComponent("reviewed.json")
        try Data("old file".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        let bytes = try GoalongSiteAnalysisDraft(title: "Reviewed", summary: "Only text", outcomes: [])
            .siteImport(for: GoalongSiteAnalysisRequest.parse(selectedData()))
        try GoalongSiteAnalysisExportWriter.write(bytes, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try permissions(destination), 0o600)
        XCTAssertEqual(try permissions(parent), 0o755)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["reviewed.json"])
    }

    func testExportRejectsSymlinkWithoutChangingTargetOrParent() throws {
        let parent = try directory()
        let target = parent.appendingPathComponent("unrelated.txt")
        let destination = parent.appendingPathComponent("reviewed.json")
        try Data("PRESERVE_TARGET".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        let parentMode = try permissions(parent)
        XCTAssertThrowsError(try GoalongSiteAnalysisExportWriter.write(Data("replacement".utf8), to: destination))
        XCTAssertEqual(try String(contentsOf: target), "PRESERVE_TARGET")
        XCTAssertEqual(try permissions(target), 0o644)
        XCTAssertEqual(try permissions(parent), parentMode)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".goalong-export-") })
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 4) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "The isolated asynchronous operation did not complete.")
    }

    @MainActor
    func testModelRequiresConsentAndReviewedSelectionBeforeCreatingAnalysisSession() async throws {
        let connectFixture = try Fixture(root: directory(), events: finalEvents())
        let analysisFixture = try Fixture(root: directory(), dynamicWorkspace: true, events: finalEvents())
        var allowed = false
        var calls = 0
        let model = GoalongSiteAnalysisModel(consent: { allowed }, makeSession: {
            calls += 1
            return try (calls == 1 ? connectFixture : analysisFixture).session()
        })
        defer { model.cancel() }
        model.connect()
        model.analyze()
        XCTAssertEqual(calls, 0)
        XCTAssertThrowsError(try model.reviewedExport())
        let file = connectFixture.root.appendingPathComponent("selection.json")
        try selectedData().write(to: file)
        model.load(file)
        try await waitFor { !model.busy }
        XCTAssertNotNil(model.request)
        allowed = true
        model.reviewed = true
        model.analyze()
        XCTAssertEqual(calls, 0, "A selected file and consent do not substitute for a connected account.")
        model.connect()
        try await waitFor { !model.busy }
        XCTAssertTrue(model.connected)
        XCTAssertEqual(calls, 1)
        model.reviewed = false
        model.analyze()
        XCTAssertEqual(calls, 1)
        model.reviewed = true
        allowed = false
        model.analyze()
        XCTAssertEqual(calls, 1)
        allowed = true
        model.analyze()
        try await waitFor { !model.busy }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(model.hasDraft)
        XCTAssertFalse(model.reviewed, "Permission for a completed operation must not authorize another turn.")
        model.title = "My reviewed title"
        let export = try XCTUnwrap(JSONSerialization.jsonObject(with: model.reviewedExport()) as? [String: Any])
        XCTAssertEqual((export["days"] as? [[String: Any]])?.first?["title"] as? String, "My reviewed title")
    }

    @MainActor
    func testCancellationWhileFactoryIsStartingCannotAttachOrRestoreState() async throws {
        let fixture = try Fixture(root: directory(), events: [])
        let entered = expectation(description: "Factory entered")
        let returned = expectation(description: "Factory returned")
        let gate = DispatchSemaphore(value: 0)
        let model = GoalongSiteAnalysisModel(consent: { true }, makeSession: {
            entered.fulfill()
            guard gate.wait(timeout: .now() + 3) == .success else { throw CodexAppServerError.timeout("test factory gate") }
            let session = try fixture.session()
            returned.fulfill()
            return session
        })
        defer { gate.signal(); model.cancel() }
        model.connect()
        await fulfillment(of: [entered], timeout: 2)
        model.cancel()
        gate.signal()
        await fulfillment(of: [returned], timeout: 3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.hasDraft)
        XCTAssertNil(model.error)
        XCTAssertFalse(try fixture.requests().contains { $0["method"] as? String == "account/read" })
    }

    func testOptInInstalledCodexSandboxConfinesSelectedAnalysisWithoutAnAccount() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_SITE_SANDBOX_CODEX"], !path.isEmpty else {
            throw XCTSkip("Set GOALONG_SITE_SANDBOX_CODEX to run only the installed local sandbox, without login or a model.")
        }
        let root = try directory()
        let home = root.appendingPathComponent("isolated-codex-home", isDirectory: true)
        let workspace = root.appendingPathComponent("empty-workspace", isDirectory: true)
        let canary = root.appendingPathComponent("outside-canary.txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        try Data("PRIVATE_OUTSIDE_CANARY".utf8).write(to: canary)
        try CodexAppServerSession.prepareCodexHome(at: home, siteAnalysisOnly: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        let stdout = Pipe(), stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["sandbox", "-P", "goalong-site-analysis", "-C", workspace.path,
            "/bin/sh", "-c", """
            printf 'RUNTIME_OK\n'
            if /bin/cat "$1"; then printf 'OUTSIDE_READ_ALLOWED\n'; exit 41; fi
            if (printf 'forbidden' > "$2/forbidden-write"); then printf 'WORKSPACE_WRITE_ALLOWED\n'; exit 42; fi
            printf 'BOUNDARIES_OK\n'
            """, "goalong-sandbox-fixture", canary.path, workspace.path]
        process.environment = CodexAppServerSession.codexEnvironment(inheriting: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], codexHomeURL: home)
        process.standardOutput = stdout
        process.standardError = stderr
        let completed = expectation(description: "Local sandbox exited")
        process.terminationHandler = { _ in completed.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        wait(for: [completed], timeout: 20)
        guard !process.isRunning else { return XCTFail("Installed sandbox did not complete within 20 seconds.") }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, String(error.prefix(2000)))
        XCTAssertTrue(output.contains("RUNTIME_OK"))
        XCTAssertTrue(output.contains("BOUNDARIES_OK"))
        XCTAssertFalse(output.contains("PRIVATE_OUTSIDE_CANARY"))
        XCTAssertFalse(output.contains("OUTSIDE_READ_ALLOWED"))
        XCTAssertFalse(output.contains("WORKSPACE_WRITE_ALLOWED"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("forbidden-write").path))
        XCTAssertEqual(try String(contentsOf: canary), "PRIVATE_OUTSIDE_CANARY")
    }
}
#endif
