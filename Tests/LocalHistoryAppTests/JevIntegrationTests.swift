#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class JevIntegrationTests: XCTestCase {
    private func event(_ kind: EventKind = .typingBurst, host: String = "x.com", path: String = "/home",
                       role: String = "AXTextArea", label: String = "Post text", secure: Bool = false,
                       suppressed: SuppressionReason? = nil) -> HistoryEvent {
        HistoryEvent(sessionID: "jev-test", kind: kind,
            app: AppSnapshot(name: "Browser", bundleIdentifier: "test.browser", processIdentifier: 1),
            window: WindowSnapshot(title: "Test", role: nil, subrole: nil),
            element: ElementSnapshot(role: role, subrole: nil, title: nil, label: label,
                                     identifier: nil, isSecure: secure),
            url: URLSnapshot(value: "https://\(host)\(path)?secret=not-for-model", host: host, redactionApplied: true),
            suppressionReason: suppressed)
    }
    func testComposerIsNotAFeedAndSearchIsNotComposer() throws {
        XCTAssertEqual(JevIngress.sample(event())?.surface, "composing")
        XCTAssertEqual(JevIngress.sample(event(label: "Search"))?.surface, "social-search")
        XCTAssertEqual(JevIngress.sample(event(role: "AXSearchField", label: "Post text"))?.surface, "social-search")
        XCTAssertEqual(JevIngress.sample(event(.scrollBurst, role: "AXWebArea", label: ""))?.surface, "social-feed")
        XCTAssertEqual(JevIngress.sample(event(label: "Unknown text"))?.surface, "editing-unknown")
        XCTAssertEqual(JevIngress.sample(event(path: "/compose/post", label: ""))?.surface, "composing")
        let sample = try XCTUnwrap(JevIngress.sample(event()))
        XCTAssertEqual(sample.resource, "x.com")
        XCTAssertFalse(sample.title.contains("secret"))
    }
    func testMediaHostMatchingDoesNotAcceptSpoofedHost() {
        XCTAssertTrue(JevIngress.isMedia("www.youtube.com"))
        XCTAssertFalse(JevIngress.isMedia("youtube.com.evil.example"))
        XCTAssertTrue(JevIngress.isSocial("mobile.x.com"))
        XCTAssertFalse(JevIngress.isSocial("notx.com"))
    }
    func testSuppressionAndSecureElementsNeverBecomeEvidence() {
        XCTAssertNil(JevIngress.sample(event(secure: true)))
        XCTAssertNil(JevIngress.sample(event(suppressed: .privateBrowserWindow)))
        XCTAssertNil(JevIngress.sample(event(.heartbeat)))
    }
    func testTextIsByteBoundedAndDoesNotExposeURLOrEmail() {
        let value = JevIngress.redactedText("Email person@example.com https://example.com/private?q=secret password: hello", limit: 96)
        XCTAssertLessThanOrEqual(value.utf8.count, 96)
        XCTAssertFalse(value.contains("person@example.com"))
        XCTAssertFalse(value.contains("example.com"))
        XCTAssertFalse(value.contains("hello"))
    }
    func testIngressDisabledAndPrivacyRevisionChanges() {
        let inbox = JevIngress()
        let now = Date()
        XCTAssertNil(inbox.take(start: now, end: now.addingTimeInterval(15)))
        inbox.configure(enabled: true, now: now)
        let initial = inbox.generation
        inbox.setPrivateWindow(true)
        XCTAssertGreaterThan(inbox.generation, initial)
        XCTAssertTrue(inbox.isBlocked)
        XCTAssertNil(inbox.take(start: now, end: now.addingTimeInterval(15)))
        // Reconfiguration cannot accidentally permit private browsing that is locally authorized.
        inbox.configure(enabled: true, now: now)
        XCTAssertNil(inbox.take(start: now, end: now.addingTimeInterval(15)))
        inbox.setPrivateWindow(false)
        XCTAssertNotNil(inbox.take(start: now, end: now.addingTimeInterval(15)))
        inbox.configure(enabled: false)
        XCTAssertNil(inbox.take(start: now, end: now.addingTimeInterval(15)))
    }
    func testCredentialsOwnerOnlyAtomicAndTraversalRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try JevLocalFiles.read("api-key", root: root))
        try JevLocalFiles.write(Data("synthetic-key-only".utf8), name: "api-key", root: root)
        XCTAssertEqual(try JevLocalFiles.read("api-key", root: root), Data("synthetic-key-only".utf8))
        let file = root.appendingPathComponent("jev/api-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try JevLocalFiles.write(Data(), name: "../escape", root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try JevLocalFiles.read("api-key", root: root))
        try JevLocalFiles.write(nil, name: "api-key", root: root)
        XCTAssertNil(try JevLocalFiles.read("api-key", root: root))
    }
    func testCredentialsSymlinkRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try JevLocalFiles.write(Data("unchanged".utf8), name: "break.json", root: root)
        let file = root.appendingPathComponent("jev/api-key")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("jev/break.json"))
        XCTAssertThrowsError(try JevLocalFiles.read("api-key", root: root))
        try JevLocalFiles.write(Data("synthetic-key".utf8), name: "api-key", root: root)
        XCTAssertEqual(try JevLocalFiles.read("break.json", root: root), Data("unchanged".utf8))
    }
    func testSeparateConsentDefaultsOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consent.json"))
        XCTAssertFalse(store.isEnabled(.jevMonitoring))
        XCTAssertTrue(store.set(.localComputerHistory, enabled: true, surface: .settings))
        XCTAssertFalse(store.isEnabled(.jevMonitoring))
        XCTAssertTrue(store.set(.jevMonitoring, enabled: true, surface: .settings))
        XCTAssertTrue(store.isEnabled(.jevMonitoring))
        XCTAssertFalse(store.isEnabled(.chatGPTAnalysis))
    }
}

/// No live key, network or personal history is used in transport fixtures.
private final class JevFixtureProtocol: URLProtocol {
    static let fixtureLock = NSLock()
    static var status = 200
    static var data = Data()
    static var headers: [String: String] = [:]
    static var observed: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.fixtureLock.lock()
        Self.observed = request
        let code = Self.status, body = Self.data, headers = Self.headers
        Self.fixtureLock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class JevTransportTests: XCTestCase {
    private func fixture(status: Int = 200, data: Data? = nil, headers: [String: String] = ["Content-Type": "application/json"]) -> JevTransport {
        JevFixtureProtocol.fixtureLock.lock()
        JevFixtureProtocol.status = status; JevFixtureProtocol.headers = headers
        JevFixtureProtocol.data = data ?? Data("""
        {"model":"jev-1.13.0","answers":{"activity":{"type":"choice","choice":"productive","probabilities":{"productive":0.9,"procrastination":0.05,"unknown":0.05},"confidence":0.7}},"usage":{"input_tokens":215}}
        """.utf8)
        JevFixtureProtocol.observed = nil
        JevFixtureProtocol.fixtureLock.unlock()
        return JevTransport(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [JevFixtureProtocol.self]
            return configuration
        })
    }
    func testPinnedEndpointAuthenticationAndResponse() async throws {
        let client = fixture()
        let value = try await client.classify(body: Data("{}".utf8), key: "synthetic-key")
        XCTAssertEqual(value.verdict, .productive)
        XCTAssertEqual(value.inputTokens, 215)
        XCTAssertEqual(JevFixtureProtocol.observed?.url, JevTransport.endpoint)
        XCTAssertEqual(JevFixtureProtocol.observed?.httpMethod, "POST")
        XCTAssertEqual(JevFixtureProtocol.observed?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
    }
    func testHTTPErrorAndRateLimitDoNotBecomeClassifications() async throws {
        for (status, expected) in [(401, JevError.authentication), (403, .authentication), (429, .rateLimited(27)), (503, .http(503))] {
            let client = fixture(status: status, headers: ["Retry-After": "27"])
            do { _ = try await client.classify(body: Data(), key: "synthetic-key"); XCTFail("HTTP error accepted") }
            catch { XCTAssertEqual(error as? JevError, expected) }
        }
    }
    func testNonFiniteRetryAfterAndResponseBound() async throws {
        let rate = fixture(status: 429, headers: ["Retry-After": "nan"])
        do { _ = try await rate.classify(body: Data(), key: "synthetic-key"); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? JevError, .rateLimited(60)) }
        let large = fixture(data: Data(repeating: 65, count: 65_537))
        do { _ = try await large.classify(body: Data(), key: "synthetic-key"); XCTFail("Expected bounded rejection") }
        catch { XCTAssertEqual(error as? JevError, .invalidResponse) }
    }
    func testContentTypeAndInvalidBodyFailClosed() async throws {
        for headers in [["Content-Type": "text/html"], ["Content-Type": "application/json"]] {
            let client = fixture(data: Data("not a classification".utf8), headers: headers)
            do { _ = try await client.classify(body: Data(), key: "synthetic-key"); XCTFail("Malformed response accepted") }
            catch { XCTAssertEqual(error as? JevError, .invalidResponse) }
        }
    }
    func testOverBudgetAndPreCancelledNeverStartNetwork() async throws {
        let client = fixture()
        do { _ = try await client.classify(body: Data(repeating: 65, count: 801), key: "synthetic-key"); XCTFail("Over budget accepted") }
        catch { XCTAssertEqual(error as? JevError, .budget) }
        XCTAssertNil(JevFixtureProtocol.observed)
        client.cancel()
        do { _ = try await client.classify(body: Data(), key: "synthetic-key"); XCTFail("Cancelled request accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(JevFixtureProtocol.observed)
    }
}
#endif
