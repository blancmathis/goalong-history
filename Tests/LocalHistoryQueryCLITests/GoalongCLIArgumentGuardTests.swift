import XCTest
import LocalHistoryCore
@testable import LocalHistoryQueryCLI

/// A wrong command line must fail with a usage message before any data is read or printed.
final class GoalongCLIArgumentGuardTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-cli-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func failure(_ arguments: [String]) -> String {
        do { try GoalongQueryCLI.run(arguments: ["--root", root.path] + arguments); return "no error" }
        catch { return "\(error)" }
    }

    private func output(_ arguments: [String]) throws -> [String: Any] {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var thrown: Error?
        do { try GoalongQueryCLI.run(arguments: ["--root", root.path] + arguments) } catch { thrown = error }
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let thrown { throw thrown }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWebsitesRejectsOutOfRangePagingAndExtraArguments() {
        XCTAssertEqual(failure(["websites", "--limit", "0"]), "--limit must be between 1 and 1000")
        XCTAssertEqual(failure(["websites", "--limit", "1001"]), "--limit must be between 1 and 1000")
        XCTAssertEqual(failure(["websites", "--offset", "50001"]), "--offset must be between 0 and 50000")
        XCTAssertEqual(failure(["websites", "--offset", "-1"]), "--offset must be between 0 and 50000")
        XCTAssertTrue(failure(["websites", "today", "extra"]).hasPrefix("websites accepts one date"))
        XCTAssertEqual(failure(["websites", "--limit", "abc"]), "Invalid integer: abc")
    }

    func testAIConversationsRejectsOutOfRangeBudgetLimitAndOffset() {
        XCTAssertEqual(failure(["ai-conversations", "--tokens", "2047"]), "--tokens must be between 2048 and 100000")
        XCTAssertEqual(failure(["ai-conversations", "--tokens", "100001"]), "--tokens must be between 2048 and 100000")
        XCTAssertEqual(failure(["ai-conversations", "--limit", "0"]), "--limit must be between 1 and 256")
        XCTAssertEqual(failure(["ai-conversations", "--limit", "257"]), "--limit must be between 1 and 256")
        XCTAssertEqual(failure(["ai-conversations", "--offset", "50001"]), "--offset must be between 0 and 50000")
        XCTAssertTrue(failure(["ai-conversations", "today", "again"]).hasPrefix("ai-conversations accepts one date"))
    }

    func testScreenTimeRejectsConflictingOrTooManyDeviceSelections() {
        XCTAssertEqual(failure(["screen-time", "--mac-only", "--devices", "a"]), "Use either --mac-only or --devices, not both")
        let many = (1...33).map(String.init).joined(separator: ",")
        XCTAssertEqual(failure(["screen-time", "--devices", many]), "--devices accepts at most 32 comma-separated device IDs")
        XCTAssertTrue(failure(["screen-time", "today", "yesterday"]).hasPrefix("screen-time accepts one date"))
    }

    func testActivityRejectsBadPagingMissingIdentifierAndExtraArguments() {
        XCTAssertEqual(failure(["activity", "--limit", "0", "abc"]), "activity requires --limit 1...500 and --offset >= 0")
        XCTAssertEqual(failure(["activity", "--limit", "501", "abc"]), "activity requires --limit 1...500 and --offset >= 0")
        XCTAssertEqual(failure(["activity", "--offset", "-1", "abc"]), "activity requires --limit 1...500 and --offset >= 0")
        XCTAssertEqual(failure(["activity"]), "activity requires an activity ID")
        XCTAssertTrue(failure(["activity", "abc", "today", "extra"]).hasPrefix("activity accepts an activity ID"))
    }

    func testSimpleCommandsRejectStrayArgumentsAndUnknownCommands() {
        XCTAssertEqual(failure(["days", "x"]), "days does not accept arguments")
        XCTAssertEqual(failure(["recaps", "x"]), "recaps does not accept arguments")
        XCTAssertEqual(failure(["memories", "x"]), "memories does not accept arguments")
        XCTAssertEqual(failure(["status", "x"]), "status does not accept arguments")
        XCTAssertEqual(failure(["sources"]), "sources requires one memory ID")
        XCTAssertEqual(failure(["sources", "a", "b"]), "sources requires one memory ID")
        XCTAssertEqual(failure(["search"]), "search requires a query")
        XCTAssertEqual(failure(["site"]), "site requires a query")
        XCTAssertEqual(failure(["ask"]), "ask requires a natural-language question")
        XCTAssertEqual(failure(["frobnicate"]), "Unknown command: frobnicate")
        XCTAssertEqual(failure(["health", "today", "x"]), "Use health [today|yesterday|YYYY-MM-DD].")
        do { try GoalongQueryCLI.run(arguments: []); XCTFail("expected an error") }
        catch { XCTAssertEqual("\(error)", "Missing command") }
    }

    func testEmptyHistoryStillAnswersMemoriesAndUnknownSourcesWithJSON() throws {
        let memories = try output(["memories"])
        XCTAssertEqual(((memories["result"] as? [String: Any])?["hits"] as? [Any])?.count, 0)
        let sources = try output(["sources", "no-such-memory"])
        let limitations = (sources["result"] as? [String: Any])?["limitations"] as? [String] ?? []
        XCTAssertTrue(limitations.contains("No memory with that identifier was loaded."))
    }
}
