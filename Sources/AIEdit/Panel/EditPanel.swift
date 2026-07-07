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

    /// Where to place the panel when showing it.
    enum Placement {
        /// Adjacent to a screen rect (AppKit coordinates), e.g. the text caret.
        case near(CGRect)
        /// Next to the current mouse location (legacy fallback).
        case nearMouse
        /// Centered on the main screen (entire-document scope).
        case centered
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show the panel at the given placement, clamped on screen.
    func show(placement: Placement = .nearMouse) {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, placement: placement)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Dismiss the panel. While shown it stays visible permanently — synthetic
    /// keystrokes are posted to the target app's pid, so the panel never needs
    /// to get out of their way.
    func close() {
        panel?.orderOut(nil)
    }

    /// Retake key status after the target app was activated for a keystroke
    /// burst, so Esc (and typing) reach the panel again. No reordering, no
    /// flicker; no-op when the panel isn't on screen.
    func focus() {
        guard let panel, panel.isVisible else { return }
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.model.onCancel?() }
        return panel
    }

    private func position(_ panel: NSPanel, placement: Placement) {
        // Size the panel to its SwiftUI content before computing the origin —
        // a freshly created panel still has a zero-height frame here.
        if let content = panel.contentView {
            panel.setContentSize(content.fittingSize)
        }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        var origin: CGPoint
        var screen: NSScreen?
        switch placement {
        case .near(let rect):
            // Just below the caret/selection, left-aligned with it.
            origin = CGPoint(x: rect.minX, y: rect.minY - size.height - 8)
            screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        case .nearMouse:
            let mouse = NSEvent.mouseLocation
            origin = CGPoint(x: mouse.x + 8, y: mouse.y - size.height - 8)
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        case .centered:
            screen = NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
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
