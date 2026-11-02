#if os(macOS)
    import AppKit
    import SwiftUI

    /// Native translation of goalong-website/styles/landing/shared.css.
    /// Lime fills always use dark ink; light-mode control tint is a readable olive.
    enum LHTheme {
        static let accent = adaptive(light: 0x4B611B, dark: 0xD3F35F, highLight: 0x354B0C, highDark: 0xE2FF7A)
        static let actionBackground = Color(nsColor: rgb(0xD3F35F))
        static let actionHover = Color(nsColor: rgb(0xE2FF7A))
        static let actionPressed = Color(nsColor: rgb(0xBDD94F))
        static let onAccent = Color(nsColor: rgb(0x18210D))
        static let text = adaptive(light: 0x0D100E, dark: 0xF2F6EF, highLight: 0x000000, highDark: 0xFFFFFF)
        /// T-043 R-1: ≥ 5:1 on every surface (page, card, group, sidebar, hover, selection) in both modes; dark 6:1.
        static let secondaryText = adaptive(light: 0x566252, dark: 0xAEBBB1, highLight: 0x35422F, highDark: 0xCCD6CE)
        static let success = adaptive(light: 0x286A3B, dark: 0x98D7A5, highLight: 0x1D5530, highDark: 0xB0E6BB)
        static let warning = adaptive(light: 0x7A5B19, dark: 0xEED08C, highLight: 0x654A10, highDark: 0xF7DFA6)
        /// T-043 R-13: 4.5:1 (light) and 6.7:1 (dark) on every surface; stronger with Increase Contrast.
        static let danger = adaptive(light: 0xA63D32, dark: 0xFFADA0, highLight: 0x8E2A22, highDark: 0xFFC2B8)
        static let privateTint = adaptive(light: 0x6D519E, dark: 0xC7B4E8, highLight: 0x563E85, highDark: 0xD8CAF0)
        static let teal = adaptive(light: 0x246A66, dark: 0x87CCC1, highLight: 0x1A5552, highDark: 0xA1DDD3)
        static let sidebarBackground = adaptive(light: 0xEAE7DC, dark: 0x0B100D)
        static let pageBackground = adaptive(light: 0xF4F2EA, dark: 0x101712)
        static let cardBackground = adaptive(light: 0xFAF9F4, dark: 0x131B16)
        static let elevatedBackground = adaptive(light: 0xFFFFFF, dark: 0x1B251E)
        /// Decorative hairline between rows and around groups (not a control edge, WCAG 1.4.11 does not apply):
        /// one step stronger so dark groups read apart from the page (T-043 R-4).
        static let separator = adaptive(light: 0xCFD3C5, dark: 0x36443A, highLight: 0x828B76, highDark: 0x718A75)
        /// ≥ 3:1 on every surface, sidebar, selection and pressed included (T-043 R-4).
        static let strongSeparator = adaptive(light: 0x777E6B, dark: 0x718A75, highLight: 0x5E6655, highDark: 0x8FA592)
        static let hoverBackground = adaptive(light: 0xE7EADB, dark: 0x1F2B23)
        static let selectionBackground = adaptive(light: 0xE0E8CA, dark: 0x2C3B22, highLight: 0xCFDDAA, highDark: 0x3B502C)
        static let pressedBackground = adaptive(light: 0xD6DFC2, dark: 0x2A3A2E)
        /// Controls and inputs: raised buttons, sunken fields, quiet inset notes.
        static let controlBackground = adaptive(light: 0xFFFFFF, dark: 0x1B251E)
        /// Edge of fields, checkboxes and raised buttons: ≥ 3:1 on the field and every surface, pressed included (déc. 3, T-043 R-4).
        static let controlBorder = adaptive(light: 0x777E6B, dark: 0x76887B, highLight: 0x666E5C, highDark: 0x8AA08E)
        static let fieldBackground = adaptive(light: 0xFFFFFF, dark: 0x0C120E)
        static let insetBackground = adaptive(light: 0xEFEEE4, dark: 0x18211B)
        static let segmentSelected = adaptive(light: 0xFFFFFF, dark: 0x2A3A2E)
        static let segmentSelectedBorder = adaptive(light: 0xC9D0BC, dark: 0x3D5141, highLight: 0x666E5C, highDark: 0x8AA08E)
        /// Off track: an empty well in both modes, so on (ink) and off read apart at a glance (R7, UI-17A). Light: a pale
        /// well, 15:1 against the ink on track; its 1 pt strongSeparator edge is ≥ 3:1 on page, card and inset (WCAG
        /// 1.4.11) and the white knob keeps a 4.2:1 edge on it (`switchKnobEdge`). Dark: a dark well, 12:1 against the on
        /// track; the strongSeparator edge keeps it ≥ 4.2:1 on every background (UI-14, écran 27) and the knob is 12:1.
        static let switchTrack = adaptive(light: 0xE4E7DB, dark: 0x1F2B23)
        /// Hover of the off track: one step darker than the well in light, lighter in dark.
        static let switchTrackHover = adaptive(light: 0xD9DDCE, dark: 0x26332A)
        static let switchKnob = adaptive(light: 0xFFFFFF, dark: 0xE6EDE7)
        /// Edge of the off knob: light only (tertiary text, 4.6:1 on the pale well); the dark knob is 12:1 on its well.
        static let switchKnobEdge = Color(nsColor: NSColor(name: nil) { appearance in
            switch style(of: appearance) {
            case (dark: true, _): return .clear
            case (dark: false, high: true): return LHTheme.rgb(0x4C5747)
            case (dark: false, high: false): return LHTheme.rgb(0x5E6859)
            }
        })
        /// T-043 R-3: ≥ 4.6:1 on the field (and page/card), still clearly paler than typed text (text is 15:1 / 11:1).
        static let placeholder = adaptive(light: 0x666F61, dark: 0x828F85, highLight: 0x535D4F, highDark: 0xA3B1A6)
        /// Chart axes and the resting thread: quieter than secondary text, never body copy. T-043 R-1: ≥ 4.6:1 on
        /// every surface, pressed included, in both modes (it was 3.5:1 on dark selection).
        static let tertiaryText = adaptive(light: 0x5A6355, dark: 0x96A59B, highLight: 0x4C5747, highDark: 0xB1BEB4)
        /// The label of a disabled control (déc. 3, T-043 R-5): ≥ 3:1 on every surface (selection and pressed included), and
        /// clearly weaker than an active label (ink, 11–15:1). Drawn at full opacity, never faded.
        static let disabledText = adaptive(light: 0x757E70, dark: 0x74857A, highLight: 0x5E6859, highDark: 0x9AAA9E)
        /// A loading indicator (T-043 R-6): tinted like secondary text, ≥ 3:1 on every surface.
        static let progressTint = secondaryText

        /// The three states of active time, always in this order. Lime is work as the person
        /// defined it; time outside work is a calm periwinkle, never a warning; what is not
        /// classified yet stays neutral. Validated for colour-vision separation on both pages.
        static let workData = adaptive(light: 0x56701A, dark: 0xD3F35F)
        static let otherData = adaptive(light: 0x5A69C4, dark: 0x8497F2)
        static let unclassifiedData = adaptive(light: 0x8A9184, dark: 0x66766A, highLight: 0x6B7366, highDark: 0x93A396)

        // 4-point grid.
        static let pageInset: CGFloat = 32
        /// Space under the last block of every scrolling page (UI-sombre-25b: one value, not 40 and 48).
        static let pageBottomInset: CGFloat = 40
        static let sectionSpacing: CGFloat = 40
        static let cardInset: CGFloat = 16
        /// One corner per level: data marks, controls, groups.
        static let markRadius: CGFloat = 3
        static let controlRadius: CGFloat = 8
        static let cardRadius: CGFloat = 12
        static let cardCorner: CGFloat = 12
        static let readableWidth: CGFloat = 760

        /// One family, San Francisco. Character comes from scale and tight tracking, as on the site.
        static let heroFont = Font.system(size: 56, weight: .bold)
        static let heroTracking: CGFloat = -1.8
        static let pageTitleFont = Font.system(size: 28, weight: .bold)
        static let pageTitleTracking: CGFloat = -0.6
        static let sheetTitleFont = Font.system(size: 22, weight: .bold)
        static func figureFont(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
        /// A title set directly on the page, above content that has no frame.
        static let sectionTitleFont = Font.system(size: 17, weight: .semibold)
        /// The title of a group of controls, inside its surface.
        static let cardTitleFont = Font.system(size: 15, weight: .semibold)

        /// The site's curve for everything that changes state; one short spring for what
        /// answers a press.
        static func ease(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
        static let hover = ease(0.12)
        static let settle = ease(0.24)
        static let draw = ease(0.7)
        static let press = Animation.spring(response: 0.24, dampingFraction: 0.8)

        static func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }

        /// Increase Contrast for the colour tokens: nil follows the Mac (Accessibility › Display › Increase contrast).
        /// SwiftUI hands a dynamic NSColor a plain Aqua or Dark Aqua appearance even under Increase Contrast, so the
        /// appearance alone never picks the high* values (R281-1). The gallery and the tests set it.
        static var increasedContrastOverride: Bool?

        /// Dark or light, and whether Increase Contrast is on, for one appearance.
        static func style(of appearance: NSAppearance) -> (dark: Bool, high: Bool) {
            // A high-contrast appearance by name, if a system ever hands one; on macOS 13+ even
            // `NSAppearance(named: .accessibilityHighContrastAqua)` is plain Aqua, so the Mac's setting decides.
            switch appearance.name {
            case .accessibilityHighContrastDarkAqua: return (true, true)
            case .accessibilityHighContrastAqua: return (false, true)
            default:
                return (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                        increasedContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            }
        }

        private static func adaptive(light: UInt32, dark: UInt32,
                                     highLight: UInt32? = nil, highDark: UInt32? = nil) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                switch style(of: appearance) {
                case (dark: true, high: true): return rgb(highDark ?? dark)
                case (dark: true, high: false): return rgb(dark)
                case (dark: false, high: true): return rgb(highLight ?? light)
                case (dark: false, high: false): return rgb(light)
                }
            })
        }
    }
#endif
