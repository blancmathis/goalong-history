#if os(macOS)
import Ambiance
import Foundation

/// Plays an installed Focus source during work phases of a session started with `ambiance`.
/// It never downloads and does nothing while the Ambiance module is off or no Focus source is
/// installed. It stops only the audio it started, so a source the user chose is left alone.
@MainActor final class AmbianceFocusSessionAudio: FocusSessionAudio {
    private let controller: @MainActor () -> AmbianceController?
    private let lastSource: @MainActor () -> String?
    private var playing: AmbianceSource?

    init(controller: @escaping @MainActor () -> AmbianceController?, lastSource: @escaping @MainActor () -> String?) {
        self.controller = controller; self.lastSource = lastSource
    }

    func startWork() {
        guard let controller = controller() else { playing = nil; return }
        if let playing, controller.state == .playing(playing) { return }
        if case .playing = controller.state { playing = nil; return }
        controller.refresh()
        guard let source = Self.focusSource(in: controller.sources, last: lastSource()) else { playing = nil; return }
        controller.play(source)
        playing = controller.state == .playing(source) ? source : nil
    }

    func startBreak() { stop() }

    func stop() {
        defer { playing = nil }
        guard let playing, let controller = controller(), controller.state == .playing(playing) else { return }
        controller.stop()
    }

    /// The last Focus source the user played when it is still installed, else the first installed one.
    static func focusSource(in sources: [AmbianceSource], last: String?) -> AmbianceSource? {
        let focus = sources.filter { $0.kind == .focus && $0.isAvailable }
        return focus.first { $0.id == last } ?? focus.first
    }
}
#endif
