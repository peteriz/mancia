# 02 — Placement: the hybrid rule

This is the ribbon's highest-risk piece and the reason the direction nearly
failed review. Build it first, as a pure function, before any UI exists.

## The problem

The ribbon's promise is "always opens in one predictable place." That promise
holds only while the macOS menu bar is on screen and reserving a strip.

In a **full-screen Space** the menu bar is auto-hidden, so there is no strip.
A lane anchored to the top edge of the screen would then:

1. Cover real document content — possibly the selected line, destroying the
   direction's whole premise; and
2. Get covered itself. `EditPanel` uses `panel.level = .floating`
   (`EditPanel.swift:77`), which is level 3; the menu bar is `.mainMenu`,
   level 24. Pull the pointer up to reach the lane and the revealing menu bar
   slides over the control you were reaching for.

The same is true when the user has enabled "Automatically hide and show the
menu bar" in System Settings.

## The rule

> **If the frontmost window's screen reserves no menu-bar strip, anchor to the
> host window's top edge, inset below the reveal area. Otherwise anchor to the
> screen, directly below the menu bar.**

The detection signal is a measurement, not a capability query:

```
topGap = screen.frame.maxY - screen.visibleFrame.maxY
```

`visibleFrame` excludes the menu bar at the top and the Dock at the bottom or
sides — so the *top* gap isolates the menu-bar strip exactly. `topGap > 1`
means a strip is reserved. This one number covers both the full-screen Space
and the auto-hide preference, which is why it is preferred over an
`AXFullScreen` attribute read or a `_HIHideMenuBar` defaults lookup. It also
makes the whole rule trivially testable with injected rectangles.

## The pure resolver

Add `Sources/Mancia/Ribbon/RibbonPlacement.swift`. No AppKit calls inside —
`CGRect` and `CGFloat` only, so the tests need no screen.

```swift
import CoreGraphics

/// Where the command ribbon sits, resolved from screen and host-window
/// geometry. Pure and free of AppKit lookups so every branch is unit-testable;
/// `RibbonWindow` supplies a `Context` built from live `NSScreen` / Accessibility
/// values.
enum RibbonPlacement {
    /// Everything the rule needs, all injectable.
    struct Context: Equatable {
        /// The full frame of the screen holding the frontmost window.
        var screenFrame: CGRect
        /// That screen's visible frame (menu bar and Dock excluded).
        var visibleFrame: CGRect
        /// The frontmost window's frame in AppKit screen coordinates, when the
        /// Accessibility probe resolved one. `nil` falls back to the screen.
        var hostWindowFrame: CGRect?
        /// The screen's top safe-area inset — non-zero on notched displays.
        var safeAreaTop: CGFloat
    }

    /// Which edge the lane hangs from. Drives the corner treatment in
    /// `03-visual-spec.md`: a screen-anchored lane is flush to the top edge and
    /// rounds only its bottom corners; a window-anchored lane floats and rounds
    /// all four.
    enum Anchor: Equatable { case screen, hostWindow }

    struct Resolution: Equatable {
        var frame: CGRect
        var anchor: Anchor
    }

    /// Minimum clearance left above a window-anchored lane so the auto-revealing
    /// menu bar cannot slide over it. macOS reserves ~24pt for the menu bar and
    /// more on notched displays, hence the safe-area term.
    static let revealClearance: CGFloat = 28

    /// Never let the lane get narrower than this; below it the four cells
    /// cannot hold their labels and the layout must stack instead.
    static let minimumWidth: CGFloat = 480

    static func resolve(height: CGFloat, in context: Context) -> Resolution {
        let topGap = context.screenFrame.maxY - context.visibleFrame.maxY
        let menuBarReservesStrip = topGap > 1

        let anchor: Anchor = menuBarReservesStrip ? .screen : .hostWindow
        let host = menuBarReservesStrip
            ? context.visibleFrame
            : (context.hostWindowFrame ?? context.screenFrame)

        let clearance = menuBarReservesStrip
            ? 0
            : max(revealClearance, context.safeAreaTop + 4)

        let width = max(minimumWidth, host.width)
        let x = host.minX + (host.width - width) / 2   // centered if clamped wider
        let y = host.maxY - clearance - height

        var frame = CGRect(x: x, y: y, width: width, height: height)
        frame = clamp(frame, to: context.visibleFrame, screen: context.screenFrame)
        return Resolution(frame: frame, anchor: anchor)
    }

    /// Keep the lane on the display. Horizontal clamping uses the screen frame
    /// (a full-screen host legitimately spans past `visibleFrame` horizontally
    /// when the Dock is on a side); vertical clamping uses the screen frame too,
    /// because a window-anchored lane sits above `visibleFrame.maxY` by design.
    private static func clamp(_ frame: CGRect, to visible: CGRect, screen: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(result.minX, screen.minX), screen.maxX - result.width)
        result.origin.y = min(max(result.minY, screen.minY), screen.maxY - result.height)
        return result
    }
}
```

Note `resolve` takes a **height** and returns a **frame**: the lane's width is
imposed by placement, not by content, which inverts the current panel's
`setContentSize(content.fittingSize)` sizing (`EditPanel.swift:102`). Height
still comes from content; see stage 3.

## Choosing the screen

Not `NSScreen.main` — that is the screen with the key window, which for a
menu-bar app can be wrong. Pick the screen holding the frontmost *host* window:

1. If the Accessibility probe returned a host window frame, choose the screen
   whose frame has the largest intersection area with it.
2. Otherwise fall back to the screen containing `NSEvent.mouseLocation`.
3. Otherwise `NSScreen.main`.

Put this in the adapter (`RibbonWindow`), not in `RibbonPlacement`, so the
resolver stays pure.

## The host-window probe

Add `Sources/Mancia/Ribbon/HostWindowProbe.swift`. It is the only new
Accessibility surface in this work.

```swift
/// Reads the frontmost application's focused-window frame, so a full-screen
/// host can be anchored to rather than covered. Accessibility-gated exactly
/// like `SelectionCapture`; returns nil rather than throwing on any failure,
/// because placement must degrade to the screen, never fail the session.
@MainActor
enum HostWindowProbe {
    static func frontmostWindowFrame() -> CGRect? { … }
}
```

Implementation notes:

- `NSWorkspace.shared.frontmostApplication?.processIdentifier` →
  `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` →
  `kAXPositionAttribute` + `kAXSizeAttribute`.
- **Accessibility rectangles are top-left origin; AppKit is bottom-left.**
  `SelectionCapture.selectionScreenRect()` (`SelectionCapture.swift:127`)
  already performs this flip for the caret rect — reuse its convention exactly,
  and if the conversion is more than two lines, factor it into a shared helper
  rather than writing it a second time.
- Never block. This runs synchronously on the main actor during `show()`; a
  hung host app must not hang Mancia. If the AX call cannot be made
  non-blocking, guard it with `AXUIElementSetMessagingTimeout` at ~100ms.
- Returns `nil` when Accessibility is not trusted. That is fine:
  `EditCoordinator.start()` already gates the whole session behind
  `ensureAccessibility()` (`EditCoordinator.swift:464`).

## Cases the rule must produce

Each row is a unit test in [05-test-plan.md](05-test-plan.md).

| Case | Context | Expected |
|---|---|---|
| Windowed, single display | `topGap = 25` | `.screen`; lane flush under the menu bar, full `visibleFrame` width |
| Zoomed window | same as above | identical — a zoomed window changes nothing about placement |
| Full-screen Space | `topGap = 0`, host = full screen | `.hostWindow`; `y = screen.maxY - 28 - height`, full width |
| Menu bar set to auto-hide | `topGap = 0`, host = a normal window | `.hostWindow`; anchored to that window's top edge |
| Notched display, full-screen | `topGap = 0`, `safeAreaTop = 37` | clearance is `41`, not `28` |
| Split View | `topGap = 0`, host = left half | `.hostWindow`; lane spans the half, not the screen |
| Narrow host window | host width `320` | width clamps to `minimumWidth` 480 and centers on the host |
| Probe failed in full-screen | `hostWindowFrame = nil`, `topGap = 0` | falls back to `screenFrame`, still inset by clearance |
| Secondary display, host on it | screen 2's rects | lane on screen 2 — never screen 1 |
| Lane taller than the screen | absurd height | clamped so `minY >= screen.minY` |

## Re-resolving

Placement is resolved once per `show()`. It must **also** re-resolve when:

- the lane's height changes (review region opening or closing), because the
  frame is anchored by its *top* edge — recompute and `setFrame` so the lane
  grows downward rather than shifting up;
- `NSApplication.didChangeScreenParametersNotification` fires while visible
  (display connected, resolution change, Dock moved).

It must **not** re-resolve on every host-window move: the lane is transient and
chasing a dragged window would be worse than staying put.

## Window level

Keep `.floating`. Do **not** raise the level above `.mainMenu` to "win" against
the menu bar — that would cover the system menu bar in the windowed case, which
is user-hostile and would break the very affordance the ribbon sits beneath.
The clearance inset is the correct fix.

Keep `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
(`EditPanel.swift:83`). This is already correct and is what lets the lane
appear over a full-screen app at all; without `.fullScreenAuxiliary` the
hotkey would switch Spaces instead of showing the lane.
