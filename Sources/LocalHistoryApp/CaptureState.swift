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

        var isCapturing: Bool {
            !GoalongGlobalPause.isPaused() && lock.withLock { !manualPaused && userSessionActive && systemAwake && displaysAwake && screenUnlocked }
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
