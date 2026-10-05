#if os(macOS)
import Darwin
import Foundation
import MachO

/// One pending ping at most. Timer suspension/clock rollback invalidates an old
/// ping instead of mistaking sleep for a stalled application.
struct SupportResponsivenessState {
    enum Action: Equatable { case ping(UInt64), warning(Double), none }
    private var lastTick: Double?
    private var pending: Double?
    private var generation: UInt64 = 0
    private var reported = false

    mutating func tick(at now: Double) -> Action {
        if let lastTick, now < lastTick || now - lastTick > 60 {
            pending = nil; reported = false; generation &+= 1
        }
        lastTick = now
        if let pending {
            guard !reported, now - pending >= 30 else { return .none }
            reported = true; return .warning(max(0, now - pending))
        }
        generation &+= 1; pending = now
        return .ping(generation)
    }
    mutating func acknowledge(_ token: UInt64, at now: Double) -> Double? {
        guard token == generation, let pending else { return nil }
        let duration = reported ? max(0, now - pending) : nil
        self.pending = nil; reported = false
        return duration
    }
}

final class SupportResponsivenessMonitor {
    private let queue = DispatchQueue(label: "ai.goalong.support-responsiveness", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var state = SupportResponsivenessState()
    private var running = false
    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true; self.state = SupportResponsivenessState()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(3))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    private func tick() {
        guard running else { return }
        switch state.tick(at: ProcessInfo.processInfo.systemUptime) {
        case .none: break
        case .warning(let seconds):
            SupportDiagnostics.shared.record(.mainThreadUnresponsive, component: .interface, level: .warning,
                values: [.durationMS: .number(seconds * 1000)])
        case .ping(let token):
            DispatchQueue.main.async { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, self.running else { return }
                    if let seconds = self.state.acknowledge(token, at: ProcessInfo.processInfo.systemUptime) {
                        SupportDiagnostics.shared.record(.mainThreadRecovered, component: .interface,
                            values: [.durationMS: .number(seconds * 1000)])
                    }
                }
            }
        }
    }
    func stop() { queue.sync { running = false; timer?.cancel(); timer = nil } }
}

/// Main-thread stalls of 100 ms or more, the kind felt as a hitch after a click. A run loop
/// observer arms a one-shot watchdog when the main thread wakes and disarms it before it sleeps,
/// so an idle app costs nothing. When the watchdog fires, the main thread is suspended for a
/// few microseconds while its frame-pointer chain is copied into a preallocated buffer. Only
/// offsets inside the app's own binary are kept (`off_<hex>`, symbolicated offline with atos):
/// no symbol text, path or user data reaches the journal.
final class SupportStallMonitor {
    static let threshold: TimeInterval = 0.1
    private static let maximumFrames = 48
    private let queue = DispatchQueue(label: "ai.goalong.support-stall", qos: .userInteractive)
    private var observer: CFRunLoopObserver?
    private var timer: DispatchSourceTimer?
    private var mainThread: thread_act_t = 0
    private var stackLow: UInt = 0, stackHigh: UInt = 0
    private var imageStart: UInt = 0, imageEnd: UInt = 0
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: SupportStallMonitor.maximumFrames)
    // Guarded by `lock`: written on main, read on the watchdog queue.
    private var lock = os_unfair_lock()
    private var busySince: TimeInterval = 0
    private var iteration: UInt64 = 0
    private var sampled: (iteration: UInt64, frames: [String])?
    // Main thread only.
    private var lastRecord: TimeInterval = 0
    private var skipped = 0
    /// Last stall seen on main (duration in ms, app frames); read by tests.
    private(set) var lastStall: (durationMS: Double, frames: [String])?

    deinit { buffer.deallocate() }

    /// Call on the main thread.
    func start() {
        guard observer == nil else { return }
        mainThread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = top; stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let base = info.dli_fbase {
            imageStart = UInt(bitPattern: base)
            imageEnd = imageStart + Self.textSize(of: base)
        }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.sampleMainThread() }
        timer.schedule(deadline: .distantFuture)
        timer.resume(); self.timer = timer
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 0) { [weak self] _, activity in
            if activity == .afterWaiting { self?.woke() } else { self?.willSleep() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil; timer?.cancel(); timer = nil
    }

    private func woke() {
        os_unfair_lock_lock(&lock); busySince = ProcessInfo.processInfo.systemUptime; iteration &+= 1; os_unfair_lock_unlock(&lock)
        timer?.schedule(deadline: .now() + Self.threshold)
    }

    private func willSleep() {
        timer?.schedule(deadline: .distantFuture)
        let now = ProcessInfo.processInfo.systemUptime
        os_unfair_lock_lock(&lock)
        let started = busySince, current = iteration, frames = sampled?.iteration == current ? sampled?.frames : nil
        busySince = 0; sampled = nil
        os_unfair_lock_unlock(&lock)
        guard started > 0, now - started >= Self.threshold else { return }
        lastStall = ((now - started) * 1000, frames ?? [])
        // At most one record every 2 s; the stalls in between are counted on the next one.
        guard now - lastRecord >= 2 else { skipped += 1; return }
        lastRecord = now
        var values: [SupportKey: SupportValue] = [.durationMS: .number((now - started) * 1000)]
        if skipped > 0 { values[.suppressedCount] = .count(skipped); skipped = 0 }
        let keys: [SupportKey] = [.stallFrame1, .stallFrame2, .stallFrame3, .stallFrame4]
        for (key, frame) in zip(keys, frames ?? []) { values[key] = .symbol(frame) }
        let level: SupportLevel = now - started >= 1 ? .warning : .info
        queue.async { SupportDiagnostics.shared.record(.mainThreadStalled, component: .interface, level: level, values: values) }
    }

    /// Watchdog queue. No allocation happens while the main thread is suspended: it may hold
    /// the malloc lock.
    private func sampleMainThread() {
        os_unfair_lock_lock(&lock)
        let current = iteration, busy = busySince > 0, done = sampled?.iteration == current
        os_unfair_lock_unlock(&lock)
        guard busy, !done, mainThread != 0, imageEnd > imageStart else { return }
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
        let count = copyFrames()
        thread_resume(mainThread)
        var frames: [String] = []
        for index in 0..<count where frames.count < 4 {
            let address = buffer[index]
            guard address >= imageStart, address < imageEnd else { continue }
            frames.append("off_" + String(address - imageStart, radix: 16))
        }
        os_unfair_lock_lock(&lock)
        if iteration == current { sampled = (current, frames) }
        os_unfair_lock_unlock(&lock)
    }

    private func copyFrames() -> Int {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let flavor = ARM_THREAD_STATE64
        #else
        var state = x86_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let flavor = x86_THREAD_STATE64
        #endif
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, thread_state_flavor_t(flavor), $0, &stateCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let mask: UInt = 0x0000_0FFF_FFFF_FFFF // strips pointer-authentication bits
        #if arch(arm64)
        var count = 0
        buffer[count] = UInt(state.__pc) & mask; count += 1
        buffer[count] = UInt(state.__lr) & mask; count += 1
        var frame = UInt(state.__fp) & mask
        #else
        var count = 0
        buffer[count] = UInt(state.__rip); count += 1
        var frame = UInt(state.__rbp)
        #endif
        while count < Self.maximumFrames, frame >= stackLow, frame + 16 <= stackHigh, frame % 8 == 0 {
            let pointer = UnsafePointer<UInt>(bitPattern: frame)!
            let next = pointer[0] & mask, returnAddress = pointer[1] & mask
            guard returnAddress != 0 else { break }
            buffer[count] = returnAddress; count += 1
            guard next > frame else { break }
            frame = next
        }
        return count
    }

    private static func textSize(of header: UnsafeRawPointer) -> UInt {
        let mh = header.assumingMemoryBound(to: mach_header_64.self).pointee
        var command = header.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<mh.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == LC_SEGMENT_64 {
                let segment = command.assumingMemoryBound(to: segment_command_64.self).pointee
                let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { return UInt(segment.vmsize) }
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return 0
    }
}
#endif
