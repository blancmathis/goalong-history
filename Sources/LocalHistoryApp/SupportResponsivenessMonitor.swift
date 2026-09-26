#if os(macOS)
import Foundation

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
#endif
