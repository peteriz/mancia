import AppKit

/// The surface an edit session runs on.
///
/// Two exist: the floating panel that opens beside the caret, and the command
/// ribbon that opens in one predictable place at the top of the screen. They
/// are interchangeable by design — the session machine in `EditCoordinator` is
/// identical either way, and only the presentation differs — which is what
/// makes it possible to run both and compare them on real work.
@MainActor
protocol EditPresentation: AnyObject {
    /// Put the surface on screen, wherever it decides that is.
    func show()
    /// Take it off screen. The session may still be alive.
    func close()
    /// Retake key status and put focus back in the instruction field.
    func focus()
    /// Any key press routed to the surface; returns whether it was consumed.
    var onKeyDown: ((NSEvent) -> Bool)? { get set }
    /// ⌘, — the app has no menu bar to own this shortcut.
    var onOpenSettings: (() -> Void)? { get set }
}
