import AppKit

/// The standard macOS About panel, with Mancia's name, bundle version, and icon.
///
/// Lives outside `AppDelegate` so `DebugCLI --about-check` can present exactly
/// the panel the menu presents, rather than a lookalike that could drift.
@MainActor
enum AboutPanel {
    /// Build the options dictionary. Pure and static so the version wiring is
    /// unit-testable without standing up an app.
    static func options(info: [String: Any]?, icon: NSImage?) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Mancia",
            .applicationVersion: AppVersion.displayString(from: info),
        ]
        if let icon { options[.applicationIcon] = icon }
        return options
    }

    /// The bundled app icon, sized for the panel. Absent under `swift run`,
    /// where there is no bundle to read from; the panel falls back to the
    /// generic icon rather than failing.
    static func bundledIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "mancia-logo", withExtension: "png"),
              let icon = NSImage(contentsOf: url)
        else { return nil }
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }

    /// Show the panel and bring it forward.
    ///
    /// Order matters: the panel is ordered front *before* activating, so an
    /// accessory (LSUIElement) app — which has no window to activate onto —
    /// raises the panel with the same activation rather than a later one.
    static func present() {
        NSApp.orderFrontStandardAboutPanel(
            options: options(info: Bundle.main.infoDictionary, icon: bundledIcon())
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The panel AppKit created for `present()`, if it is on screen.
    ///
    /// Identified structurally (a visible titled panel with a close button that
    /// is none of Mancia's own windows) because AppKit's about-panel class is
    /// private. Used by `--about-check` to verify the close button.
    static func currentPanel() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible
                && window is NSPanel
                && !(window is KeyablePanel)
                && window.standardWindowButton(.closeButton) != nil
        }
    }

    /// Visible text rendered by the panel, including text nested in stack views.
    static func displayedText(in panel: NSWindow) -> [String] {
        guard let contentView = panel.contentView else { return [] }

        var text: [String] = []
        collectDisplayedText(in: contentView, into: &text)
        return text
    }

    private static func collectDisplayedText(in view: NSView, into text: inout [String]) {
        guard !view.isHidden else { return }

        if let textField = view as? NSTextField {
            let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                text.append(value)
            }
        }
        for subview in view.subviews {
            collectDisplayedText(in: subview, into: &text)
        }
    }
}
