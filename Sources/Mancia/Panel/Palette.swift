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
    static let textSecondary = dynamic(light: 0x857866, dark: 0x9E9483)
    /// Placeholder / faint glyphs inside the field.
    static let textFaint = dynamic(light: 0xA2957F, dark: 0x8B7F6D)

    // MARK: - Accent

    /// The single accent — drives the Improve primary and the live status dot.
    static let accent = dynamic(light: 0xD8513A, dark: 0xFF6A4D)
    /// Text/glyph color that sits on top of the accent fill.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x25120C)

    // MARK: - Status

    /// Applied / success moment.
    static let applied = dynamic(light: 0x3E9E57, dark: 0x5BC57C)
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

    private static func nsColor(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The Mancia identity mark — the pointing-hand menu-bar glyph. Resolves from
/// the app bundle when assembled (`make app`/`make run`); falls back to an SF
/// Symbol under a bare `swift run` where the resource is not bundled.
enum BrandMark {
    /// A SwiftUI view of the mark, tinted to read on the current surface.
    @MainActor
    static func view(size: CGFloat) -> some View {
        Group {
            if let image = NSImage(named: "MenuBarIcon") {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
            } else {
                Image(systemName: "hand.point.up.left.fill")
                    .resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(Palette.text)
    }
}
