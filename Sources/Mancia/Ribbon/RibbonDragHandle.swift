import AppKit
import SwiftUI

struct RibbonDragHandle: NSViewRepresentable {
    var onDrag: (NSEvent) -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Move ribbon")
        view.setAccessibilityIdentifier("Ribbon-drag")
        view.toolTip = "Drag to move the ribbon"
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
    }

    final class HandleView: NSView {
        var onDrag: ((NSEvent) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            onDrag?(event)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setFill()
            for x in [-3.0, 3.0] {
                for y in [-5.0, 0.0, 5.0] {
                    NSBezierPath(ovalIn: NSRect(
                        x: bounds.midX + x - 1, y: bounds.midY + y - 1,
                        width: 2, height: 2)).fill()
                }
            }
        }
    }
}
