import AppKit
import SwiftUI

/// A non-activating floating panel that hosts the SwiftUI edit UI near the
/// cursor, so the target app keeps focus until the user interacts.
@MainActor
final class EditPanel {
    private let model: PanelModel
    private var panel: NSPanel?

    init(model: PanelModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show the panel near the current mouse location, clamped on screen.
    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Temporarily hide the panel while preserving its state and position, so
    /// synthetic ⌘A/⌘C/⌘V keystrokes reach the target app instead of being
    /// swallowed by this floating panel. Pair with `reveal()`.
    func hide() {
        panel?.orderOut(nil)
    }

    /// Re-show a previously hidden panel in place (no repositioning), using the
    /// same key-and-order-front path as `show()` so focus behaves exactly as it
    /// did before hiding. `orderOut` tears down the SwiftUI hosting view's
    /// accessibility tree, so we install a fresh hosting view before ordering
    /// front. All state lives in the external `PanelModel`, so recreating the
    /// view preserves it.
    func reveal() {
        guard let panel else { return }
        panel.contentView = makeContentView()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    private func makeContentView() -> NSHostingView<EditPanelView> {
        NSHostingView(rootView: EditPanelView(model: model))
    }

    private func makePanel() -> NSPanel {
        let hosting = makeContentView()
        let panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.model.onCancel?() }
        return panel
    }

    private func position(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = CGPoint(x: mouse.x + 8, y: mouse.y - size.height - 8)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}

/// NSPanel that can become key (needed for the text field) and routes Esc.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
