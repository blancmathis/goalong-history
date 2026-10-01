#if os(macOS)
    import Combine
    import SwiftUI

    // Goalong's signature: the trail. A day is a path through the forest; one lime thread
    // marks where you are on it (sidebar), where a journey starts (empty states) and what
    // just happened (confirmations). Everything here answers a person's action or appears
    // once; nothing loops, and Reduce Motion gets the finished state immediately.

    /// The Goalong mark, traced like a path being walked. It draws itself once per launch
    /// and retraces when hovered.
    struct GoalongAnimatedMark: View {
        var lineWidth: CGFloat = 2.1
        private static var hasIntroduced = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var progress: CGFloat = GoalongAnimatedMark.hasIntroduced ? 1 : 0

        var body: some View {
            GoalongMark()
                .trim(from: 0, to: progress)
                .stroke(LHTheme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .onAppear {
                    guard !Self.hasIntroduced else { return }
                    Self.hasIntroduced = true
                    trace(duration: 1.2, delay: 0.15)
                }
                .onHover { inside in if inside { trace(duration: 0.7, delay: 0) } }
        }

        private func trace(duration: Double, delay: Double) {
            guard !reduceMotion else { progress = 1; return }
            progress = 0
            withAnimation(.easeInOut(duration: duration).delay(delay)) { progress = 1 }
        }
    }

    /// A winding trail from a start ring to a lime waypoint.
    struct GoalongTrailPath: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
            path.move(to: p(0.04, 0.78))
            path.addCurve(to: p(0.38, 0.42), control1: p(0.18, 0.80), control2: p(0.20, 0.38))
            path.addCurve(to: p(0.66, 0.62), control1: p(0.52, 0.45), control2: p(0.52, 0.70))
            path.addCurve(to: p(0.94, 0.22), control1: p(0.80, 0.55), control2: p(0.82, 0.24))
            return path
        }
    }

    struct GoalongTrailIllustration: View {
        var width: CGFloat = 132
        var height: CGFloat = 54
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var drawn: CGFloat = 0
        @State private var arrived = false

        var body: some View {
            ZStack(alignment: .topLeading) {
                GoalongTrailPath()
                    .stroke(LHTheme.secondaryText.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
                GoalongTrailPath()
                    .trim(from: 0, to: drawn * 0.999)
                    .stroke(LHTheme.accent.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Circle().strokeBorder(LHTheme.secondaryText.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                    .position(x: width * 0.04, y: height * 0.78)
                Circle().fill(LHTheme.accent)
                    .frame(width: 10, height: 10)
                    .shadow(color: LHTheme.accent.opacity(0.5), radius: 6)
                    .position(x: width * 0.94, y: height * 0.22)
                    .scaleEffect(arrived ? 1 : 0.4, anchor: .center)
                    .opacity(arrived ? 1 : 0)
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            .onAppear {
                guard drawn == 0 else { return }
                if reduceMotion { drawn = 1; arrived = true; return }
                withAnimation(.easeInOut(duration: 1.1).delay(0.1)) { drawn = 1 }
                // The waypoint lights up when the walked line reaches it.
                withAnimation(LHTheme.press.delay(1.1)) { arrived = true }
            }
        }
    }

    /// An empty screen is the start of a trail: what is missing and the one step that fixes it.
    struct GoalongEmptyState<Actions: View>: View {
        let title: String
        let message: String
        @ViewBuilder var actions: () -> Actions

        var body: some View {
            HStack(alignment: .center, spacing: 26) {
                GoalongTrailIllustration()
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 19, weight: .semibold, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text(message).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) { actions() }.padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 26).padding(.vertical, 24)
            .background(GoalongSurface(corner: LHTheme.cardRadius))
        }
    }

    extension GoalongEmptyState where Actions == EmptyView {
        init(title: String, message: String) {
            self.init(title: title, message: message) { EmptyView() }
        }
    }

    // MARK: - Contour backdrop

    /// Faint contour lines, like a forest survey map, in the top corner of every page.
    /// Static, drawn once, fixed behind scrolling content: atmosphere, never information.
    struct GoalongContourBackdrop: View {
        @Environment(\.colorScheme) private var scheme
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            Canvas(rendersAsynchronously: true) { context, size in
                let center = CGPoint(x: size.width - 70, y: -30)
                let base = scheme == .dark ? LHTheme.accent : Color(nsColor: LHTheme.rgb(0x4B611B))
                for ring in 0..<11 {
                    let radius = 70 + CGFloat(ring) * 30
                    var path = Path()
                    let steps = 160
                    for step in 0...steps {
                        let angle = Double(step) / Double(steps) * 2 * .pi
                        let wobble = 1 + 0.07 * sin(3 * angle + Double(ring) * 0.55) + 0.035 * sin(5 * angle - Double(ring) * 0.9)
                        let point = CGPoint(x: center.x + cos(angle) * radius * wobble * 1.25,
                                            y: center.y + sin(angle) * radius * wobble)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    let strength = (scheme == .dark ? 0.085 : 0.11) * (1 - Double(ring) / 13)
                    context.stroke(path, with: .color(base.opacity(strength)), lineWidth: ring % 4 == 0 ? 1.2 : 0.8)
                }
            }
            .frame(height: 340)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
            .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5)))
            .opacity(contrast == .increased ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    extension View {
        /// Page canvas: forest background with the contour backdrop in its top corner.
        func goalongPageBackground() -> some View {
            background(alignment: .top) {
                ZStack(alignment: .top) {
                    LHTheme.pageBackground
                    GoalongContourBackdrop()
                }
            }
        }
    }

    // MARK: - Confirmation toast

    /// Saying "Enregistré" where the person is looking, then getting out of the way.
    @MainActor final class GoalongToastCenter: ObservableObject {
        static let shared = GoalongToastCenter()
        struct Toast: Identifiable, Equatable {
            let id = UUID()
            let message: String
            var symbol = "checkmark"
        }
        @Published private(set) var current: Toast?
        private var dismissal: Task<Void, Never>?

        func show(_ message: String, symbol: String = "checkmark") {
            dismissal?.cancel()
            current = Toast(message: message, symbol: symbol)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            let id = current?.id
            dismissal = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                guard !Task.isCancelled, self?.current?.id == id else { return }
                self?.current = nil
            }
        }
    }

    struct GoalongToastHost: View {
        @ObservedObject private var center = GoalongToastCenter.shared
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ZStack {
                if let toast = center.current {
                    GoalongToastView(toast: toast)
                        .id(toast.id)
                        .transition(reduceMotion ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(reduceMotion ? nil : LHTheme.settle, value: center.current)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }

    private struct GoalongToastView: View {
        let toast: GoalongToastCenter.Toast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var drawn: CGFloat = 0

        var body: some View {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LHTheme.actionBackground)
                    if toast.symbol == "checkmark" {
                        GoalongCheckShape().trim(from: 0, to: drawn)
                            .stroke(LHTheme.onAccent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .padding(5.5)
                    } else {
                        Image(systemName: toast.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(LHTheme.onAccent)
                    }
                }
                .frame(width: 20, height: 20)
                Text(toast.message).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.text)
            }
            .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
            .background {
                Capsule().fill(LHTheme.elevatedBackground)
                    .overlay(Capsule().strokeBorder(LHTheme.controlBorder))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            }
            .onAppear {
                if reduceMotion { drawn = 1 } else { withAnimation(.easeOut(duration: 0.35).delay(0.12)) { drawn = 1 } }
            }
        }
    }

    struct GoalongCheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
            return path
        }
    }
#endif
