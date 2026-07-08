import AppKit

/// Keyboard commands the floating panel supports beyond plain typing.
///
/// Mancia is a menu-bar-only app with no Edit menu, so ⌘-key equivalents
/// inside the panel have nothing to route through the menu bar the way they
/// do in regular apps. The panel resolves them itself (see `KeyablePanel`)
/// and dispatches the matching editor action or panel behavior.
enum PanelKeyCommand: Equatable {
    /// Standard editing in the instruction field.
    case selectAll, copy, paste, cut, undo, redo
    /// ⌘W — close the session, same as Esc.
    case closePanel
    /// ⌘, — open the Settings window.
    case openSettings
    /// ⌘⏎ — run the primary action, same as Return.
    case submit

    /// Pure mapping from a key event's characters + modifiers, kept separate
    /// from NSEvent so it is unit-testable.
    static func resolve(characters: String?, modifiers: NSEvent.ModifierFlags) -> PanelKeyCommand? {
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        guard let chars = characters?.lowercased(), !chars.isEmpty else { return nil }
        switch (chars, mods) {
        case ("a", [.command]): return .selectAll
        case ("c", [.command]): return .copy
        case ("v", [.command]): return .paste
        case ("x", [.command]): return .cut
        case ("z", [.command]): return .undo
        case ("z", [.command, .shift]): return .redo
        case ("w", [.command]): return .closePanel
        case (",", [.command]): return .openSettings
        case ("\r", [.command]): return .submit
        default: return nil
        }
    }
}
