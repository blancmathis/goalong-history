#if os(macOS)
    import Foundation

    final class CaptureState {
        private let lock = NSLock()
        private var manualPaused = false
        private var userSessionActive = true
        private var systemAwake = true

        var isCapturing: Bool {
            lock.withLock { !manualPaused && userSessionActive && systemAwake }
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
