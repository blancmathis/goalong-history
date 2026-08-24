#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class ActivityAnalysisUIRefreshTests: XCTestCase {
        func testEqualPageRefreshesShareOneAdmittedSourcePass() throws {
            let barrier = DerivedHistoryWriteBarrier(
                label: "goalong-ui-refresh-barrier-\(UUID().uuidString)"
            )
            let operationStarted = DispatchSemaphore(value: 0)
            let releaseOperation = DispatchSemaphore(value: 0)
            let stateLock = NSLock()
            var operationCount = 0
            let scheduler = ActivityAnalysisRefreshScheduler(
                label: "goalong-ui-refresh-scheduler-\(UUID().uuidString)",
                barrier: barrier
            ) { _, _ in
                stateLock.lock()
                operationCount += 1
                stateLock.unlock()
                operationStarted.signal()
                _ = releaseOperation.wait(timeout: .now() + 2)
                return Self.cycleResult(sourceReadPasses: 1)
            }
            let completionQueue = DispatchQueue(
                label: "goalong-ui-refresh-completions-\(UUID().uuidString)"
            )
            let completed = expectation(description: "both page callbacks")
            completed.expectedFulfillmentCount = 2
            var sourceReadPasses: [Int] = []
            let completion: ActivityAnalysisRefreshScheduler.Completion = { result in
                if case .success(let value) = result {
                    stateLock.lock()
                    sourceReadPasses.append(value.sourceReadPasses)
                    stateLock.unlock()
                }
                completed.fulfill()
            }
            let day = Date(timeIntervalSince1970: 1_777_000_000)

            scheduler.request(
                day: day,
                force: true,
                completionQueue: completionQueue,
                completion: completion
            )
            XCTAssertEqual(operationStarted.wait(timeout: .now() + 2), .success)
            scheduler.request(
                day: day,
                force: true,
                completionQueue: completionQueue,
                completion: completion
            )
            releaseOperation.signal()

            wait(for: [completed], timeout: 2)
            XCTAssertTrue(scheduler.waitUntilIdle(timeout: .now() + 2))
            stateLock.lock()
            let observedOperationCount = operationCount
            let observedPasses = sourceReadPasses
            stateLock.unlock()
            XCTAssertEqual(observedOperationCount, 1)
            XCTAssertEqual(observedPasses, [1, 1])
        }

        func testCycleServiceRejectsSameRootReentrancyWithoutDeadlock() {
            var service: ActivityAnalysisCycleService!
            service = ActivityAnalysisCycleService(
                revisionProvider: { _, _ in .absent },
                operation: { day, tokenBudget, forceVerification, includeActivityMemory in
                    try service.process(
                        day: day,
                        tokenBudget: tokenBudget,
                        forceVerification: forceVerification,
                        includeActivityMemory: includeActivityMemory
                    )
                }
            )

            let startedAt = Date()
            XCTAssertThrowsError(
                try service.process(
                    day: Date(timeIntervalSince1970: 1_777_000_000),
                    tokenBudget: 1_600,
                    forceVerification: true,
                    includeActivityMemory: false
                )
            ) { error in
                guard let cycleError = error as? ActivityAnalysisCycleError,
                    case .reentrantCycle = cycleError
                else { return XCTFail("Expected reentrant-cycle rejection, got \(error)") }
            }
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        }

        func testClearDrainsActiveRefreshAndInvalidatesQueuedPreClearRefresh() {
            let barrier = DerivedHistoryWriteBarrier(
                label: "goalong-ui-clear-barrier-\(UUID().uuidString)"
            )
            let firstOperationStarted = DispatchSemaphore(value: 0)
            let releaseFirstOperation = DispatchSemaphore(value: 0)
            let stateLock = NSLock()
            var operationCount = 0
            let scheduler = ActivityAnalysisRefreshScheduler(
                label: "goalong-ui-clear-scheduler-\(UUID().uuidString)",
                barrier: barrier
            ) { _, _ in
                stateLock.lock()
                operationCount += 1
                let current = operationCount
                stateLock.unlock()
                if current == 1 {
                    firstOperationStarted.signal()
                    _ = releaseFirstOperation.wait(timeout: .now() + 2)
                }
                return Self.cycleResult(sourceReadPasses: 1)
            }
            let completionQueue = DispatchQueue(
                label: "goalong-ui-clear-completions-\(UUID().uuidString)"
            )
            let invalidated = expectation(description: "pre-clear refreshes invalidated")
            invalidated.expectedFulfillmentCount = 2
            let suspended = expectation(description: "refresh during clear rejected")
            var observedErrors: [ActivityAnalysisRefreshError] = []
            let captureError: ActivityAnalysisRefreshScheduler.Completion = { result in
                if case .failure(let error) = result,
                    let refreshError = error as? ActivityAnalysisRefreshError
                {
                    stateLock.lock()
                    observedErrors.append(refreshError)
                    stateLock.unlock()
                }
                invalidated.fulfill()
            }
            let firstDay = Date(timeIntervalSince1970: 1_777_000_000)
            let secondDay = firstDay.addingTimeInterval(86_400)

            scheduler.request(
                day: firstDay,
                force: true,
                completionQueue: completionQueue,
                completion: captureError
            )
            XCTAssertEqual(firstOperationStarted.wait(timeout: .now() + 2), .success)
            scheduler.request(
                day: secondDay,
                force: true,
                completionQueue: completionQueue,
                completion: captureError
            )

            let suspension = barrier.suspend()
            scheduler.request(
                day: secondDay,
                force: true,
                completionQueue: completionQueue
            ) { result in
                if case .failure(let error) = result,
                    let refreshError = error as? ActivityAnalysisRefreshError
                {
                    stateLock.lock()
                    observedErrors.append(refreshError)
                    stateLock.unlock()
                }
                suspended.fulfill()
            }

            let drainedSignal = DispatchSemaphore(value: 0)
            barrier.notifyWhenDrained(suspension, on: completionQueue) {
                barrier.resume(suspension)
                drainedSignal.signal()
            }
            XCTAssertEqual(drainedSignal.wait(timeout: .now() + 0.05), .timedOut)
            releaseFirstOperation.signal()

            XCTAssertEqual(drainedSignal.wait(timeout: .now() + 2), .success)
            wait(for: [invalidated, suspended], timeout: 2)
            XCTAssertTrue(scheduler.waitUntilIdle(timeout: .now() + 2))
            stateLock.lock()
            let observedOperationCount = operationCount
            let errors = observedErrors
            stateLock.unlock()
            XCTAssertEqual(observedOperationCount, 1)
            XCTAssertEqual(
                errors.filter { $0 == .invalidatedByHistoryClear }.count,
                2
            )
            XCTAssertEqual(
                errors.filter { $0 == .temporarilySuspended }.count,
                1
            )
        }

        func testActivityPageModelDoesNotPublishAnOlderRequest() {
            let runtime = ControlledRefreshRuntime()
            let firstDay = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: 1_777_000_000)
            )
            let secondDay = Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: firstDay
            )!
            let analyses = [
                ActivityAnalysisPaths.dayString(firstDay): Self.analysis(for: firstDay),
                ActivityAnalysisPaths.dayString(secondDay): Self.analysis(for: secondDay),
            ]
            let model = ActivityAnalysisPageModel(
                refreshRuntime: runtime,
                storedAnalysisLoader: { analyses[ActivityAnalysisPaths.dayString($0)] }
            )

            model.refresh(day: firstDay, forceRebuild: true)
            model.refresh(day: secondDay, forceRebuild: true)
            XCTAssertEqual(runtime.requestCount, 2)

            runtime.completeRequest(at: 1, with: .success(Self.cycleResult()))
            let newestPublished = expectation(description: "newest request published")
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    XCTAssertEqual(model.analysis?.dayStart, secondDay)
                    XCTAssertFalse(model.isLoading)
                    newestPublished.fulfill()
                }
            }
            wait(for: [newestPublished], timeout: 2)

            runtime.completeRequest(at: 0, with: .success(Self.cycleResult()))
            let staleIgnored = expectation(description: "stale request ignored")
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    XCTAssertEqual(model.analysis?.dayStart, secondDay)
                    XCTAssertFalse(model.isLoading)
                    staleIgnored.fulfill()
                }
            }
            wait(for: [staleIgnored], timeout: 2)
        }

        func testActivityPageModelKeepsStoredFallbackAndReportsRefreshError() {
            let runtime = ControlledRefreshRuntime()
            let day = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: 1_777_000_000)
            )
            let stored = Self.analysis(for: day)
            let model = ActivityAnalysisPageModel(
                refreshRuntime: runtime,
                storedAnalysisLoader: { _ in stored }
            )

            model.refresh(day: day, forceRebuild: true)
            runtime.completeRequest(at: 0, with: .failure(FixtureRefreshError.failed))

            let fallbackPublished = expectation(description: "stored fallback published")
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    XCTAssertEqual(model.analysis, stored)
                    XCTAssertEqual(model.errorMessage, FixtureRefreshError.failed.localizedDescription)
                    XCTAssertFalse(model.isLoading)
                    fallbackPublished.fulfill()
                }
            }
            wait(for: [fallbackPublished], timeout: 2)
        }

        func testComputerHistoryPageModelVerifiesStoredMemoryAndReportsAbsentSource() {
            let runtime = ControlledRefreshRuntime()
            let day = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: 1_777_000_000)
            )
            let stored = ComputerHistoryEngine.analyze(events: [], day: day, generatedAt: day)
            let model = ComputerHistoryPageModel(
                refreshRuntime: runtime,
                storedMemoryLoader: { _ in stored }
            )

            model.refresh(day: day)

            XCTAssertEqual(runtime.requestCount, 1)
            XCTAssertEqual(model.memory, stored)
            XCTAssertEqual(model.sourceStatus, .checking)
            XCTAssertFalse(model.isLoading)

            runtime.completeRequest(
                at: 0,
                with: .success(Self.cycleResult(sourceAbsent: true))
            )

            let absentPublished = expectation(description: "absent source status published")
            DispatchQueue.main.async {
                XCTAssertEqual(model.memory, stored)
                XCTAssertEqual(model.sourceStatus, .absent)
                XCTAssertNil(model.errorMessage)
                XCTAssertFalse(model.isLoading)
                absentPublished.fulfill()
            }
            wait(for: [absentPublished], timeout: 2)
        }

        func testComputerHistoryPageModelKeepsStoredMemoryWhenSourceIsInaccessible() {
            let runtime = ControlledRefreshRuntime()
            let day = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: 1_777_000_000)
            )
            let stored = ComputerHistoryEngine.analyze(events: [], day: day, generatedAt: day)
            let model = ComputerHistoryPageModel(
                refreshRuntime: runtime,
                storedMemoryLoader: { _ in stored }
            )
            let error = ActivityAnalysisCycleError.sourceInaccessible("Permission denied")

            model.refresh(day: day)
            runtime.completeRequest(at: 0, with: .failure(error))

            let inaccessiblePublished = expectation(
                description: "inaccessible source status published"
            )
            DispatchQueue.main.async {
                XCTAssertEqual(model.memory, stored)
                XCTAssertEqual(
                    model.sourceStatus,
                    .inaccessible(error.localizedDescription)
                )
                XCTAssertEqual(model.errorMessage, error.localizedDescription)
                XCTAssertFalse(model.isLoading)
                inaccessiblePublished.fulfill()
            }
            wait(for: [inaccessiblePublished], timeout: 2)
        }

        private static func cycleResult(
            sourceReadPasses: Int = 0,
            sourceAbsent: Bool = false
        ) -> ActivityAnalysisCycleResult {
            ActivityAnalysisCycleResult(
                sourceAbsent: sourceAbsent,
                issues: [],
                sourceBytesRead: sourceReadPasses == 0 ? 0 : 128,
                sourceReadPasses: sourceReadPasses,
                derivedViewsWritten: 2,
                usedCachedRevision: sourceReadPasses == 0
            )
        }

        private static func analysis(for day: Date) -> ActivityDayAnalysis {
            ActivityAnalysisEngine.analyze(
                events: [],
                day: day,
                generatedAt: day.addingTimeInterval(1)
            )
        }
    }

    private final class ControlledRefreshRuntime: ActivityAnalysisRefreshServing {
        private struct Request {
            let completion: (Result<ActivityAnalysisCycleResult, Error>) -> Void
        }

        private var requests: [Request] = []

        var requestCount: Int { requests.count }

        func refresh(
            day _: Date,
            force _: Bool,
            completion: @escaping (Result<ActivityAnalysisCycleResult, Error>) -> Void
        ) {
            requests.append(Request(completion: completion))
        }

        func completeRequest(
            at index: Int,
            with result: Result<ActivityAnalysisCycleResult, Error>
        ) {
            requests[index].completion(result)
        }
    }

    private enum FixtureRefreshError: LocalizedError {
        case failed

        var errorDescription: String? { "Fixture refresh failed" }
    }
#endif
