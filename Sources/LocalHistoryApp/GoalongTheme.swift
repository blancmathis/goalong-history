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
        static let text = adaptive(light: 0x0D100E, dark: 0xF2F6EF)
        static let secondaryText = adaptive(light: 0x566252, dark: 0xA0B0A4, highLight: 0x35422F, highDark: 0xC0CCC2)
        static let success = adaptive(light: 0x286A3B, dark: 0x98D7A5)
        static let warning = adaptive(light: 0x80601A, dark: 0xEED08C)
        static let danger = adaptive(light: 0xAB3F34, dark: 0xFFADA0)
        static let privateTint = adaptive(light: 0x6E52A0, dark: 0xC7B4E8)
        static let teal = adaptive(light: 0x256C68, dark: 0x87CCC1)
        static let sidebarBackground = adaptive(light: 0xEAE7DC, dark: 0x0B100D)
        static let pageBackground = adaptive(light: 0xF4F2EA, dark: 0x101712)
        static let cardBackground = adaptive(light: 0xFAF9F4, dark: 0x131B16)
        static let elevatedBackground = adaptive(light: 0xFFFFFF, dark: 0x1B251E)
        static let separator = adaptive(light: 0xD4D8CA, dark: 0x2D3C31, highLight: 0x828B76, highDark: 0x718A75)
        static let strongSeparator = adaptive(light: 0x828B76, dark: 0x718A75)
        static let hoverBackground = adaptive(light: 0xE7EADB, dark: 0x253228)
        static let selectionBackground = adaptive(light: 0xE0E8CA, dark: 0x2C3B22, highLight: 0xCFDDAA, highDark: 0x3B502C)
        static let pressedBackground = adaptive(light: 0xD6DFC2, dark: 0x34462A)
        /// Controls and inputs: raised buttons, sunken fields, quiet inset notes.
        static let controlBackground = adaptive(light: 0xFFFFFF, dark: 0x1B251E)
        static let controlBorder = adaptive(light: 0xCDD3C2, dark: 0x2F3F33, highLight: 0x828B76, highDark: 0x718A75)
        static let fieldBackground = adaptive(light: 0xFFFFFF, dark: 0x0C120E)
        static let insetBackground = adaptive(light: 0xF0EFE6, dark: 0x18211B)
        static let segmentSelected = adaptive(light: 0xFFFFFF, dark: 0x2A3A2E)
        static let segmentSelectedBorder = adaptive(light: 0xC9D0BC, dark: 0x3D5141)
        static let switchTrack = adaptive(light: 0xE2E4D8, dark: 0x223026)
        static let switchKnob = adaptive(light: 0xFFFFFF, dark: 0xB4C2B7)
        static let placeholder = adaptive(light: 0x8A9486, dark: 0x66766A, highLight: 0x5E6859, highDark: 0x93A396)
        static let pageInset: CGFloat = 28
        static let cardInset: CGFloat = 20
        static let cardRadius: CGFloat = 14
        static let controlRadius: CGFloat = 8
        static let readableWidth: CGFloat = 920
        static let pageTitleFont = Font.system(size: 26, weight: .semibold)

        static func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }

        private static func adaptive(light: UInt32, dark: UInt32,
                                     highLight: UInt32? = nil, highDark: UInt32? = nil) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                // Preserve exact increased-contrast identities before matching Aqua.
                switch appearance.name {
                case .accessibilityHighContrastDarkAqua: return rgb(highDark ?? dark)
                case .accessibilityHighContrastAqua: return rgb(highLight ?? light)
                default:
                    return rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
                }
            })
        }
    }
#endif
