#if os(macOS)
    import Combine
    import SwiftUI

    // What an empty screen says and how the app confirms: the two places, besides the thread
    // itself (GoalongThread.swift), where Goalong speaks in its own voice. Everything here
    // answers a person's action or appears once; nothing loops.

    /// An empty screen is a thread that has not started: what is missing and the one step
    /// that fixes it. Set directly on the page, or inside a group when it replaces a list.
    struct GoalongEmptyState<Actions: View>: View {
        let title: String
        let message: String
        @ViewBuilder var actions: () -> Actions

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                GoalongThreadPlaceholder().padding(.bottom, 4)
                Text(title).font(LHTheme.sectionTitleFont).tracking(-0.2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(message).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                HStack(spacing: 10) { actions() }.padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    extension GoalongEmptyState where Actions == EmptyView {
        init(title: String, message: String) {
            self.init(title: title, message: message) { EmptyView() }
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
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            }
            .onAppear {
                if reduceMotion { drawn = 1 } else { withAnimation(LHTheme.ease(0.3).delay(0.12)) { drawn = 1 } }
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
