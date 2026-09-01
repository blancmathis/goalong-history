#if os(macOS)
    import CoreGraphics
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class EventTapIngressBufferTests: XCTestCase {
        func testAdjacentBurstsCoalesceWithoutReorderingDiscreteInteractions() {
            let queue = EventTapIngressBuffer(capacity: 4)
            let start = Date(timeIntervalSince1970: 1_800_000_000)

            XCTAssertTrue(queue.enqueue(typing(at: start)))
            XCTAssertFalse(queue.enqueue(typing(at: start.addingTimeInterval(0.01))))
            XCTAssertFalse(queue.enqueue(click(at: start.addingTimeInterval(0.02))))
            XCTAssertFalse(queue.enqueue(scroll(at: start.addingTimeInterval(0.03), deltaY: 3)))
            XCTAssertFalse(queue.enqueue(scroll(at: start.addingTimeInterval(0.04), deltaY: 5)))

            let metrics = queue.metrics
            XCTAssertEqual(metrics.currentDepth, 3)
            XCTAssertEqual(metrics.maximumDepth, 3)
            XCTAssertEqual(metrics.acceptedCount, 5)
            XCTAssertEqual(metrics.coalescedCount, 2)
            XCTAssertEqual(metrics.droppedCount, 0)

            let typingBurst = queue.popFirst()
            XCTAssertEqual(typingBurst?.kind, .keyDown)
            XCTAssertEqual(typingBurst?.sequence, 1)
            XCTAssertEqual(typingBurst?.occurrences, 2)
            XCTAssertEqual(typingBurst?.observedAt, start)
            XCTAssertEqual(typingBurst?.lastObservedAt, start.addingTimeInterval(0.01))

            let discreteClick = queue.popFirst()
            XCTAssertEqual(discreteClick?.kind, .leftMouseDown)
            XCTAssertEqual(discreteClick?.sequence, 3)

            let scrollBurst = queue.popFirst()
            XCTAssertEqual(scrollBurst?.kind, .scrollWheel)
            XCTAssertEqual(scrollBurst?.sequence, 4)
            XCTAssertEqual(scrollBurst?.occurrences, 2)
            XCTAssertEqual(scrollBurst?.scrollDeltaY, 8)
            XCTAssertNil(queue.popFirst())

            // An empty drain resets the single-drain scheduling handoff.
            XCTAssertTrue(queue.enqueue(click(at: start.addingTimeInterval(1))))
        }

        func testQueueIsStrictlyBoundedAndReportsOverflow() {
            let queue = EventTapIngressBuffer(capacity: 3)
            let start = Date(timeIntervalSince1970: 1_800_000_000)

            XCTAssertTrue(queue.enqueue(click(at: start)))
            XCTAssertFalse(queue.enqueue(click(at: start.addingTimeInterval(0.01))))
            XCTAssertFalse(queue.enqueue(click(at: start.addingTimeInterval(0.02))))
            XCTAssertFalse(queue.enqueue(click(at: start.addingTimeInterval(0.03))))

            let metrics = queue.metrics
            XCTAssertEqual(metrics.capacity, 3)
            XCTAssertLessThanOrEqual(metrics.payloadCapacityBytes, 2_048)
            XCTAssertEqual(metrics.currentDepth, 3)
            XCTAssertEqual(metrics.maximumDepth, 3)
            XCTAssertEqual(metrics.acceptedCount, 3)
            XCTAssertEqual(metrics.droppedCount, 1)
        }

        func testRingBufferWraparoundPreservesFIFOOrder() {
            let queue = EventTapIngressBuffer(capacity: 3)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            for offset in 0 ..< 3 {
                _ = queue.enqueue(click(at: start.addingTimeInterval(Double(offset))))
            }

            XCTAssertEqual(queue.popFirst()?.sequence, 1)
            XCTAssertEqual(queue.popFirst()?.sequence, 2)
            _ = queue.enqueue(click(at: start.addingTimeInterval(3)))
            _ = queue.enqueue(click(at: start.addingTimeInterval(4)))

            XCTAssertEqual(queue.popFirst()?.sequence, 3)
            XCTAssertEqual(queue.popFirst()?.sequence, 4)
            XCTAssertEqual(queue.popFirst()?.sequence, 5)
            XCTAssertNil(queue.popFirst())
        }

        func testIngressLatencyDoesNotDependOnAXOrConsumerWork() {
            let queue = EventTapIngressBuffer(capacity: 8)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let wallStart = DispatchTime.now().uptimeNanoseconds

            // No consumer is run during this loop. Model a dense half-second callback
            // burst so all samples remain inside the production 0.70-second coalescing
            // window; ingress latency is therefore independent of AX or disk progress.
            for index in 0 ..< 20_000 {
                let observedAt = start.addingTimeInterval(Double(index) / 40_000)
                _ = queue.enqueue(
                    typing(at: observedAt),
                    callbackStartedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
            let metrics = queue.metrics
            XCTAssertEqual(metrics.currentDepth, 1)
            XCTAssertEqual(metrics.maximumDepth, 1)
            XCTAssertEqual(metrics.acceptedCount, 20_000)
            XCTAssertEqual(metrics.coalescedCount, 19_999)
            XCTAssertEqual(metrics.droppedCount, 0)
            XCTAssertLessThanOrEqual(metrics.payloadCapacityBytes, 4_096)
            XCTAssertGreaterThan(metrics.longestCallbackIngressNanoseconds, 0)
            XCTAssertLessThan(metrics.longestCriticalSectionNanoseconds, 100_000_000)
            XCTAssertLessThan(elapsed, 2_000_000_000)
        }

        func testPrivacyStateBoundariesNeverCoalesce() {
            let queue = EventTapIngressBuffer(capacity: 4)
            let start = Date(timeIntervalSince1970: 1_800_000_000)

            XCTAssertTrue(queue.enqueue(typing(at: start)))
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .keyDown,
                        observedAt: start.addingTimeInterval(0.01),
                        capturingWasEnabled: true,
                        secureInputWasEnabled: true
                    )
                )
            )
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .keyDown,
                        observedAt: start.addingTimeInterval(0.02),
                        capturingWasEnabled: false,
                        secureInputWasEnabled: false
                    )
                )
            )

            XCTAssertEqual(queue.metrics.currentDepth, 3)
            XCTAssertEqual(queue.metrics.coalescedCount, 0)
        }

        func testCoalescingStopsAtTimeOriginAndTargetBoundaries() {
            let queue = EventTapIngressBuffer(capacity: 8)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertTrue(queue.enqueue(typing(at: start, sourcePID: 10, targetPID: 20)))
            XCTAssertFalse(
                queue.enqueue(typing(at: start.addingTimeInterval(1.2), sourcePID: 10, targetPID: 20))
            )
            XCTAssertFalse(
                queue.enqueue(typing(at: start.addingTimeInterval(1.3), sourcePID: 11, targetPID: 20))
            )
            XCTAssertFalse(
                queue.enqueue(typing(at: start.addingTimeInterval(1.4), sourcePID: 11, targetPID: 21))
            )

            XCTAssertEqual(queue.metrics.currentDepth, 4)
            XCTAssertEqual(queue.metrics.coalescedCount, 0)
        }

        func testCoalescingSplitsLongBurstsAndContextChanges() {
            let queue = EventTapIngressBuffer(capacity: 8)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let firstContext = context(pid: 20, windowTitle: "First")
            let secondContext = context(pid: 20, windowTitle: "Second")

            XCTAssertTrue(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .keyDown,
                        observedAt: start,
                        targetProcessIdentifier: 20,
                        observedContext: firstContext
                    )
                )
            )
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .keyDown,
                        observedAt: start.addingTimeInterval(0.6),
                        targetProcessIdentifier: 20,
                        observedContext: firstContext
                    )
                )
            )
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .keyDown,
                        observedAt: start.addingTimeInterval(0.71),
                        targetProcessIdentifier: 20,
                        observedContext: firstContext
                    )
                )
            )
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .keyDown,
                        observedAt: start.addingTimeInterval(0.72),
                        targetProcessIdentifier: 20,
                        observedContext: secondContext
                    )
                )
            )

            XCTAssertEqual(queue.metrics.currentDepth, 3)
            XCTAssertEqual(queue.popFirst()?.occurrences, 2)
            XCTAssertEqual(queue.popFirst()?.occurrences, 1)
            XCTAssertEqual(queue.popFirst()?.observedContext, secondContext)
        }

        func testDragSamplesCoalesceWithBoundedPoints() {
            let queue = EventTapIngressBuffer(capacity: 4)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertTrue(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .leftMouseDragged,
                        observedAt: start,
                        locationX: .infinity,
                        locationY: -.infinity,
                        targetProcessIdentifier: 20
                    )
                )
            )
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .leftMouseDragged,
                        observedAt: start.addingTimeInterval(0.05),
                        locationX: 15,
                        locationY: 25,
                        targetProcessIdentifier: 20
                    )
                )
            )

            let drag = queue.popFirst()
            XCTAssertEqual(drag?.occurrences, 2)
            XCTAssertEqual(drag?.locationX, 0)
            XCTAssertEqual(drag?.locationY, 0)
            XCTAssertEqual(drag?.lastLocationX, 15)
            XCTAssertEqual(drag?.lastLocationY, 25)
            XCTAssertEqual(EventTapPendingInput.boundedCoordinate(2_000_000), 1_000_000)
        }

        func testSamePIDPublicToPrivateTransitionSplitsTypingAndDragAtIngress() throws {
            let queue = EventTapIngressBuffer(capacity: 8)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let publicContext = context(pid: 42, windowTitle: "Public")
            let privateContext = context(
                pid: 42,
                windowTitle: nil,
                suppression: .privateBrowserWindow
            )

            XCTAssertTrue(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .keyDown,
                        observedAt: start,
                        targetProcessIdentifier: 42,
                        observedContext: publicContext
                    )
                )
            )
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .keyDown,
                        observedAt: start.addingTimeInterval(0.01),
                        targetProcessIdentifier: 42,
                        observedContext: privateContext
                    )
                )
            )
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .leftMouseDragged,
                        observedAt: start.addingTimeInterval(0.02),
                        locationX: 10,
                        locationY: 10,
                        targetProcessIdentifier: 42,
                        observedContext: publicContext
                    )
                )
            )
            XCTAssertFalse(
                queue.enqueue(
                    EventTapPendingInput(
                        kind: .leftMouseDragged,
                        observedAt: start.addingTimeInterval(0.03),
                        locationX: 20,
                        locationY: 20,
                        targetProcessIdentifier: 42,
                        observedContext: privateContext
                    )
                )
            )

            XCTAssertEqual(queue.metrics.currentDepth, 4)
            XCTAssertEqual(queue.metrics.coalescedCount, 0)
            XCTAssertFalse(try XCTUnwrap(queue.popFirst()).eventTimeContextIsPrivate)
            XCTAssertTrue(try XCTUnwrap(queue.popFirst()).eventTimeContextIsPrivate)
            XCTAssertFalse(try XCTUnwrap(queue.popFirst()).eventTimeContextIsPrivate)
            XCTAssertTrue(try XCTUnwrap(queue.popFirst()).eventTimeContextIsPrivate)
        }

        func testEventTimePrivacyTargetAndFreshnessChecksFailClosed() {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let safe = context(pid: 42)
            let suppressed = context(pid: 42, suppression: .excludedApplication)
            let safeInput = EventTapPendingInput(
                kind: .keyDown,
                observedAt: start,
                targetProcessIdentifier: 42,
                observedContext: safe
            )
            let privateInput = EventTapPendingInput(
                kind: .keyDown,
                observedAt: start,
                targetProcessIdentifier: 42,
                observedContext: suppressed
            )

            XCTAssertFalse(safeInput.eventTimeContextIsPrivate)
            XCTAssertFalse(safeInput.targetIsRepresented(frontmostProcessIdentifier: 99))
            XCTAssertTrue(safeInput.targetIsRepresented(frontmostProcessIdentifier: 42))
            XCTAssertTrue(privateInput.eventTimeContextIsPrivate)

            let mismatched = EventTapPendingInput(
                kind: .keyDown,
                observedAt: start,
                targetProcessIdentifier: 77,
                observedContext: safe
            )
            XCTAssertFalse(mismatched.targetIsRepresented(frontmostProcessIdentifier: 99))
            XCTAssertTrue(mismatched.targetIsRepresented(frontmostProcessIdentifier: 77))

            XCTAssertTrue(
                EventTapMonitor.ingressAgeIsAcceptable(
                    observedAt: start,
                    now: start.addingTimeInterval(1.9)
                )
            )
            XCTAssertFalse(
                EventTapMonitor.ingressAgeIsAcceptable(
                    observedAt: start,
                    now: start.addingTimeInterval(2.1)
                )
            )
        }

        func testConcurrentProducersRemainBoundedAndLosslesslyCoalesce() {
            let queue = EventTapIngressBuffer(capacity: 4)
            let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
            DispatchQueue.concurrentPerform(iterations: 20_000) { _ in
                _ = queue.enqueue(typing(at: observedAt, sourcePID: 10, targetPID: 20))
            }

            let metrics = queue.metrics
            XCTAssertEqual(metrics.acceptedCount, 20_000)
            XCTAssertEqual(metrics.coalescedCount, 19_999)
            XCTAssertEqual(metrics.currentDepth, 1)
            XCTAssertEqual(metrics.maximumDepth, 1)
            XCTAssertEqual(metrics.droppedCount, 0)
            XCTAssertEqual(queue.popFirst()?.occurrences, 20_000)
        }

        func testDiscardPendingIsBoundedAndAccountsForEveryOccurrence() {
            let queue = EventTapIngressBuffer(capacity: 4)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            _ = queue.enqueue(typing(at: start))
            _ = queue.enqueue(typing(at: start.addingTimeInterval(0.1)))
            _ = queue.enqueue(click(at: start.addingTimeInterval(0.2)))

            XCTAssertEqual(queue.discardPending(), 3)
            XCTAssertEqual(queue.metrics.currentDepth, 0)
            XCTAssertEqual(queue.metrics.droppedCount, 3)
            XCTAssertTrue(queue.enqueue(click(at: start.addingTimeInterval(1))))
        }

        func testObservationGapAccumulatorIsBoundedAndResettable() throws {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var accumulator = EventTapObservationGapAccumulator()
            accumulator.record(
                count: Int.max,
                firstObservedAt: start,
                lastObservedAt: start.addingTimeInterval(0.2),
                reason: String(repeating: "overflow", count: 20)
            )
            accumulator.record(
                count: 4,
                firstObservedAt: start.addingTimeInterval(-0.1),
                lastObservedAt: start.addingTimeInterval(0.4),
                reason: "stale_ingress"
            )

            let gap = try XCTUnwrap(accumulator.take())
            XCTAssertEqual(gap.count, 1_000_000_000)
            XCTAssertEqual(gap.firstObservedAt, start.addingTimeInterval(-0.1))
            XCTAssertEqual(gap.lastObservedAt, start.addingTimeInterval(0.4))
            XCTAssertEqual(gap.reasons.count, 2)
            XCTAssertTrue(gap.reasons.allSatisfy { $0.count <= 64 })
            XCTAssertNil(accumulator.take())
        }

        func testThreadGateCancellationBlocksLateInstallAndRestart() {
            let cancelledBeforeInstall = EventTapThreadGate()
            cancelledBeforeInstall.cancel()
            XCTAssertFalse(cancelledBeforeInstall.install(runLoop: CFRunLoopGetCurrent()))
            XCTAssertFalse(cancelledBeforeInstall.markEnabled())
            XCTAssertFalse(cancelledBeforeInstall.isEnabled)

            let installed = EventTapThreadGate()
            XCTAssertTrue(installed.install(runLoop: CFRunLoopGetCurrent()))
            XCTAssertTrue(installed.markEnabled())
            XCTAssertTrue(installed.isEnabled)
            installed.clear()
            XCTAssertFalse(installed.isEnabled)
        }

        func testCallbackSourceContainsNoAXAppKitAnalysisOrPersistenceWork() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = repositoryRoot
                .appendingPathComponent("Sources/LocalHistoryApp/EventTapMonitor.swift")
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let callback = try XCTUnwrap(
                source.slice(
                    from: "        func handle(type: CGEventType, event: CGEvent) {",
                    through: "        var ingressMetrics: EventTapIngressMetrics {"
                )
            )

            XCTAssertTrue(callback.contains("ingress.enqueue("))
            XCTAssertTrue(callback.contains("eventTargetUnixProcessID"))
            XCTAssertTrue(callback.contains("observedContext: contextMonitor.latestSnapshot"))
            XCTAssertTrue(callback.contains("DispatchQueue.main.async"))
            for forbidden in [
                "contextMonitor.sampleNow",
                "contextProvider.",
                "recorder.record",
                "ActivityAnalysisRuntime",
                "Data(contentsOf:",
                ".write(to:",
            ] {
                XCTAssertFalse(
                    callback.contains(forbidden),
                    "Event-tap callback regressed across the non-blocking boundary: \(forbidden)"
                )
            }
        }

        func testKeyboardIngressRetainsOnlyCoarseActivityClassification() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/EventTapMonitor.swift"),
                encoding: .utf8
            )
            let pendingInput = try XCTUnwrap(
                source.slice(
                    from: "    struct EventTapPendingInput: Equatable {",
                    through: "    struct EventTapIngressMetrics: Equatable {"
                )
            )
            let keyHandler = try XCTUnwrap(
                source.slice(
                    from: "        private func handleKeyDown(",
                    through: "        private func addTypingActivity("
                )
            )

            XCTAssertTrue(pendingInput.contains("var keyActivity: KeyActivity"))
            XCTAssertFalse(pendingInput.contains("keyCode"))
            XCTAssertFalse(pendingInput.contains("flagsRawValue"))
            XCTAssertFalse(pendingInput.contains("isRepeat"))
            XCTAssertFalse(source.contains("keyboardEventAutorepeat"))
            XCTAssertFalse(source.contains("KeyDescriptor"))
            XCTAssertFalse(source.contains("CGEventKeyboardGetUnicodeString"))
            XCTAssertTrue(keyHandler.contains("key: nil"))
            XCTAssertTrue(keyHandler.contains("modifiers: []"))
        }

        func testBurstSemanticCaptureUsesOnlyOneSettledSnapshotAfterInactivity() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/EventTapMonitor.swift"),
                encoding: .utf8
            )
            let scrollStart = try XCTUnwrap(
                source.slice(from: "        private func handleScroll(", through: "        private func handleKeyDown(")
            )
            let typingStart = try XCTUnwrap(
                source.slice(from: "        private func addTypingActivity(", through: "        private func flushTypingBurst()")
            )
            let typingFlush = try XCTUnwrap(
                source.slice(from: "        private func flushTypingBurst()", through: "        private func resetTypingBurst()")
            )
            let scrollFlush = try XCTUnwrap(
                source.slice(from: "        private func flushScrollBurst()", through: "        private func resetScrollBurst()")
            )

            XCTAssertTrue(scrollStart.contains("rescheduleScrollSettled("))
            XCTAssertTrue(typingStart.contains("rescheduleTypingSettled("))
            XCTAssertTrue(source.contains("rescheduleNavigationSettled("))
            XCTAssertFalse(source.contains("scheduleTypingAfter("))
            XCTAssertFalse(source.contains("scheduleScrollAfter("))
            XCTAssertFalse(source.contains("private func captureNearEvent("))
            XCTAssertFalse(typingFlush.contains("captureAfter("))
            XCTAssertFalse(scrollFlush.contains("captureAfter("))
            XCTAssertTrue(source.contains("deadline: .now() + max(0, 1.20 - elapsed)"))
            XCTAssertTrue(source.contains("deadline: .now() + max(0, 1.05 - elapsed)"))
            XCTAssertTrue(typingFlush.contains("timestamp: end"))
            XCTAssertTrue(scrollFlush.contains("timestamp: end"))
        }

        func testPhysicalDragAndInputBoundariesArePresentInMonitorSource() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/EventTapMonitor.swift"),
                encoding: .utf8
            )

            for required in [
                ".leftMouseDragged",
                ".rightMouseDragged",
                ".otherMouseDragged",
                ".leftMouseUp",
                "trigger: \"drag\"",
                "pointer_gesture",
                "flushTypingBurst()",
                "A disabled shortcut category must never fall through as text activity.",
            ] {
                XCTAssertTrue(source.contains(required), "Missing physical-input boundary: \(required)")
            }

            let mouseDown = try XCTUnwrap(
                source.slice(from: "        private func handleMouseDown(", through: "        private func handleMouseDragged(")
            )
            let mouseDragged = try XCTUnwrap(
                source.slice(from: "        private func handleMouseDragged(", through: "        private func handleMouseUp(")
            )
            let mouseUp = try XCTUnwrap(
                source.slice(from: "        private func handleMouseUp(", through: "        private func buttonName(")
            )
            XCTAssertFalse(mouseDown.contains("recorder.record("), "mouse-down must wait for click/drag classification")
            XCTAssertTrue(mouseDown.contains("let interactionID = UUID().uuidString"))
            XCTAssertTrue(mouseDown.contains("contextProvider.element("))
            XCTAssertTrue(mouseDragged.contains("interactionID: down.interactionID"))
            XCTAssertTrue(mouseUp.contains("timestamp: down.startedAt"))
            XCTAssertTrue(mouseUp.contains("completeDrag("))
            XCTAssertTrue(source.contains("timestamp: input.lastObservedAt"))
            XCTAssertTrue(source.contains("cancelOpenInteractionsForBoundary()"))
        }

        func testFreshPrivacyFailureCancelsEveryOpenInteractionWithoutPersistingIt() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/EventTapMonitor.swift"),
                encoding: .utf8
            )
            let processing = try XCTUnwrap(
                source.slice(
                    from: "        private func process(_ input: EventTapPendingInput) {",
                    through: "        private func suppressForSecureInput(using context: ContextSnapshot?) {"
                )
            )
            let secureSuppression = try XCTUnwrap(
                source.slice(
                    from: "        private func suppressForSecureInput(using context: ContextSnapshot?) {",
                    through: "        /// Cancels without persisting."
                )
            )
            let ingressDropReporting = try XCTUnwrap(
                source.slice(
                    from: "        private func reportIngressDropsIfNeeded(reason: String = \"bounded_ingress_overflow\") {",
                    through: "        /// Collapses a burst of callback losses"
                )
            )
            let cancellation = try XCTUnwrap(
                source.slice(
                    from: "        private func cancelOpenInteractionsForBoundary(discardPendingInput: Bool = false) {",
                    through: "        private func resumeAfterSecureInputIfNeeded(using context: ContextSnapshot) {"
                )
            )

            XCTAssertTrue(processing.contains("guard let context = input.observedContext else"))
            XCTAssertTrue(processing.contains("context.app.processIdentifier == frontmostPID"))
            XCTAssertTrue(processing.contains("contextProvider.fastSuppressionReason()"))
            XCTAssertTrue(processing.contains("let nearEventContext = context"))
            XCTAssertFalse(processing.contains("input.observedContext ?? context"))
            XCTAssertFalse(processing.contains("needsFreshPrivacyCheck"))
            XCTAssertFalse(source.contains("ComputerHistoryMetadata.Phase.before"))
            XCTAssertFalse(source.contains("phase: ComputerHistoryMetadata.Phase.nearEvent"))
            XCTAssertFalse(source.contains("ActivityAnalysisRuntime.shared.scheduleInteractionContext"))
            XCTAssertTrue(secureSuppression.contains("cancelOpenInteractionsForBoundary()"))
            XCTAssertFalse(secureSuppression.contains("flushTypingBurst()"))
            XCTAssertFalse(secureSuppression.contains("flushScrollBurst()"))
            XCTAssertTrue(
                ingressDropReporting.contains(
                    "cancelOpenInteractionsForBoundary(discardPendingInput: true)"
                ),
                "Only a proven ingress overflow should discard the independently vetted queue."
            )

            for requiredReset in [
                "interactionBoundaryGeneration &+= 1",
                "if discardPendingInput",
                "ingress.discardPending()",
                "typingFlushWorkItem?.cancel()",
                "scrollFlushWorkItem?.cancel()",
                "typingSettledWorkItem?.cancel()",
                "scrollSettledWorkItem?.cancel()",
                "navigationSettledWorkItem?.cancel()",
                "deferredSemanticCaptures.removeAll",
                "resetTypingBurst()",
                "resetScrollBurst()",
                "pointerDownStates.removeAll",
                "activeDragStates.removeAll",
            ] {
                XCTAssertTrue(
                    cancellation.contains(requiredReset),
                    "Privacy boundary failed to cancel: \(requiredReset)"
                )
            }
            XCTAssertTrue(cancellation.contains("for capture in deferredSemanticCaptures.values"))
            XCTAssertTrue(cancellation.contains("capture.cancel()"))
            XCTAssertFalse(cancellation.contains("recorder.record("))

            let deferredCapture = try XCTUnwrap(
                source.slice(
                    from: "        private func scheduleOwnedSemanticCapture(",
                    through: "        private func rescheduleTypingSettled("
                )
            )
            XCTAssertTrue(deferredCapture.contains("maximumDeferredSemanticCaptures"))
            XCTAssertTrue(deferredCapture.contains("boundaryGeneration"))
            XCTAssertTrue(deferredCapture.contains("wasPending"))
            XCTAssertFalse(deferredCapture.contains("scheduleInteractionContext"))
        }

        func testRichAccessibilityTraversalRunsOffInputQueueAndHasABoundedBacklog() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/ActivityAnalysisRuntime.swift"),
                encoding: .utf8
            )
            let persistence = try XCTUnwrap(
                source.slice(
                    from: "        private func persistSemanticContext(",
                    through: "        private func commitSemanticContext("
                )
            )

            XCTAssertTrue(source.contains("maximumPendingSemanticCaptures = 2"))
            XCTAssertTrue(persistence.contains("pendingSemanticCaptureCount < Self.maximumPendingSemanticCaptures"))
            XCTAssertTrue(persistence.contains("semanticCaptureQueue.async"))
            XCTAssertTrue(persistence.contains("AXRichContextReader.capture("))
            XCTAssertTrue(persistence.contains("DispatchQueue.main.async"))
            XCTAssertTrue(persistence.contains("captureGeneration == self.interactionCaptureGeneration"))
            XCTAssertTrue(persistence.contains("Self.semanticBoundaryMatches("))
        }

        private func typing(
            at date: Date,
            sourcePID: Int64 = 0,
            targetPID: Int64 = 0
        ) -> EventTapPendingInput {
            EventTapPendingInput(
                kind: .keyDown,
                observedAt: date,
                sourceProcessIdentifier: sourcePID,
                targetProcessIdentifier: targetPID
            )
        }

        private func click(at date: Date) -> EventTapPendingInput {
            EventTapPendingInput(
                kind: .leftMouseDown,
                observedAt: date,
                locationX: 100,
                locationY: 200
            )
        }

        private func scroll(at date: Date, deltaY: Double) -> EventTapPendingInput {
            EventTapPendingInput(
                kind: .scrollWheel,
                observedAt: date,
                scrollDeltaY: deltaY
            )
        }

        private func context(
            pid: Int32,
            windowTitle: String? = nil,
            suppression: SuppressionReason? = nil
        ) -> ContextSnapshot {
            ContextSnapshot(
                app: AppSnapshot(name: "Fixture", bundleIdentifier: "test.fixture", processIdentifier: pid),
                window: windowTitle.map { WindowSnapshot(title: $0, role: nil, subrole: nil) },
                focusedElement: nil,
                url: nil,
                suppressionReason: suppression
            )
        }
    }

    private extension String {
        func slice(from start: String, through end: String) -> String? {
            guard let startRange = range(of: start),
                let endRange = range(of: end, range: startRange.upperBound ..< endIndex)
            else { return nil }
            return String(self[startRange.lowerBound ..< endRange.lowerBound])
        }
    }
#endif
