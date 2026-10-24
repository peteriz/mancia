import SwiftUI

/// The lane's fixed graphite register.
///
/// The ribbon is chrome laid over somebody else's document, so it keeps one
/// look whatever the system appearance or the page behind it: a warm graphite
/// slab with a single vermilion accent. A cream lane disappeared into the white
/// documents it usually sits on; a dark one reads as a tool on top of the page.
/// Opaque on purpose — no material — so contrast never depends on what is
/// behind it, and Reduce Transparency has nothing to undo.
///
/// Measured against `lane` (#1A1917): `text` 15.4:1, `caption` 6.8:1,
/// `appliedText` 11.9:1, `errorText` 9.3:1, `onAccent` on `accent` 6.1:1.
enum RibbonPalette {
    static let lane = Color(hex: 0x1A1917)
    /// The outer edge, so the slab holds its shape against a dark document.
    static let laneEdge = Color.black.opacity(0.6)
    /// A one-point lip of light along the inside of the edge.
    static let laneHighlight = Color.white.opacity(0.07)
    /// Dividers inside the lane: between target and actions, above a status row.
    static let divider = Color(hex: 0x33302C)
    static let controlHover = Color(hex: 0x2A2825)
    /// The Custom field — one step up from the lane so writing reads as a well.
    static let field = Color(hex: 0x232220)
    static let fieldEdge = Color(hex: 0x3A3732)
    static let text = Color(hex: 0xF3F0E9)
    static let caption = Color(hex: 0xA7A196)
    static let symbol = Color(hex: 0xC9C3B7)
    /// Keyboard focus: 4.8:1 against the lane, visible without competing
    /// with the accent.
    static let focusRing = Color(hex: 0x8A857C)
    /// The live segment of the action-set toggle: paper on graphite, so the
    /// mode reads at a glance without spending the accent on it.
    static let selectedSegment = Color(hex: 0xEDE8DE)
    static let onSelectedSegment = Color(hex: 0x1A1917)
    /// Vermilion: the action that is open or just ran, and the Run button.
    static let accent = Color(hex: 0xFF5A36)
    static let onAccent = Color(hex: 0x1A0D08)
    /// The working light: a paler, warmer vermilion than `accent`, so a beam
    /// on a dark control reads as the same family as the action it belongs to.
    static let processing = Color(hex: 0xFF8A6B)
    static let applied = Color(hex: 0x7BD389)
    static let appliedText = Color(hex: 0xA7E3B0)
    static let error = Color(hex: 0xFF7A6B)
    static let errorText = Color(hex: 0xFFA699)
}
