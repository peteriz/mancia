import SwiftUI

/// The shared palette over a restrained material backdrop. Controls use solid
/// fills so their text stays readable regardless of the host document.
enum RibbonPalette {
    static let laneTint = Palette.surface.opacity(0.88)
    static let laneEdge = Palette.border
    /// Buttons sit on their own step above the lane so each one reads as a
    /// distinct target rather than as a label floating on the strip.
    static let controlTint = Palette.raised
    static let controlHoverTint = Palette.controlHover
    static let controlEdge = Palette.border
    /// The instruction field is the one recessed surface: paper rather than
    /// chrome, so writing reads as writing.
    static let directionTint = Palette.raised
    /// Used when Reduce Transparency is on, where translucency is not an option
    /// and the lane still has to be legible over anything behind it.
    static let laneOpaque = Palette.surface
    static let text = Palette.text
    static let caption = Palette.textSecondary
    static let symbol = Palette.textSecondary
    static let action = Palette.accent
    static let customRun = Palette.secondaryAction
    static let onCustomRun = Palette.onSecondaryAction
    /// Cool light is reserved for work in progress. It separates state from
    /// action: orange still means "run this", while blue means "it is running".
    static let processing = Color(hex: 0x49B8FF)
    static let onAction = Palette.onAccent
    static let applied = Palette.applied
    static let error = Palette.error
}
