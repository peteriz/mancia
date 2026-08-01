import AppKit
import SwiftUI

/// The Mancia visual palette — a warm cream/ink base with one decisive
/// vermilion accent. Colors adapt to light and dark appearance. Kept in one
/// place so the panel reads as a single, sharp, cohesive surface.
enum Palette {
    // MARK: - Surfaces

    /// The panel background.
    static let surface = dynamic(light: 0xF5EFE3, dark: 0x161310)
    /// Raised controls (the describe field).
    static let raised = dynamic(light: 0xFCF9F1, dark: 0x211C16)
    /// Hairline borders.
    static let border = dynamic(light: 0xE4D9C6, dark: 0x352E24)

    // MARK: - Text

    static let text = dynamic(light: 0x1A1611, dark: 0xF3ECDE)
    /// Captions and status lines. The light value is deep enough to clear
    /// 4.5:1 on `surface` (5.20:1); the earlier 0x857866 was 3.76:1.
    static let textSecondary = dynamic(light: 0x6E6250, dark: 0x9E9483)
    /// Placeholder / faint glyphs inside the field. Placeholders are body text
    /// and need 4.5:1 like any other; the light value gives 4.76:1, where the
    /// earlier 0xA2957F gave 2.57:1.
    static let textFaint = dynamic(light: 0x756850, dark: 0x8B7F6D)

    // MARK: - Accent

    /// The single accent — drives the Improve primary and the live status dot.
    /// The light value carries white text on the run button at 5.14:1; the
    /// earlier 0xD8513A was 4.07:1 and failed AA.
    static let accent = dynamic(light: 0xC2412C, dark: 0xFF6A4D)
    /// Text/glyph color that sits on top of the accent fill.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x25120C)

    // MARK: - Status

    /// Applied / success moment. The light value reaches 4.60:1, where the
    /// earlier 0x3E9E57 was 2.94:1 — below even the 3:1 floor for the 7pt
    /// status dot it fills.
    static let applied = dynamic(light: 0x2F7A44, dark: 0x5BC57C)
    /// Error moment (kept warm so it does not clash with the palette).
    static let error = dynamic(light: 0xC0392B, dark: 0xF0917A)
    static let errorDot = dynamic(light: 0xD8513A, dark: 0xE4553B)

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
