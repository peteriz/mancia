import CoreGraphics

/// Where the command ribbon sits, resolved from screen and host-window
/// geometry. Pure and free of AppKit lookups so every branch is unit-testable;
/// `RibbonWindow` supplies a `Context` built from live `NSScreen` /
/// Accessibility values.
///
/// The rule the ribbon rests on:
///
/// > If the frontmost window's screen reserves no menu-bar strip, anchor to
/// > the host window's top edge, inset below the reveal area. Otherwise anchor
/// > to the screen, directly below the menu bar.
///
/// The primary detection signal is a measurement rather than a capability
/// query: `screenFrame.maxY - visibleFrame.maxY`. `visibleFrame` excludes the
/// menu bar at the top and the Dock at the bottom or sides, so the *top* gap
/// isolates the menu-bar strip.
///
/// On a notched display that measurement is not enough on its own. There the
/// top strip is permanently unavailable to ordinary windows, so `visibleFrame`
/// stops short of `frame` whether or not a menu bar is drawn — measured on a
/// 14" MacBook Pro, the gap is 33pt with the menu bar shown, 32pt with it
/// auto-hidden, and still 33pt while another app owns a full-screen Space.
/// Geometry alone therefore cannot separate the two states, so `menuBarHidden`
/// carries the answer explicitly; see `RibbonWindow.currentContext()`.
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
        /// `true` when no menu bar is drawn over the host: the frontmost window
        /// owns a full-screen Space, or the menu bar is set to auto-hide. It
        /// overrides the measured gap, which a notched display leaves ambiguous.
        var menuBarHidden: Bool

        init(
            screenFrame: CGRect,
            visibleFrame: CGRect,
            hostWindowFrame: CGRect? = nil,
            safeAreaTop: CGFloat = 0,
            menuBarHidden: Bool = false
        ) {
            self.screenFrame = screenFrame
            self.visibleFrame = visibleFrame
            self.hostWindowFrame = hostWindowFrame
            self.safeAreaTop = safeAreaTop
            self.menuBarHidden = menuBarHidden
        }
    }

    /// Which edge the lane hangs from. Drives the corner treatment: a
    /// screen-anchored lane is flush to the top edge and rounds only its bottom
    /// corners; a window-anchored lane floats and rounds all four.
    enum Anchor: Equatable { case screen, hostWindow }

    struct Resolution: Equatable {
        var frame: CGRect
        var anchor: Anchor
    }

    /// Minimum clearance left above a window-anchored lane so the auto-revealing
    /// menu bar cannot slide over it. The lane stays at `.floating` (level 3)
    /// and the menu bar is `.mainMenu` (level 24), so the inset — not the window
    /// level — is what keeps the lane reachable.
    static let revealClearance: CGFloat = 28

    /// Never let the lane get narrower than this; below it the four cells
    /// cannot hold their labels.
    static let minimumWidth: CGFloat = 480

    /// …and never let it get wider than this. On a 5K or ultrawide display a
    /// full-width lane is thousands of points of mostly empty ink with `Run` a
    /// long way from the Direction field the user just typed in. Capping and
    /// centering keeps the command sentence readable as a sentence, and the
    /// lane is still top-centered, so it still opens in one predictable place.
    static let maximumWidth: CGFloat = 1200

    static func resolve(height: CGFloat, in context: Context) -> Resolution {
        let topGap = context.screenFrame.maxY - context.visibleFrame.maxY
        let menuBarReservesStrip = topGap > 1 && !context.menuBarHidden

        let anchor: Anchor = menuBarReservesStrip ? .screen : .hostWindow
        let host = menuBarReservesStrip
            ? context.visibleFrame
            : (context.hostWindowFrame ?? context.screenFrame)

        let clearance = menuBarReservesStrip
            ? 0
            : max(revealClearance, context.safeAreaTop + 4)

        // The minimum wins over the maximum: a lane too narrow to lay out is a
        // worse failure than one wider than its host, which merely overhangs.
        let width = max(minimumWidth, min(host.width, maximumWidth))
        let x = host.minX + (host.width - width) / 2   // centered on the host
        let y = host.maxY - clearance - height

        let frame = CGRect(x: x, y: y, width: width, height: height)
        return Resolution(frame: clamp(frame, to: context.screenFrame), anchor: anchor)
    }

    /// Keep the lane on the display. Both axes clamp against the *screen*
    /// frame, not the visible frame: a full-screen host legitimately spans past
    /// `visibleFrame` horizontally when the Dock is on a side, and a
    /// window-anchored lane sits above `visibleFrame.maxY` by design.
    ///
    /// The lower bound is applied last on each axis so it wins outright. That
    /// only matters when the lane is larger than the display, and there the
    /// controls the user needs — the review region's buttons — sit at the
    /// lane's bottom edge, so overflowing off the top is the survivable failure
    /// and dropping off the bottom is not.
    private static func clamp(_ frame: CGRect, to screen: CGRect) -> CGRect {
        var result = frame
        result.origin.x = max(min(result.minX, screen.maxX - result.width), screen.minX)
        result.origin.y = max(min(result.minY, screen.maxY - result.height), screen.minY)
        return result
    }
}
