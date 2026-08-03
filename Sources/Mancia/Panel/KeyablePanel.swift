import AppKit

/// An `NSPanel` that can become key (needed for the instruction field), routes
/// Esc, and resolves the ⌘-shortcuts an Edit menu would normally own.
///
/// Mancia is menu-bar-only, so there is no Edit menu for ⌘A/⌘C/⌘V/⌘X/⌘Z to
/// route through. This class is why they work inside the field at all, which is
/// why both presentations — the floating panel and the command ribbon — share
/// exactly this one, rather than each growing its own.
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onOpenSettings: (() -> Void)?
    var onSubmit: (() -> Void)?
    /// ⌘T — swap the target between the selection and the whole document.
    var onToggleTarget: (() -> Void)?
    /// ⌘1…⌘5 — activate the matching visible action button.
    var onActivateAction: ((Int) -> Void)?
    /// ⌘Z after the instruction field has exhausted its own undo stack.
    var onUndoVersion: (() -> Bool)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Observe key presses so the coordinator can cancel the post-apply beat.
    /// Events it doesn't consume still forward to the content (typing, Esc),
    /// so the panel behaves normally otherwise.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let command = PanelKeyCommand.resolve(
                  characters: event.charactersIgnoringModifiers,
                  modifiers: event.modifierFlags
              )
        else { return super.performKeyEquivalent(with: event) }

        switch command {
        case .selectAll: dispatchEditorAction(#selector(NSText.selectAll(_:)))
        case .copy: dispatchEditorAction(#selector(NSText.copy(_:)))
        case .paste: dispatchEditorAction(#selector(NSText.paste(_:)))
        case .cut: dispatchEditorAction(#selector(NSText.cut(_:)))
        case .undo:
            if let undo = fieldUndoManager, undo.canUndo {
                undo.undo()
            } else {
                _ = onUndoVersion?()
            }
        case .redo: if let undo = fieldUndoManager, undo.canRedo { undo.redo() }
        case .closePanel: onCancel?()
        case .openSettings: onOpenSettings?()
        case .submit: onSubmit?()
        case .toggleTarget: onToggleTarget?()
        case .activateAction(let index): onActivateAction?(index)
        }
        // Always consume a recognized shortcut, like a menu item would —
        // a no-op (e.g. nothing to undo) should not fall through and beep.
        return true
    }

    /// Send a standard editing action down the responder chain, which reaches
    /// the field editor while the instruction field is focused — exactly what
    /// the matching Edit-menu item would do.
    private func dispatchEditorAction(_ action: Selector) {
        _ = NSApp.sendAction(action, to: nil, from: self)
    }

    /// The focused field's undo stack (the field editor is an NSTextView).
    /// Scoped to typing in the panel — never the target document.
    private var fieldUndoManager: UndoManager? {
        (firstResponder as? NSTextView)?.undoManager
    }
}
