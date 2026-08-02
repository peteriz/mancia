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
    /// ⌘1…⌘4 — pin the nth preset in `PanelPreset.all`, as picking it from the
    /// Action menu would. Carries the index rather than the preset so this
    /// stays a pure mapping from keys, with the catalog resolved by the model.
    case selectPreset(Int)
    /// ⌘T — swap the target between the selection and the whole document.
    ///
    /// The digits it used to share with the presets are worth more to them:
    /// there are four presets and picking one is the common move, whereas the
    /// target is usually right already — the session opens aimed at whatever
    /// the user had selected. A two-state control is served just as well by one
    /// key, and `T` survives keyboard layouts that a shifted digit would not.
    case toggleTarget

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
        case ("t", [.command]): return .toggleTarget
        case ("1", [.command]): return .selectPreset(0)
        case ("2", [.command]): return .selectPreset(1)
        case ("3", [.command]): return .selectPreset(2)
        case ("4", [.command]): return .selectPreset(3)
        default: return nil
        }
    }

    /// Tab and ⇧Tab, which move focus between the ribbon's cells.
    ///
    /// Resolved from the key code, and separately from the ⌘-shortcuts above,
    /// because neither is a key equivalent: a bare Tab has no modifier to mark
    /// it as a command, so both arrive through `sendEvent` rather than
    /// `performKeyEquivalent`.
    enum FocusMove: Equatable { case next, previous }

    /// Return / keypad Enter, unmodified — the lane's primary key.
    ///
    /// Also not a key equivalent, and the Direction field is the only cell that
    /// answers it on its own (through `onSubmit`), so every other focus stop
    /// needs the window to run it.
    static func isPrimaryReturn(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == 36 || keyCode == 76 else { return false }
        return modifiers.intersection([.command, .shift, .option, .control]).isEmpty
    }

    static func focusMove(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> FocusMove? {
        guard keyCode == 48 else { return nil }
        switch modifiers.intersection([.command, .shift, .option, .control]) {
        case []: return .next
        case [.shift]: return .previous
        default: return nil
        }
    }
}
