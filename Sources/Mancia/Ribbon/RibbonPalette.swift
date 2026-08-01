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
/// `action` 6.34:1.
enum RibbonPalette {
    static let lane = Color(hex: 0x211C16)
    static let laneEdge = Color(hex: 0x352E24)
    static let text = Color(hex: 0xF3ECDE)
    static let caption = Color(hex: 0x9E9483)
    static let action = Color(hex: 0xFF6A4D)
    static let onAction = Color(hex: 0x25120C)
    static let applied = Color(hex: 0x5BC57C)
    static let error = Color(hex: 0xF0917A)
}
