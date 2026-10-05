#if os(macOS)
import ApplicationServices
import Foundation

/// Commands and observer callbacks share one run loop. Admission and shutdown
/// never join the thread or wait for an AX call (including AX served by Goalong).
final class AXObservationThread {
    private final class State {
        let lock = NSLock()
        var runLoop: CFRunLoop?
        var pending: [() -> Void] = []

        func submit(_ command: @escaping () -> Void) {
            lock.lock()
            if let runLoop {
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, command)
                CFRunLoopWakeUp(runLoop)
            } else {
                pending.append(command)
            }
            lock.unlock()
        }

        func run() {
            let loop = CFRunLoopGetCurrent()!
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(loop, keepAlive, .defaultMode)
            lock.lock()
            runLoop = loop
            let commands = pending
            pending.removeAll()
            // Schedule pending commands before submit() can see the live loop.
            for command in commands {
                CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, command)
            }
            lock.unlock()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, keepAlive, .defaultMode)
            lock.lock()
            runLoop = nil
            lock.unlock()
        }
    }

    private let state = State()
    init() {
        let state = state
        let thread = Thread { state.run() }
        thread.name = "Goalong.AXObservation"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
    func submit(_ command: @escaping () -> Void) { state.submit(command) }
    func shutdown(after command: @escaping () -> Void) {
        state.submit { command(); CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
}
#endif
