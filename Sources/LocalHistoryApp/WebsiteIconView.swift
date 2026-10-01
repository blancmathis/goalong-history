#if os(macOS)
    import SwiftUI

    /// A local-only website mark. It deliberately avoids remote favicon services so a
    /// private browsing history is never sent to a third party just to decorate the UI.
    struct WebsiteIconView: View {
        let host: String
        var size: CGFloat = 34

        private var initial: String {
            let normalized = SharingSubjectKey.normalizedHost(host)
            guard let first = normalized.first else { return "•" }
            return String(first).uppercased()
        }

        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LHTheme.insetBackground)
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(LHTheme.separator)
                Text(initial)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(LHTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Image(systemName: "globe")
                    .font(.system(size: size * 0.26, weight: .semibold))
                    .foregroundStyle(LHTheme.secondaryText)
                    .padding(size * 0.04)
                    .background(LHTheme.cardBackground, in: Circle())
                    .offset(x: size * 0.1, y: size * 0.1)
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Website \(host)")
        }
    }
#endif
