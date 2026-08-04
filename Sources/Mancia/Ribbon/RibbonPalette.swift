import SwiftUI

/// The ribbon's frosted register.
///
/// Every tint is mixed from `primary`, never from white. A white tint is
/// invisible over a white document — the lane and its controls disappeared into
/// the page and left only an outline — while ink-based tints darken over light
/// hosts and lighten over dark ones, so the same values hold their contrast
/// against any app the ribbon opens over.
///
/// The material stays frosted rather than liquid: the surfaces carry enough
/// tint to read as controls first and as glass second.
enum RibbonPalette {
    static let laneTint = Color.primary.opacity(0.07)
    static let laneEdge = Color.primary.opacity(0.20)
    /// Buttons sit on their own step above the lane so each one reads as a
    /// distinct target rather than as a label floating on the strip.
    static let controlTint = Color.primary.opacity(0.10)
    static let controlHoverTint = Color.primary.opacity(0.18)
    static let controlEdge = Color.primary.opacity(0.16)
    /// The instruction field is the one recessed surface: paper rather than
    /// chrome, so writing reads as writing.
    static let directionTint = Color(nsColor: .textBackgroundColor).opacity(0.72)
    /// Used when Reduce Transparency is on, where translucency is not an option
    /// and the lane still has to be legible over anything behind it.
    static let laneOpaque = Color(nsColor: .windowBackgroundColor)
    static let text = Color.primary
    static let caption = Color.secondary
    static let symbol = Color.primary.opacity(0.75)
    static let action = Color(hex: 0xFF6A4D)
    static let customRun = Color(hex: 0x46566F)
    static let onCustomRun = Color(hex: 0xF6F8FF)
    /// Cool light is reserved for work in progress. It separates state from
    /// action: orange still means "run this", while blue means "it is running".
    static let processing = Color(hex: 0x49B8FF)
    static let onAction = Color(hex: 0x25120C)
    static let applied = Color(hex: 0x5BC57C)
    static let error = Color(hex: 0xF0917A)
}
