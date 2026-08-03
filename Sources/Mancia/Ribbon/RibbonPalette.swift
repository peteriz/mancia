import SwiftUI

/// The lane's fixed dark register.
///
/// The ribbon reads as chrome adjoining the menu bar, so — unlike `Palette` —
/// it does not follow system appearance: a cream bar hanging under a dark menu
/// bar reads as a detached foreign object. Values mirror `Palette`'s dark
/// column, through the same hex conversion, so the two surfaces stay one
/// system. Content surfaces inside the lane (the review region, popovers) keep
/// the active appearance's register.
///
/// Measured against the lane fill `#211C16`: `text` 14.38:1, `caption` 5.65:1,
/// `applied` 7.83:1, `error` 7.27:1, `action` 5.97:1, and `onAction` on
/// `action` 6.34:1. Against the lifted `control` fill `#2A241C`, which the
/// Target menu, action buttons, and Direction field sit on: `text` 13.06:1 and
/// `caption` — the register the field's placeholder is drawn in — 5.13:1.
enum RibbonPalette {
    static let lane = Color(hex: 0x211C16)
    static let laneEdge = Color(hex: 0x352E24)
    /// The one surface lifted off the lane: the Target menu, action buttons,
    /// and Direction field. It tells a control apart from the lane now that the
    /// captions naming them are gone.
    static let control = Color(hex: 0x2A241C)
    /// Selected action-button fill: lifted enough to scan as state without
    /// competing with the vermilion Run control.
    static let controlSelected = Color(hex: 0x40352A)
    static let text = Color(hex: 0xF3ECDE)
    static let caption = Color(hex: 0x9E9483)
    static let action = Color(hex: 0xFF6A4D)
    /// Run's fill while the lane is inert — a request running, or a
    /// confirmation waiting. `action` at 80% over the lane, precomputed.
    ///
    /// Run used to go inert by dimming whole, fill and label together. Dark
    /// ink on a bright fill does not survive that: both ends walk toward the
    /// lane and the label's contrast collapses from 6.34:1 to 2.52:1, which is
    /// how the one word on the lane's one accent control became the least
    /// readable thing on it. Softening the fill alone and leaving the label at
    /// full strength keeps 4.54:1, and the comet riding the border is what
    /// says the button is busy.
    static let actionInert = Color(hex: 0xD35A42)
    static let onAction = Color(hex: 0x25120C)
    static let applied = Color(hex: 0x5BC57C)
    static let error = Color(hex: 0xF0917A)
}
