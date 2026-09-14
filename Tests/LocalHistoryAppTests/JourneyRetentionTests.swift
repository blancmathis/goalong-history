#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class JourneyRetentionTests: XCTestCase {
    private func fixture() throws -> (HistoryRetentionStore, HistoryRetentionStorage, [HistoryDataClass: URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-journey-retention-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var files: [HistoryDataClass: URL] = [:]
        var definitions: [HistoryRetentionArtifactDirectory] = []
        for kind in HistoryDataClass.allCases {
            let directory = root.appendingPathComponent(kind.rawValue)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("2020-01-01.fixture")
            try Data("synthetic-local-artifact".utf8).write(to: file)
            files[kind] = file
            definitions.append(HistoryRetentionArtifactDirectory(directory: directory, dataClass: kind, allowedSuffixes: [".fixture"]))
        }
        let storage = HistoryRetentionStorage(policyFile: root.appendingPathComponent("policy.json"),
            activationFile: root.appendingPathComponent("activation.json"), artifactDirectories: definitions, prepare: {})
        return (HistoryRetentionStore(legacyRetentionDays: 30, storage: storage), storage, files)
    }
    func testOpeningOrSavingAPolicyNeverAuthorizesDeletion() throws {
        let (store, storage, files) = try fixture()
        XCTAssertFalse(store.isAutomaticCleanupEnabled)
        var draft = store.policy
        for kind in HistoryDataClass.allCases { draft.setDuration(RetentionDuration(days: 1), for: kind) }
        try store.save(draft)
        store.applyCleanup()
        let reopened = HistoryRetentionStore(legacyRetentionDays: 30, storage: storage)
        reopened.applyCleanup()
        XCTAssertFalse(reopened.isAutomaticCleanupEnabled)
        for file in files.values { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }
    func testExplicitActivationOnlyExpiresTheChosenClasses() throws {
        let (store, _, files) = try fixture()
        var draft = store.policy
        for kind in HistoryDataClass.allCases { draft.setDuration(.indefinite, for: kind) }
        draft.detailedEvents = RetentionDuration(days: 7)
        draft.memories = RetentionDuration(days: 30)
        try store.activate(draft)
        XCTAssertTrue(store.isAutomaticCleanupEnabled)
        store.applyCleanup()
        for (kind, file) in files {
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), ![.detailedEvents, .memories].contains(kind), kind.rawValue)
        }
    }
    func testDeactivationPersistsAcrossRestartAndPreservesEveryArtifact() throws {
        let (store, storage, files) = try fixture()
        try store.activate(store.policy)
        XCTAssertTrue(store.isAutomaticCleanupEnabled)
        try store.save(store.policy)
        let reopened = HistoryRetentionStore(legacyRetentionDays: 30, storage: storage)
        XCTAssertFalse(reopened.isAutomaticCleanupEnabled)
        reopened.applyCleanup()
        for file in files.values { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }
    @MainActor func testProofDeletionRequiresASecondIndependentConfirmation() throws {
        let (store, _, files) = try fixture()
        let model = HistoryRetentionSettingsModel(store: store)
        model.automaticCleanup = true
        model.draft.minuteSeals = RetentionDuration(days: 1)
        XCTAssertFalse(model.apply(proofDeletionConfirmed: false))
        XCTAssertFalse(store.isAutomaticCleanupEnabled)
        store.applyCleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[.minuteSeals]!.path))
        XCTAssertTrue(model.apply(proofDeletionConfirmed: true))
        XCTAssertTrue(store.isAutomaticCleanupEnabled)
        store.applyCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[.minuteSeals]!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[.anchorReceipts]!.path))
    }
    @MainActor func testAnUnwritableActivationDoesNotReportSuccessOrDelete() throws {
        let (store, storage, files) = try fixture()
        try FileManager.default.createDirectory(at: storage.activationFile, withIntermediateDirectories: false)
        let model = HistoryRetentionSettingsModel(store: store)
        model.automaticCleanup = true
        XCTAssertFalse(model.apply(proofDeletionConfirmed: false))
        XCTAssertNotNil(model.error)
        XCTAssertFalse(store.isAutomaticCleanupEnabled)
        store.applyCleanup()
        for file in files.values { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }

    func testCleanupDrainsWritersAndInvalidatesPreviouslyQueuedWork() throws {
        let (store, _, files) = try fixture()
        let barrier = DerivedHistoryWriteBarrier(label: "test.journey-retention-drain")
        let admission = try XCTUnwrap(barrier.admission())
        let permit = try XCTUnwrap(barrier.beginJob(admission: admission))
        try store.activate(store.policy)
        let completed = expectation(description: "cleanup after drain")
        store.applyCleanupAfterDrainingDerivedWriters(barrier: barrier) { completed.fulfill() }
        XCTAssertNil(barrier.admission())
        XCTAssertFalse(barrier.isCurrent(permit))
        for file in files.values { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        barrier.endJob(permit)
        wait(for: [completed], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[.detailedEvents]!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[.minuteSeals]!.path))
        XCTAssertNil(barrier.beginJob(admission: admission))
        XCTAssertNotNil(barrier.admission())
    }

    func testDisablingCleanupDuringDrainPreservesAllData() throws {
        let (store, _, files) = try fixture()
        let barrier = DerivedHistoryWriteBarrier(label: "test.journey-retention-cancel")
        let permit = try XCTUnwrap(barrier.beginJob())
        try store.activate(store.policy)
        let completed = expectation(description: "cancelled cleanup after drain")
        store.applyCleanupAfterDrainingDerivedWriters(barrier: barrier) { completed.fulfill() }
        try store.save(store.policy)
        barrier.endJob(permit)
        wait(for: [completed], timeout: 5)
        XCTAssertFalse(store.isAutomaticCleanupEnabled)
        for file in files.values { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertNotNil(barrier.admission())
    }
}
#endif
