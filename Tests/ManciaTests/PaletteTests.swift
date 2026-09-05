import AppKit
import SwiftUI
import Testing

@testable import Mancia

@MainActor
@Test("Palette text and focus remain readable in both appearances", arguments: [false, true])
func paletteContrast(dark: Bool) throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    func luminance(_ color: Color) throws -> Double {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let rgb = try #require(resolved)
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
    let textColors = [
        Palette.text, Palette.textSecondary, Palette.textFaint,
        Palette.applied, Palette.error, Palette.attention,
    ]
    let pairs = [Palette.surface, Palette.raised, Palette.controlHover].flatMap { background in
        textColors.map { ($0, background) }
    } + [
        (RibbonPalette.onAction, RibbonPalette.action),
        (RibbonPalette.onCustomRun, RibbonPalette.customRun),
    ]
    for (index, pair) in pairs.enumerated() {
        let (foreground, background) = pair
        let first = try luminance(foreground)
        let second = try luminance(background)
        let contrast = (max(first, second) + 0.05) / (min(first, second) + 0.05)
        #expect(contrast >= 4.5, "Color pair \(index), dark appearance: \(dark)")
    }
}
