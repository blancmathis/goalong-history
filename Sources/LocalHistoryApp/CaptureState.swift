#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class CaptureState {
        private let lock = NSLock()
        private var manualPaused = false
        private var userSessionActive = true
        private var systemAwake = true
        private var displaysAwake = true
        private var screenUnlocked = true
        /// Last global-pause value read by `isCapturing`. Only `isCapturingHint` uses it.
        private var lastGlobalPause = false
        private let isGloballyPaused: () -> Bool

        init(isGloballyPaused: @escaping () -> Bool = { GoalongGlobalPause.isPaused() }) {
            self.isGloballyPaused = isGloballyPaused
        }

        /// Authoritative value. The global pause may read its file (lstat, and a read
        /// when the file changed) under its own process-wide lock.
        var isCapturing: Bool {
            let globallyPaused = isGloballyPaused()
            return lock.withLock {
                lastGlobalPause = globallyPaused
                return !globallyPaused && localFlagsAllowCapture
            }
        }

        /// No I/O and no shared lock: for the event-tap callback, which must never wait
        /// on the disk. The global pause part is the value last read by `isCapturing`;
        /// every consumer re-checks `isCapturing` before it records anything.
        var isCapturingHint: Bool {
            lock.withLock { !lastGlobalPause && localFlagsAllowCapture }
        }

        private var localFlagsAllowCapture: Bool {
            !manualPaused && userSessionActive && systemAwake && displaysAwake && screenUnlocked
        }

        var isManuallyPaused: Bool {
            lock.withLock { manualPaused }
        }

        @discardableResult
        func setManualPaused(_ paused: Bool) -> Bool {
            lock.withLock {
                let changed = manualPaused != paused
                manualPaused = paused
                return changed
            }
        }

        @discardableResult
        func setUserSessionActive(_ active: Bool) -> Bool {
            lock.withLock {
                let changed = userSessionActive != active
                userSessionActive = active
                return changed
            }
        }

        @discardableResult
        func setDisplaysAwake(_ awake: Bool) -> Bool {
            lock.withLock {
                let changed = displaysAwake != awake
                displaysAwake = awake
                return changed
            }
        }

        @discardableResult
        func setScreenUnlocked(_ unlocked: Bool) -> Bool {
            lock.withLock {
                let changed = screenUnlocked != unlocked
                screenUnlocked = unlocked
                return changed
            }
        }

        @discardableResult
        func setSystemAwake(_ awake: Bool) -> Bool {
            lock.withLock {
                let changed = systemAwake != awake
                systemAwake = awake
                return changed
            }
        }
    }

    extension NSLock {
        fileprivate func withLock<T>(_ body: () -> T) -> T {
            lock()
            defer { unlock() }
            return body()
        }
    }
#endif
