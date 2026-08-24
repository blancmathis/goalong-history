#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class DerivedHistoryWriteBarrierTests: XCTestCase {
        func testClearDrainsPreClearWriterAndInvalidatesItsGeneration() throws {
            let container = FileManager.default.temporaryDirectory.appendingPathComponent(
                "goalong-derived-clear-race-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: container) }
            let output = container.appendingPathComponent("derived.json")
            let barrier = DerivedHistoryWriteBarrier(
                label: "goalong-derived-clear-race-test-\(UUID().uuidString)"
            )
            let admission = try XCTUnwrap(barrier.admission())
            let writerLoadedSource = DispatchSemaphore(value: 0)
            let releaseWriter = DispatchSemaphore(value: 0)
            let writerFinished = DispatchSemaphore(value: 0)

            DispatchQueue.global(qos: .utility).async {
                guard let permit = barrier.beginJob(admission: admission) else {
                    writerFinished.signal()
                    return
                }
                writerLoadedSource.signal()
                _ = releaseWriter.wait(timeout: .now() + 2)
                try? Data("pre-clear-derived".utf8).write(to: output, options: .atomic)
                barrier.endJob(permit)
                writerFinished.signal()
            }

            XCTAssertEqual(writerLoadedSource.wait(timeout: .now() + 2), .success)
            let suspension = barrier.suspend()
            XCTAssertNil(barrier.beginJob())

            let drained = DispatchSemaphore(value: 0)
            let outputWasPresentAtDeletion = LockedFlag()
            barrier.notifyWhenDrained(
                suspension,
                on: DispatchQueue.global(qos: .utility)
            ) {
                outputWasPresentAtDeletion.set(
                    FileManager.default.fileExists(atPath: output.path)
                )
                try? FileManager.default.removeItem(at: output)
                barrier.resume(suspension)
                drained.signal()
            }

            // The clear cannot delete derived files while a writer that loaded the old
            // source is still active.
            XCTAssertEqual(drained.wait(timeout: .now() + 0.05), .timedOut)
            releaseWriter.signal()
            XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
            XCTAssertTrue(outputWasPresentAtDeletion.value)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

            // A job queued in the old generation remains invalid even after resume.
            XCTAssertNil(barrier.beginJob(admission: admission))
            let postClearAdmission = try XCTUnwrap(barrier.admission())
            let postClearPermit = try XCTUnwrap(
                barrier.beginJob(admission: postClearAdmission)
            )
            XCTAssertTrue(barrier.isCurrent(postClearPermit))
            barrier.endJob(postClearPermit)
        }
    }

    private final class LockedFlag {
        private let lock = NSLock()
        private var storage = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ value: Bool) {
            lock.lock()
            storage = value
            lock.unlock()
        }
    }
#endif
