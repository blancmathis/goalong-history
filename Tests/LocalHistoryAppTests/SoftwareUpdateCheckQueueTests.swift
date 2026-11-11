#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    /// T-053 B1, C1, C3: the order of Sparkle 2.9.6 callbacks, replayed step by step. Each step
    /// cites `.build/checkouts/Sparkle/Sparkle/SPUUpdater.m`. The app wiring is the same as in
    /// `SoftwareUpdateManager`: KVO on `canCheckForUpdates`/`sessionInProgress` and the end of
    /// `didFinishUpdateCycle` call `next`; `mayPerform` calls `cycleWillStart`.
    final class SoftwareUpdateCheckQueueTests: XCTestCase {
        /// Minimal model of SPUUpdater's two flags and of the app's reactions.
        private struct Replay {
            var queue = SoftwareUpdateCheckQueue()
            var canCheck = true
            var session = false
            var clickPending = false
            var actions: [SoftwareUpdateCheckQueue.Action] = []

            /// One KVO notification: Sparkle wrote one flag through its setter.
            mutating func set(canCheck: Bool? = nil, session: Bool? = nil) {
                if let canCheck { self.canCheck = canCheck }
                if let session { self.session = session }
                serve()
            }

            mutating func mayPerform() { queue.cycleWillStart() }

            mutating func didFinishUpdateCycle(refused: Bool) {
                queue.cycleDidFinish(refused: refused)
                serve()
            }

            mutating func serve() {
                let action = queue.next(sparkleIsFree: canCheck && !session, clickPending: clickPending)
                guard action != .none else { return }
                actions.append(action)
                switch action {
                case .startProbe, .resumeClick:
                    // checkForUpdateInformation / checkForUpdates: `:765-766`, `:722-723`.
                    if action == .resumeClick { clickPending = false }
                    session = true
                    serve()
                    canCheck = false
                    serve()
                case .none:
                    break
                }
            }

            /// `scheduleNextUpdateCheck…` then its XPC reply on a later main-queue turn.
            mutating func reschedule() {
                set(canCheck: false) // :542
                set(session: true) // :543
                set(canCheck: true) // :546, session still YES
                set(session: false) // :547
            }
        }

        /// Hourly scheduled session refused → (Sparkle would reschedule) → one probe, only one.
        func testRefusedScheduledSessionRunsExactlyOneProbe() {
            var replay = Replay()
            // Timer: `_checkForUpdatesInBackground` (:605-606), then `mayPerform` (:846-853).
            replay.set(session: true)
            replay.set(canCheck: false)
            replay.mayPerform()
            // Refusal: `abortUpdateDriver` frees Sparkle BEFORE notifying us (:824-825, :827).
            replay.set(session: false)
            replay.set(canCheck: true)
            XCTAssertEqual(replay.actions, [], "the closing cycle must not be mixed with a new one")
            replay.didFinishUpdateCycle(refused: true)
            XCTAssertEqual(replay.actions, [.startProbe])
            // Sparkle skips its rescheduling while our probe runs (:830). Probe cycle, then its end.
            replay.mayPerform()
            replay.set(session: false)
            replay.set(canCheck: true)
            replay.didFinishUpdateCycle(refused: false)
            replay.reschedule() // :888-889
            XCTAssertEqual(replay.actions, [.startProbe], "one probe, only one")
        }

        /// Same refusal, but the probe intent arrives while Sparkle is rescheduling (session busy):
        /// it waits for `canCheckForUpdates` and the free session, then runs once.
        func testProbeWantedDuringReschedulingRunsOnceWhenSparkleIsFree() {
            var replay = Replay()
            replay.set(canCheck: false) // :542
            replay.set(session: true) // :543
            replay.queue.requestProbe()
            replay.serve()
            XCTAssertEqual(replay.actions, [])
            replay.set(canCheck: true) // :546: canCheck true but session still in progress
            XCTAssertEqual(replay.actions, [], "canCheckForUpdates alone is not enough (:546-547)")
            replay.set(session: false) // :547
            XCTAssertEqual(replay.actions, [.startProbe])
            replay.set(canCheck: true)
            replay.serve()
            XCTAssertEqual(replay.actions, [.startProbe])
        }

        /// C1: a click queued behind a running probe resumes once, after the probe ends, and never
        /// meets a busy Sparkle (no « momentanément indisponible » message).
        func testClickQueuedBehindProbeResumesOnceWithSparkleFree() {
            var replay = Replay()
            replay.queue.requestProbe()
            replay.serve()
            XCTAssertEqual(replay.actions, [.startProbe])
            replay.mayPerform()
            replay.clickPending = true // .wait: session in progress
            replay.serve()
            XCTAssertEqual(replay.actions, [.startProbe])
            // Probe ends: flags freed (:877-878) before didFinishUpdateCycle (:886).
            replay.set(session: false)
            replay.set(canCheck: true)
            XCTAssertEqual(replay.actions, [.startProbe])
            XCTAssertTrue(replay.canCheck && !replay.session, "startUserInitiatedCheck's guard passes")
            replay.didFinishUpdateCycle(refused: false)
            XCTAssertEqual(replay.actions, [.startProbe, .resumeClick])
            XCTAssertFalse(replay.clickPending)
            // Sparkle does not reschedule while the user check runs (:888); later events: nothing.
            replay.mayPerform()
            replay.set(session: false)
            replay.set(canCheck: true)
            replay.didFinishUpdateCycle(refused: false)
            replay.reschedule()
            XCTAssertEqual(replay.actions, [.startProbe, .resumeClick])
        }

        /// C3: a click during the rescheduling window (no cycle, no didFinishUpdateCycle coming)
        /// is served when the rescheduling ends, not an hour later.
        func testClickDuringReschedulingIsServedWhenItEnds() {
            var replay = Replay()
            replay.set(canCheck: false)
            replay.set(session: true)
            replay.clickPending = true
            replay.serve()
            replay.set(canCheck: true)
            XCTAssertEqual(replay.actions, [])
            replay.set(session: false)
            XCTAssertEqual(replay.actions, [.resumeClick])
        }

        /// Launch: `updater.start()` frees Sparkle (:168) and queues its first cycle on the main
        /// queue (:172-187). `SoftwareUpdateManager.start` only records the probe: serving it now
        /// would make Sparkle skip that launch cycle (:185). The cycle reschedules (:464 →
        /// :542-547); the probe runs after it, once.
        func testLaunchProbeIsServedAfterSparkleStartupSession() {
            var replay = Replay()
            replay.queue.requestProbe() // start(): request only, no serve
            XCTAssertEqual(replay.actions, [])
            replay.reschedule()
            XCTAssertEqual(replay.actions, [.startProbe])
            replay.mayPerform()
            replay.set(session: false)
            replay.set(canCheck: true)
            replay.didFinishUpdateCycle(refused: false)
            replay.reschedule()
            XCTAssertEqual(replay.actions, [.startProbe])
        }

        /// A finished probe or user check answers an older probe request; a refusal does not.
        func testOnlyARefusalLeavesAProbeToRun() {
            var queue = SoftwareUpdateCheckQueue()
            queue.requestProbe()
            queue.cycleWillStart()
            XCTAssertEqual(queue.next(sparkleIsFree: true, clickPending: false), .none)
            queue.cycleDidFinish(refused: false)
            XCTAssertEqual(queue.next(sparkleIsFree: true, clickPending: false), .none)
            queue.cycleWillStart()
            queue.cycleDidFinish(refused: true)
            XCTAssertEqual(queue.next(sparkleIsFree: true, clickPending: true), .resumeClick)
            XCTAssertEqual(queue.next(sparkleIsFree: true, clickPending: false), .none)
        }

        /// B1: a refused scheduled session read nothing and must not delay the next probe.
        func testRefusalDoesNotAdvanceTheBackgroundThrottle() {
            XCTAssertFalse(SoftwareUpdateManager.cycleCountsAsBackgroundCheck(
                error: NSError(domain: SoftwareUpdateManager.heldSessionRefusalDomain, code: 1)))
            XCTAssertTrue(SoftwareUpdateManager.cycleCountsAsBackgroundCheck(error: nil))
        }
    }
#endif
