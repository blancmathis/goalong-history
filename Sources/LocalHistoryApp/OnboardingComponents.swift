#if os(macOS)
    import SwiftUI

    extension LocalHistoryOnboardingView {
        func featureCard(symbol: String, title: String, detail: String) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LHTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(LHTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading)
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
        }

        func boundaryCard(symbol: String, tint: Color, title: String, items: [String]) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                            .padding(.top, 2)
                        Text(item)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(17)
            .frame(maxWidth: .infinity, minHeight: 225, alignment: .topLeading)
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.075)))
        }

        func callout(symbol: String, tint: Color, title: String, detail: String) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }

        func statusPill(granted: Bool) -> some View {
            Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(granted ? LHTheme.success : LHTheme.warning)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background((granted ? LHTheme.success : LHTheme.warning).opacity(0.1), in: Capsule())
        }

        func finalCheckRow(symbol: String, title: String, detail: String, complete: Bool) -> some View {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(complete ? LHTheme.success : LHTheme.warning)
                    .frame(width: 30, height: 30)
                    .background((complete ? LHTheme.success : LHTheme.warning).opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(complete ? LHTheme.success : LHTheme.warning)
            }
            .padding(.vertical, 12)
        }
    }
#endif
