#if os(macOS)
    import Combine
    import SwiftUI

    // What an empty screen says and how the app confirms: the two places, besides the thread
    // itself (GoalongThread.swift), where Goalong speaks in its own voice. Everything here
    // answers a person's action or appears once; nothing loops.

    /// The sort of thing an empty or state view reports (déc. 9 et 14, T-043 R-10): one distinct glyph per sort, so
    /// « pas encore », « à autoriser » and « indisponible » never look alike. Shared by `GoalongEmptyState`,
    /// `EmptyStateView` and `StatusPill`.
    enum GoalongStateKind: Equatable {
        /// Nothing yet: data will come by itself.
        case notYet
        /// Needs an access or a setting the person must give.
        case needsPermission
        /// Cannot work here (missing app, unsupported, failed).
        case unavailable
        /// The list is simply empty (nothing matches, nothing added).
        case empty
        /// A pill only: the thing works or is on.
        case ready
        /// A pill only: needs a look (partial, to verify, broken).
        case attention

        var symbol: String {
            switch self {
            case .notYet: return "clock"
            case .needsPermission: return "lock.shield"
            case .unavailable: return "nosign"
            case .empty: return "tray"
            case .ready: return "checkmark.circle.fill"
            case .attention: return "exclamationmark.circle.fill"
            }
        }
    }

    /// An empty screen: one sentence that says what is missing and, at most, one named action (déc. 9, T-043 R-11).
    /// No dotted thread, no decorative mark: the state glyph of its required `kind` only. Set directly on the page, or inside a
    /// group when it replaces a list.
    struct GoalongEmptyState<Actions: View>: View {
        let title: String
        let message: String
        let kind: GoalongStateKind
        @ViewBuilder var actions: () -> Actions

        /// Several free actions. Kept for the existing callers; new code names its one action with
        /// `init(title:message:kind:actionTitle:prominent:action:)`.
        @available(*, deprecated, message: "Une seule action nommée : init(title:message:kind:actionTitle:prominent:action:) (T-043 R-11)")
        init(title: String, kind: GoalongStateKind, message: String, @ViewBuilder actions: @escaping () -> Actions) {
            self.title = title
            self.message = message
            self.kind = kind
            self.actions = actions
        }

        fileprivate init(uncheckedTitle title: String, kind: GoalongStateKind, message: String,
                         @ViewBuilder actions: @escaping () -> Actions) {
            self.title = title
            self.message = message
            self.kind = kind
            self.actions = actions
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: kind.symbol).font(.system(size: 18, weight: .medium))
                    .foregroundStyle(LHTheme.secondaryText)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
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
        init(title: String, kind: GoalongStateKind, message: String) {
            self.init(uncheckedTitle: title, kind: kind, message: message) { EmptyView() }
        }
    }

    /// The one named action of an empty state: primary (lime) when it is the screen's recommended step, otherwise
    /// secondary (déc. 7).
    struct GoalongEmptyStateAction: View {
        /// Shown when a caller passes an empty title, never a crash (R281-10).
        static let fallbackTitle = "Continuer"
        let title: String
        var prominent = true
        let action: () -> Void

        init(title: String, prominent: Bool = true, action: @escaping () -> Void) {
            self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.fallbackTitle : title
            self.prominent = prominent
            self.action = action
        }

        var body: some View {
            if prominent {
                Button(title, action: action).buttonStyle(LHPrimaryButtonStyle())
            } else {
                Button(title, action: action).buttonStyle(LHSecondaryButtonStyle())
            }
        }
    }

    extension GoalongEmptyState where Actions == GoalongEmptyStateAction {
        /// One sentence and one named action (« Ouvrir les réglages d’enregistrement », never « Ouvrir »).
        init(title: String, kind: GoalongStateKind, message: String, actionTitle: String,
             prominent: Bool = true, action: @escaping () -> Void) {
            self.init(uncheckedTitle: title, kind: kind, message: message) {
                GoalongEmptyStateAction(title: actionTitle, prominent: prominent, action: action)
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

        #if DEBUG
        /// Test gallery: no toast appears by itself; `setForTesting` shows a fixed one.
        static var suppressedForTesting = false
        func setForTesting(_ message: String?, symbol: String = "checkmark") {
            dismissal?.cancel(); dismissal = nil
            current = message.map { Toast(message: $0, symbol: symbol) }
        }
        #endif

        func show(_ message: String, symbol: String = "checkmark") {
            #if DEBUG
            if Self.suppressedForTesting { return }
            #endif
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
                // R4d-4: a stroked `Capsule` drew a vertical tick at each end. The border is a fill instead:
                // the border colour in the capsule, the surface in a capsule 1 pt smaller.
                Capsule(style: .continuous).fill(LHTheme.elevatedBackground)
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                    .overlay(Capsule(style: .continuous).fill(LHTheme.controlBorder)
                        .overlay(Capsule(style: .continuous).fill(LHTheme.elevatedBackground).padding(1)))
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
