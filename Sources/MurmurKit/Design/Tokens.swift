import AppKit
import SwiftUI

/// Design tokens from design/murmur-mockups.html ("Design tokens" board).
/// Light is the primary design; every color has a dark counterpart.
public enum Tokens {
    // Surfaces
    public static let windowBackground = dynamic(light: 0xF7F8FA, dark: 0x17181D)
    public static let elevated = dynamic(light: 0xFFFFFF, dark: 0x23252C)
    public static let chip = dynamic(light: rgba(255, 255, 255, 0.62), dark: rgba(255, 255, 255, 0.12))
    /// What glass becomes under Reduce Transparency: its opaque tint.
    public static let glassOpaque = dynamic(light: 0xF2F4F8, dark: 0x23252C)
    public static let separator = dynamic(light: rgba(20, 24, 40, 0.08), dark: rgba(255, 255, 255, 0.08))
    public static let stroke = dynamic(light: rgba(20, 24, 40, 0.12), dark: rgba(255, 255, 255, 0.13))
    public static let control = dynamic(light: rgba(20, 24, 40, 0.05), dark: rgba(255, 255, 255, 0.07))
    public static let controlStrong = dynamic(light: rgba(20, 24, 40, 0.09), dark: rgba(255, 255, 255, 0.13))

    // Labels
    public static let label = dynamic(light: 0x14161C, dark: 0xF5F6FA)
    public static let labelSecondary = dynamic(light: rgba(28, 32, 44, 0.78), dark: rgba(240, 242, 250, 0.74))
    public static let labelTertiary = dynamic(light: rgba(28, 32, 44, 0.62), dark: rgba(240, 242, 250, 0.58))

    // Accent: Ice by default. The only color in the chrome; it follows the choice in Settings.
    public static let accent = dynamic { Accent.current.fill(dark: $0) }
    public static let onAccent = dynamic { Accent.current.onFill(dark: $0) }
    public static let accentText = dynamic { Accent.current.text(dark: $0) }
    public static let accentSoft = dynamic { Accent.current.soft(dark: $0) }
    /// The accent, held back: the comparison bars in a chart.
    public static let accentMuted = dynamic { Accent.current.fill(dark: $0).withAlphaComponent($0 ? 0.32 : 0.26) }

    // Status. Reserved: never used for decoration.
    public static let recording = dynamic(light: 0xD92D20, dark: 0xFF6259)
    public static let recordingSoft = dynamic(light: rgba(217, 45, 32, 0.10), dark: rgba(255, 98, 89, 0.16))
    public static let success = dynamic(light: 0x1B8435, dark: 0x3DD467)
    public static let successSoft = dynamic(light: rgba(27, 132, 53, 0.12), dark: rgba(61, 212, 103, 0.15))
    public static let warning = dynamic(light: 0xA35400, dark: 0xFFB340)
    public static let warningSoft = dynamic(light: rgba(196, 110, 0, 0.13), dark: rgba(255, 179, 64, 0.14))
    /// Command mode only.
    public static let command = dynamic(light: 0x5A3FD0, dark: 0xB9B3FF)
    public static let commandSoft = dynamic(light: rgba(90, 63, 208, 0.10), dark: rgba(163, 156, 255, 0.16))

    public enum Radius {
        public static let keycap: CGFloat = 6
        public static let group: CGFloat = 14
        public static let card: CGFloat = 16
        public static let panel: CGFloat = 22
        public static let overlay: CGFloat = 24
        public static let window: CGFloat = 26
    }

    public enum Motion {
        public static let pulse: Double = 1.2
        public static let cardInOut: Double = 0.18
        public static let insertedHold: Double = 1.2
    }

    // MARK: construction helpers

    nonisolated static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    nonisolated static func hex(_ value: UInt32) -> NSColor {
        rgba(CGFloat((value >> 16) & 0xFF), CGFloat((value >> 8) & 0xFF), CGFloat(value & 0xFF), 1)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color { dynamic(light: hex(light), dark: hex(dark)) }

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        dynamic { $0 ? dark : light }
    }

    /// `resolve` gets true for dark appearances. It runs at draw time, on whatever thread is drawing.
    static func dynamic(_ resolve: @escaping @Sendable (Bool) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            resolve(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        })
    }
}

/// Type ramp: SF Pro / SF Mono at the sizes on the tokens board.
public extension Font {
    static let mmDisplay = Font.system(size: 26, weight: .bold)
    static let mmTitle = Font.system(size: 20, weight: .semibold)
    static let mmPaneTitle = Font.system(size: 17, weight: .bold)
    static let mmTranscript = Font.system(size: 15)
    static let mmBody = Font.system(size: 13)
    static let mmBodyEmphasis = Font.system(size: 13, weight: .semibold)
    static let mmCallout = Font.system(size: 12)
    static let mmSub = Font.system(size: 11.5)
    static let mmCaption = Font.system(size: 11, weight: .semibold)
    static let mmMono = Font.system(size: 12, design: .monospaced)
}
