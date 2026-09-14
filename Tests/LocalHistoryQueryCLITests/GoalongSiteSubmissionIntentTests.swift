#if os(macOS)
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryQueryCLI

final class GoalongSiteSubmissionIntentTests: XCTestCase {
    func testReturningToAnEarlierSelectionCreatesANewOperation() throws {
        let endpoint = try GoalongSiteSubmission.endpoint(origin: "https://example.invalid")
        let a = Data("selection-a".utf8), b = Data("selection-b".utf8)
        let requests = [a, b, a].map {
            GoalongSiteSubmission.requestForNewSubmission(payload: $0, endpoint: endpoint, token: "synthetic-only")
        }
        let keys = try requests.map { try XCTUnwrap($0.value(forHTTPHeaderField: "Idempotency-Key")) }
        XCTAssertEqual(Set(keys).count, 3, "A new approval of A after B must not replay the first A's receipt")
        for (index, payload) in [a, b, a].enumerated() {
            XCTAssertEqual(requests[index].httpBody, payload)
            XCTAssertEqual(requests[index].url, endpoint)
            XCTAssertEqual(requests[index].httpMethod, "POST")
            XCTAssertTrue(keys[index].hasSuffix(SHA256Digest.hashHex(payload)))
            XCTAssertLessThanOrEqual(keys[index].count, 128)
            XCTAssertNotNil(keys[index].range(of: "^[A-Za-z0-9_.:-]{8,128}$", options: .regularExpression))
            XCTAssertFalse(keys[index].contains("synthetic-only"))
        }
    }

    func testAnExplicitRetryRetainsItsOriginalOperationAndBytes() throws {
        let endpoint = try GoalongSiteSubmission.endpoint(origin: "https://example.invalid")
        let payload = Data("reviewed-selection".utf8)
        let original = GoalongSiteSubmission.requestForNewSubmission(payload: payload, endpoint: endpoint, token: "synthetic-only")
        let key = try XCTUnwrap(original.value(forHTTPHeaderField: "Idempotency-Key"))
        let retry = GoalongSiteSubmission.request(payload: payload, endpoint: endpoint, token: "synthetic-only", idempotencyKey: key)
        XCTAssertEqual(retry.value(forHTTPHeaderField: "Idempotency-Key"), key)
        XCTAssertEqual(retry.httpBody, original.httpBody)
        XCTAssertEqual(retry.url, original.url)
        // This is only request construction; no retry loop or network operation is started.
    }

    func testProductionSendUsesTheNewIntentBuilder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Sources/LocalHistoryQueryCLI/GoalongSiteSubmission.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("session.dataTask(with: requestForNewSubmission(payload: payload, endpoint: destination, token: token)).resume()"))
        XCTAssertFalse(source.contains("session.dataTask(with: request(payload:"))
    }
}
#endif
