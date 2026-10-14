#if os(macOS)
    import AppKit
    import LocalHistoryCore
    import SwiftUI

    /// Marks of the `make dev` copy. A release has no GoalongBuildChannel key and shows none of them.
    enum GoalongDevChannelMarks {
        static var channel: GoalongBuildChannel { .current }

        /// A small orange dot on a menu bar item. The template image stays untouched, so it keeps
        /// the system tint in light and dark menu bars and the item keeps its size.
        @MainActor static func badge(_ button: NSStatusBarButton?) {
            guard channel.isDevelopment, let button,
                  !button.subviews.contains(where: { $0.identifier == dotIdentifier }) else { return }
            let dot = NSView()
            dot.identifier = dotIdentifier
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            ])
        }

        private static let dotIdentifier = NSUserInterfaceItemIdentifier("goalong.dev.dot")
    }

    /// "Copie de développement · données isolées" at the top of the menu bar panel and main windows.
    /// Discreet when the data is isolated; loud when the dev copy writes the real data.
    struct GoalongDevBanner: View {
        private let channel = GoalongBuildChannel.current

        var body: some View {
            if let label = channel.developmentLabel {
                let real = channel.dataMode == .real
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text(label)
                        .font(.system(size: 11, weight: real ? .semibold : .medium))
                        .foregroundStyle(real ? Color.black : LHTheme.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(real ? Color.orange : Color.orange.opacity(0.10))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
    }
#endif
