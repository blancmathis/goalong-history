#if os(macOS)
import SwiftUI

/// A disclosure header is a real, full-width button in every window and sheet.
/// Only the header toggles expansion: links and controls in the content remain independent.
struct GoalongDisclosureGroup<Label: View, Content: View>: View {
    @State private var localExpansion = false
    private let externalExpansion: Binding<Bool>?
    private let content: Content
    private let label: Label

    init(isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder label: () -> Label) {
        externalExpansion = isExpanded
        self.content = content()
        self.label = label()
    }

    init(_ title: LocalizedStringKey, isExpanded: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) where Label == Text {
        externalExpansion = isExpanded
        self.content = content()
        label = Text(title)
    }

    var body: some View {
        DisclosureGroup(isExpanded: externalExpansion ?? $localExpansion) {
            content
        } label: {
            label
        }
        .disclosureGroupStyle(GoalongDisclosureGroupStyle())
    }
}

struct GoalongDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(LHNavigationButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityValue(configuration.isExpanded ? "Déplié" : "Replié")
            .accessibilityHint(configuration.isExpanded ? "Masquer le contenu" : "Afficher le contenu")

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
            }
        }
    }
}
#endif
