#if os(macOS)
import AppKit
import SwiftUI

/// Additive local preference, also used by isolated rendering tests. A false value
/// never overrides the read-only system accessibilityReduceMotion preference.
private struct GoalongReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var goalongReduceMotion: Bool {
        get { self[GoalongReducedMotionKey.self] }
        set { self[GoalongReducedMotionKey.self] = newValue }
    }
}

/// Exact rest mark and attached G arm. Native vector paths, not an embedded web view.
struct GoalongPassageShape: Shape {
    var q = 0.0
    var b = 0.0
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ p: GoalongMotion.Point) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width / 26, y: rect.minY + p.y * rect.height / 18)
        }
        for (source, closed) in [(GoalongMotion.loop, true), (GoalongMotion.arm, false)] {
            let points = GoalongMotion.geometry(source, q: q, b: b)
            path.move(to: point(points[0][0]))
            for i in 0..<(closed ? points.count : points.count - 1) {
                let next = (i + 1) % points.count
                path.addCurve(to: point(points[next][0]), control1: point(points[i][2]), control2: point(points[next][1]))
            }
            if closed { path.closeSubpath() }
        }
        return path
    }
}

/// A real operation owns isActive. Navigation and results never await this view.
struct GoalongActivityMark: View {
    let isActive: Bool
    var width: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.goalongReduceMotion) private var localReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || localReduceMotion }
    @State private var motion = GoalongMotion.State()
    @State private var mounted = false
    @State private var windowVisible = false
    @State private var ticking = false
    private var time: Double { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !mounted || !windowVisible || !ticking || reduceMotion)) { _ in
            let sample = reduceMotion ? GoalongMotion.Sample.rest : motion.sample(at: time)
            GoalongPassageShape(q: sample.p[0], b: sample.p[1])
                .stroke(LHTheme.accent, style: StrokeStyle(lineWidth: 2.1 * width / 26, lineCap: .round, lineJoin: .round))
                .frame(width: width, height: width * 18 / 26)
        }
        .frame(width: width, height: width * 18 / 26)
        .background(GoalongMotionVisibility { windowVisible = $0 })
        .accessibilityHidden(true)
        .onAppear { mounted = true }
        .onDisappear { mounted = false; ticking = false }
        .task(id: isActive) {
            guard isActive || motion.busy else { motion.settle(); ticking = false; return }
            motion.setBusy(isActive, at: time)
            ticking = true
            if !isActive {
                do { try await Task.sleep(nanoseconds: 300_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                motion.settle()
                ticking = false
            }
        }
        .onChange(of: reduceMotion) { reduced in
            // Enabling motion again starts from the displayed static pose.
            if !reduced {
                motion.settle()
                motion.setBusy(isActive, at: time)
                ticking = isActive
            }
        }
    }
}

/// Preserve native determinate progress, labels, values and control semantics.
struct GoalongProgressViewStyle: ProgressViewStyle {
    @Environment(\.controlSize) private var controlSize
    private var width: CGFloat {
        switch controlSize {
        case .mini, .small: return 24
        case .large: return 40
        default: return 32
        }
    }
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if let fraction = configuration.fractionCompleted {
            ProgressView(value: fraction, total: 1) {
                configuration.label
            } currentValueLabel: {
                configuration.currentValueLabel
            }
            .progressViewStyle(.linear)
        } else if let label = configuration.label {
            HStack(spacing: 8) {
                GoalongActivityMark(isActive: true, width: width)
                label
            }
            .accessibilityElement(children: .combine)
        } else {
            GoalongActivityMark(isActive: true, width: width)
                .accessibilityHidden(false)
                .accessibilityLabel("Chargement en cours")
        }
    }
}

/// Stop the display clock when the owning window is hidden, miniaturized or occluded.
/// Observes only its own AppKit window; no process/service is installed.
private struct GoalongMotionVisibility: NSViewRepresentable {
    let change: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe(change: change) }
    func updateNSView(_ view: Probe, context: Context) { view.change = change }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: NSView {
        var change: (Bool) -> Void
        private var observations: [NSObjectProtocol] = []
        init(change: @escaping (Bool) -> Void) {
            self.change = change
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                    observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.report()
                    })
                }
            }
            report()
        }
        private func report() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            DispatchQueue.main.async { [weak self] in self?.change(visible) }
        }
        func stop() {
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            observations.removeAll()
        }
        deinit { stop() }
    }
}
#endif
