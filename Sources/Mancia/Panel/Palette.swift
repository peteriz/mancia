import AppKit
import SwiftUI

/// The Mancia visual palette — a warm cream/ink base with one decisive
/// vermilion accent. Colors adapt to light and dark appearance. Kept in one
/// place so the panel reads as a single, sharp, cohesive surface.
enum Palette {
    // MARK: - Surfaces

    /// The panel background.
    static let surface = dynamic(light: 0xF5F3EF, dark: 0x242321)
    /// Raised controls (the describe field).
    static let raised = dynamic(light: 0xFDFCF9, dark: 0x30302E)
    static let controlHover = dynamic(light: 0xE8E5DF, dark: 0x3E3C38)
    /// Hairline borders.
    static let border = dynamic(light: 0xC8C3BB, dark: 0x595650)

    // MARK: - Text

    static let text = dynamic(light: 0x252421, dark: 0xF2F0EB)
    static let textSecondary = dynamic(light: 0x5E5B55, dark: 0xBBB7AE)
    static let textFaint = dynamic(light: 0x625E57, dark: 0xB3AEA4)

    // MARK: - Accent

    /// Reserved for explicit approval, rather than everyday action selection.
    static let accent = dynamic(light: 0xB74732, dark: 0xEF896D)
    /// Text/glyph color that sits on top of the accent fill.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x25120C)
    static let secondaryAction = dynamic(light: 0x46566F, dark: 0xA8B8CF)
    static let onSecondaryAction = dynamic(light: 0xF6F8FF, dark: 0x1F2935)

    // MARK: - Status

    static let applied = dynamic(light: 0x2F7046, dark: 0x8BC69B)
    static let attention = dynamic(light: 0x805B12, dark: 0xE3B766)
    /// Error moment (kept warm so it does not clash with the palette).
    static let error = dynamic(light: 0xB43A36, dark: 0xEE9790)
    static let errorDot = error

    // MARK: - Helpers

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    /// The one place a `0xRRGGBB` literal becomes a color. Internal rather
    /// than private so surfaces that pin a fixed register — see
    /// `RibbonPalette` — reuse this conversion instead of copying it.
    static func nsColor(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// A fixed sRGB color from a `0xRRGGBB` literal, for surfaces that do not
    /// follow system appearance. Appearance-adaptive colors belong in
    /// `Palette` instead.
    init(hex: Int) {
        self.init(nsColor: Palette.nsColor(hex))
    }
}

/// The Mancia identity mark — the pointing-hand menu-bar glyph.
enum BrandMark {
    static let systemSymbolName = "hand.point.up.left.fill"

    /// A SwiftUI view of the mark, tinted to read on the current surface.
    @MainActor
    static func view(size: CGFloat) -> some View {
        Image(systemName: systemSymbolName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Palette.text)
    }
}
