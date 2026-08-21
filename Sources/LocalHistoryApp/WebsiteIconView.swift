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
                    .fill(LHTheme.teal.opacity(0.12))
                Text(initial)
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(LHTheme.teal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Image(systemName: "globe")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(LHTheme.teal)
                    .padding(size * 0.07)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: size * 0.06, y: size * 0.06)
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Website \(host)")
        }
    }
#endif
