#if os(macOS)
import SwiftUI

/// T-057 idée 2 (maquette): the choice « Séance de travail » / « Blocage ponctuel » is said out loud. Before, an empty
/// « Intention » field silently chose the engine (a block), a filled one chose Concentration (timer, breaks, review).
enum SessionMode: String, Hashable, CaseIterable, Identifiable {
    case work, block
    var id: String { rawValue }
    var title: String { self == .work ? "Séance de travail" : "Blocage ponctuel" }
    var symbol: String { self == .work ? "timer" : "nosign" }
    /// What you get, in one line, and what you do not.
    var promise: String {
        self == .work ? "Minuteur, repos et bilan. Vous nommez ce que vous faites."
                      : "Bloque les listes choisies maintenant, pour une durée. Sans minuteur ni bilan."
    }
    /// The mode a draft already implies, so an existing draft opens on what it would have done.
    static func implied(kind: FocusMode.Kind, intent: String, focusAvailable: Bool) -> SessionMode {
        if kind == .pomodoro || !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .work }
        return focusAvailable ? .work : .block
    }
}

/// Two cards side by side; the selected one carries the accent. A radio group for VoiceOver.
struct SessionModeChoice: View {
    @Binding var selection: SessionMode
    var blockUnavailable: String?
    var workUnavailable: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(SessionMode.allCases) { mode in
                let reason = mode == .work ? workUnavailable : blockUnavailable
                Button { if reason == nil { selection = mode } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: mode.symbol).font(.system(size: 14, weight: .medium)).accessibilityHidden(true)
                            Text(mode.title).font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                            Image(systemName: selection == mode ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13)).accessibilityHidden(true)
                        }
                        Text(reason ?? mode.promise).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(selection == mode ? LHTheme.accent : LHTheme.text)
                    .padding(12).frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(selection == mode ? LHTheme.selectionBackground : LHTheme.controlBackground))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(selection == mode ? LHTheme.accent : LHTheme.controlBorder, lineWidth: selection == mode ? 2 : 1))
                    .opacity(reason == nil ? 1 : 0.55)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel("\(mode.title). \(mode.promise)")
                .accessibilityIdentifier("block-rule-mode-\(mode.rawValue)")
            }
        }
    }
}
#endif
