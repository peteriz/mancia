import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global "Edit Selection" hotkey, default ⌃⌥⌘E.
    static let editSelection = Self(
        "editSelection",
        default: .init(.e, modifiers: [.control, .option, .command])
    )
}

/// Registers the global hotkey and forwards presses to a handler.
@MainActor
final class HotkeyManager {
    init(onTrigger: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .editSelection) {
            onTrigger()
        }
    }
}
