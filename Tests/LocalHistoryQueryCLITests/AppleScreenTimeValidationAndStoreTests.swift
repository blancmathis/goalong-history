import XCTest
import AppleScreenTime

/// An imported Screen Time file feeds the time totals the user sees: bad files must be refused, never half-stored.
final class AppleScreenTimeValidationAndStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func provenance() -> AppleScreenTimeProvenance {
        AppleScreenTimeProvenance(
            collectorBundleIdentifier: "test", collectorVersion: "1", collectorPlatform: "test",
            authorization: .unknown, fetchPolicy: .live, euCustomerRequirementAcknowledged: false)
    }

    private func segment(seconds: TimeInterval = 600, app: TimeInterval = 300) -> AppleScreenTimeSegment {
        AppleScreenTimeSegment(
            start: start, end: start.addingTimeInterval(seconds), totalScreenOnDuration: app,
            applications: [AppleScreenTimeApplicationUsage(bundleIdentifier: "com.example.work", displayName: "Work", duration: app)])
    }

    private func report(_ id: String = "mac", segments: [AppleScreenTimeSegment]? = nil) -> AppleScreenTimeDeviceReport {
        AppleScreenTimeDeviceReport(
            device: AppleScreenTimeDevice(id: id, name: "Mac \(id)", kind: .mac),
            lastUpdatedAt: start.addingTimeInterval(600), segments: segments ?? [segment()])
    }

    private func envelope(schema: Int = 1, span: TimeInterval = 86_400, reports: [AppleScreenTimeDeviceReport]? = nil) -> AppleScreenTimeExportEnvelope {
        AppleScreenTimeExportEnvelope(
            schemaVersion: schema, createdAt: start, requestedStart: start, requestedEnd: start.addingTimeInterval(span),
            requestedScope: .allDevices, provenance: provenance(), reports: reports ?? [report()])
    }

    private func message(_ envelope: AppleScreenTimeExportEnvelope) -> String {
        do { try AppleScreenTimeValidator.validate(envelope); return "valid" } catch { return "\(error)" }
    }

    private func makeStore() throws -> AppleScreenTimeStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-ast-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try AppleScreenTimeStore(rootDirectory: root)
    }

    func testValidEnvelopePasses() {
        XCTAssertEqual(message(envelope()), "valid")
    }

    func testUnknownSchemaAndBadRequestedIntervalsAreRefused() {
        XCTAssertEqual(message(envelope(schema: 2)), "Unsupported Apple Screen Time schema version: 2.")
        XCTAssertEqual(message(envelope(span: 0)), "The requested Screen Time interval is invalid.")
        XCTAssertEqual(message(envelope(span: 367 * 86_400)), "The Screen Time export covers an unexpectedly large interval.")
        XCTAssertEqual(message(envelope(span: 366 * 86_400)), "valid")
    }

    func testDeviceListIsBoundedAndIdentifiersMustBeUniqueAndNonEmpty() {
        let many = (0..<33).map { report("d\($0)") }
        XCTAssertEqual(message(envelope(reports: many)), "The Screen Time export contains too many devices.")
        XCTAssertEqual(message(envelope(reports: [report("same"), report("same")])), "The Screen Time export repeats device identifier same.")
    }

    func testZeroLengthSegmentAndOverlongApplicationTimeAreRefused() {
        let zero = AppleScreenTimeSegment(start: start, end: start, totalScreenOnDuration: 60)
        XCTAssertEqual(message(envelope(reports: [report(segments: [zero])])), "Device mac contains an invalid activity segment.")
        let tooLong = AppleScreenTimeSegment(
            start: start, end: start.addingTimeInterval(60), totalScreenOnDuration: 60,
            applications: [AppleScreenTimeApplicationUsage(bundleIdentifier: "a", displayName: "A", duration: 120)])
        XCTAssertEqual(message(envelope(reports: [report(segments: [tooLong])])), "Device mac contains an invalid application duration.")
        let atLimit = AppleScreenTimeSegment(
            start: start, end: start.addingTimeInterval(60), totalScreenOnDuration: 60,
            applications: [AppleScreenTimeApplicationUsage(bundleIdentifier: "a", displayName: "A", duration: 61)])
        XCTAssertEqual(message(envelope(reports: [report(segments: [atLimit])])), "valid")
    }

    func testSegmentCountPerDeviceIsBounded() {
        let one = segment(seconds: 60, app: 10)
        let many = Array(repeating: one, count: 10_001)
        XCTAssertEqual(message(envelope(reports: [report(segments: many)])), "Device mac contains too many activity segments.")
    }

    func testImportingGarbageIsRefusedAndStoresNothing() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.importExport(data: Data("not json".utf8))) { error in
            XCTAssertEqual("\(error)", "The selected file is not a valid Apple Screen Time export.")
        }
        XCTAssertTrue(store.storedExports().isEmpty)
    }

    func testImportingAnInvalidEnvelopeStoresNothing() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.importEnvelope(envelope(schema: 9), verification: .unsigned))
        XCTAssertTrue(store.storedExports().isEmpty)
    }

    func testImportRoundTripPicksTheNewestExportOverlappingADay() throws {
        let store = try makeStore()
        let data = try AppleScreenTimeJSON.encode(envelope())
        let stored = try store.importExport(data: data)
        XCTAssertEqual(stored.verification, .unsigned)
        XCTAssertEqual(store.storedExports().count, 1)
        let day = DateInterval(start: start, duration: 3600)
        XCTAssertEqual(store.newestExport(overlapping: day)?.envelope.reports.first?.device.id, "mac")
        XCTAssertNil(store.newestExport(overlapping: DateInterval(start: start.addingTimeInterval(10 * 86_400), duration: 3600)))
    }

    func testDeleteAllImportsRemovesOnlyImportedJSONAndReportsTheCount() throws {
        let store = try makeStore()
        try store.importEnvelope(envelope(), verification: .unsigned)
        try store.importEnvelope(envelope(), verification: .unsigned)
        let keep = store.snapshotsDirectory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: keep)
        XCTAssertEqual(try store.deleteAllImports(), 2)
        XCTAssertTrue(store.storedExports().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertEqual(try store.deleteAllImports(), 0)
    }

    func testCorruptedStoredFileIsIgnoredWhenListingExports() throws {
        let store = try makeStore()
        try store.importEnvelope(envelope(), verification: .unsigned)
        try Data("{broken".utf8).write(to: store.snapshotsDirectory.appendingPathComponent("corrupt.json"))
        XCTAssertEqual(store.storedExports().count, 1)
    }
}
