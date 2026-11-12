#if os(macOS)
import AppKit
import AppleScreenTime
import SwiftUI

/// T-054: « Animations » in Réglages. Off, or macOS « Réduire les animations » on, and the app moves nothing:
/// SwiftUI transactions lose their animation under every root (`goalongControls()` carries `goalongMotion()`), the
/// views that drive their own motion read `goalongReduceMotion`, and the AppKit ones ask `reduced()`.
enum GoalongMotionPreference {
    /// True = animations off. An absent key is false: animations on, as before.
    static let offKey = "goalong.motion.off"
    static func isOff(in defaults: UserDefaults = GoalongDefaults.standard) -> Bool { defaults.bool(forKey: offKey) }
    /// The app's switch or macOS « Réduire les animations ». For AppKit code outside SwiftUI.
    @MainActor static func reduced(in defaults: UserDefaults = GoalongDefaults.standard) -> Bool {
        isOff(in: defaults) || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Under a root: with animations off (or Reduce Motion), every transaction below runs without animation, and the
/// views with their own clock (thread trace, brand mark) show their still state. Always the same modifier, whatever
/// the value: turning the switch never rebuilds the views under it.
private struct GoalongMotionSwitch: ViewModifier {
    @AppStorage(GoalongMotionPreference.offKey) private var off = false
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.goalongReduceMotion) private var inherited

    func body(content: Content) -> some View {
        let still = off || system || inherited
        return content
            .environment(\.goalongReduceMotion, still)
            .transaction { if still { $0.disablesAnimations = true; $0.animation = nil } }
    }
}

extension View {
    /// The app's motion setting for a window, sheet or panel root (`goalongControls()` already applies it).
    func goalongMotion() -> some View { modifier(GoalongMotionSwitch()) }
}

/// The switch itself, on the Réglages home.
struct GoalongMotionSettings: View {
    @AppStorage(GoalongMotionPreference.offKey) private var off = false
    @Environment(\.accessibilityReduceMotion) private var system

    static func matches(_ raw: String) -> Bool {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        return "animations mouvement affichage".localizedStandardContains(query)
            || query.split(whereSeparator: \.isWhitespace).contains { $0.count >= 4 && "animations mouvement".localizedStandardContains(String($0)) }
    }

    var body: some View {
        GoalongSettingsGroup(title: "Affichage") {
            Toggle("Animations", isOn: Binding(get: { !off }, set: { off = !$0 }))
                .toggleStyle(.goalongSwitch)
                .accessibilityIdentifier("settings-animations")
            Text(system
                 ? "« Réduire les animations » est actif dans macOS : Goalong n’anime rien, quel que soit ce réglage."
                 : "Désactivées, les pages changent d’un coup : aucun fil tracé, aucun chiffre qui défile, aucun glissement.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
