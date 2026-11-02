#if os(macOS)
    import SwiftUI

    /// A local-only website mark. It deliberately avoids remote favicon services so a
    /// private browsing history is never sent to a third party just to decorate the UI.
    /// Goalong keeps no favicon on disk, so every site shows its monogram: the first letter of its domain on a
    /// quiet tile, at least 16 pt, so a row of sites stays tellable apart (never a row of identical globes).
    struct WebsiteIconView: View {
        static let minimumSize: CGFloat = 16
        let host: String
        var size: CGFloat = 34

        static func initial(for host: String) -> String {
            let normalized = SharingSubjectKey.normalizedHost(host)
            guard let first = normalized.first(where: { $0.isLetter || $0.isNumber }) else { return "•" }
            return String(first).uppercased()
        }

        var body: some View {
            let side = max(size, Self.minimumSize)
            let shape = RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
            Text(Self.initial(for: host))
                .font(.system(size: max(10, side * 0.5), weight: .semibold, design: .rounded))
                .foregroundStyle(LHTheme.text)
                .frame(width: side, height: side)
                .background(shape.fill(LHTheme.insetBackground))
                .overlay(shape.strokeBorder(LHTheme.separator))
                .accessibilityLabel("Site \(host)")
        }
    }
#endif
